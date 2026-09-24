import Foundation

/// Live progress for the running job, with where it came from.
struct CurrentProgress: Equatable {
    enum Source: String {
        /// ComfyUI's own websocket "progress", received because the prompt had no client_id
        /// (broadcast) or was ComfyBar's own.
        case socket = "ComfyUI progress message"
        /// tqdm bar from ComfyUI's console buffer (GET /internal/logs/raw).
        case consoleBar = "ComfyUI console (sampler bar)"
    }
    let value: Int
    let max: Int
    let node: String?
    let source: Source
    /// Only for .consoleBar: tqdm's estimate for the rest of THIS bar.
    let barRemainingSeconds: Int?
    let barClosed: Bool
    var percent: Int { max > 0 ? Int((Double(value) / Double(max) * 100).rounded(.down)) : 0 }
}

@MainActor
final class Monitor: ObservableObject {
    // MARK: published state
    @Published private(set) var reachability: Reachability?
    @Published private(set) var stats: SystemStats?
    @Published private(set) var queue: QueueSnapshot = .empty
    @Published private(set) var recent: [Job] = []
    @Published private(set) var listener: PortProbe.Listener?
    /// Listening addresses on the port that are not loopback (should always be empty).
    @Published private(set) var exposedAddresses: [String] = []
    /// Called every poll while such a listener exists; AppDelegate stops it if ComfyBar started it.
    var onExposedListeners: (([PortProbe.Listener]) -> Void)?
    @Published private(set) var serverFootprint: UInt64?
    @Published private(set) var serverStart: Date?
    @Published private(set) var memory: MemorySnapshot?
    @Published private(set) var swap: SwapSnapshot?
    @Published private(set) var progress: CurrentProgress?
    @Published private(set) var runningStart: StateMachine.StartEstimate?
    @Published private(set) var iconState: IconState = .notRunning
    @Published private(set) var unacknowledgedFailure: Job?
    @Published private(set) var lastPoll: Date?
    @Published private(set) var lastError: String?
    @Published var busyMessage: String?
    @Published private(set) var now = Date()

    let settings: AppSettings
    let log: EventLog
    let pressure: MemoryPressureWatcher
    let notifier: Notifier
    private(set) var client: ComfyClient
    private(set) var socket: SocketMonitor
    private var loop: Task<Void, Never>?
    private var wake: CheckedContinuation<Void, Never>?
    private var pollCount = 0
    private var activeIDs: Set<String> = []
    private var seenPending: Set<String> = []
    private var seenRunningAt: [String: Date] = [:]
    private var socketProgress: [String: (value: Int, max: Int, node: String?)] = [:]
    private var socketNode: [String: String] = [:]
    private var lastIconState: IconState?
    private var lastStepLogged: String?
    private var lastPollSummary = ""
    private var configKey: String
    var onChange: (() -> Void)?

    init(settings: AppSettings, log: EventLog, notifier: Notifier) {
        self.settings = settings
        self.log = log
        self.notifier = notifier
        pressure = MemoryPressureWatcher(log: log)
        configKey = settings.hostPort
        client = ComfyClient(base: settings.baseURL ?? URL(string: "http://127.0.0.1:8188")!, log: log)
        socket = SocketMonitor(host: settings.host, port: settings.port, log: log)
        wireSocket()
    }

    var runningItem: QueueItem? { queue.running.first }

    func source(of item: QueueItem) -> JobSource {
        Attribution.source(of: item, comfyBarClientID: socket.clientID)
    }

    var runningInfo: RunningJobInfo? {
        guard let r = runningItem else { return nil }
        let elapsed = runningStart.map { Int(Date().timeIntervalSince($0.date)) }
        return RunningJobInfo(promptID: r.promptID, source: source(of: r), elapsedSeconds: elapsed)
    }

    var runningNode: String? {
        guard let r = runningItem else { return nil }
        return progress?.node ?? socketNode[r.promptID]
    }

    // MARK: lifecycle

    func start() {
        pressure.start()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.pollOnce()
                let interval = self.settings.pollInterval
                await self.sleepOrWake(seconds: interval)
            }
        }
    }

    func stop() {
        loop?.cancel()
        socket.stop()
    }

    /// Ask for an immediate poll (after a control, or a socket status message). A poke that
    /// arrives while a poll is running is remembered and ends the next sleep at once.
    func pokePoll() {
        if let w = wake { wake = nil; w.resume() } else { pokePending = true }
    }

    private var pokePending = false
    private var sleepGeneration = 0

    private func sleepOrWake(seconds: Double) async {
        if pokePending { pokePending = false; return }
        sleepGeneration += 1
        let gen = sleepGeneration
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            wake = c
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
                // Only the timer of THIS sleep may end it; a timer left over from a sleep that
                // a poke ended early must not cut a later sleep short.
                guard let self, gen == self.sleepGeneration, let w = self.wake else { return }
                self.wake = nil
                w.resume()
            }
        }
    }

    /// Host/port changed in Settings: rebuild client and socket.
    func reconfigureIfNeeded() {
        guard settings.hostPort != configKey else { return }
        log.add(.state, "target changed \(configKey) -> \(settings.hostPort)")
        configKey = settings.hostPort
        socket.stop()
        client = ComfyClient(base: settings.baseURL ?? URL(string: "http://127.0.0.1:8188")!, log: log)
        socket = SocketMonitor(host: settings.host, port: settings.port, log: log)
        wireSocket()
        reachability = nil
        listener = nil; exposedAddresses = []; serverFootprint = nil; serverStart = nil
        queue = .empty; recent = []; stats = nil; progress = nil; runningStart = nil
        activeIDs = []; knownFinished = nil; seenPending = []; seenRunningAt = [:]
        socketProgress = [:]; socketNode = [:]; lastConsoleBar = nil; consecutiveFailures = 0
        socketIsDown = true
        pokePoll()
    }

    private func wireSocket() {
        let current = socket
        socket.onMessage = { [weak self, weak current] m in
            Task { @MainActor in
                guard let self, let current, current === self.socket else { return }
                self.handle(m)
            }
        }
        socket.onConnected = { [weak self, weak current] up in
            Task { @MainActor in
                guard let self, let current, current === self.socket else { return }
                self.socketConnected(up)
            }
        }
    }

    private func handle(_ m: SocketMessage) {
        switch m {
        case .progress(let v, let mx, let pid, let node):
            guard let pid else { return }
            socketProgress[pid] = (v, mx, node)
            if let node { socketNode[pid] = node }
            refreshProgress()
            onChange?()
        case .executing(let node, let pid):
            if let pid, let node { socketNode[pid] = node }
        case .status, .executionStart, .executionSuccess, .executionError, .executionInterrupted:
            pokePoll()
        case .other:
            break
        }
    }

    // MARK: poll

    func pollOnce() async {
        reconfigureIfNeeded()
        now = Date()
        let port = settings.port
        let local = LaunchGuard.isLoopback(settings.host)
        let allListeners: [PortProbe.Listener] = local
            ? await Task.detached { PortProbe.listeners(port: port) }.value
            : []
        let listenerNow = allListeners.first
        listener = listenerNow
        // Anything on this port reachable from beyond this Mac? (R2 defence in depth)
        let exposed = allListeners.filter { !PortProbe.isLoopbackAddress($0.address) }
        if exposed.map(\.address) != exposedAddresses {
            exposedAddresses = exposed.map(\.address)
            if !exposed.isEmpty { log.add(.error, "NOT loopback: \(exposed.map { "pid \($0.pid) \($0.address)" }.joined(separator: ", "))") }
        }
        if !exposed.isEmpty { onExposedListeners?(exposed) }

        var reach: Reachability
        var parts: [String] = []
        let t0 = Date()
        do {
            let q = try await client.queue(quiet: true)
            reach = .up
            parts.append("queue r\(q.running.count)/p\(q.pending.count)")
            applyQueue(q)
        } catch let e as ComfyClient.ClientError {
            if case .refused = e { reach = .refused } else { reach = .failed(e.description) }
        } catch {
            reach = .failed("\(error)")
        }
        // One timeout is not "down": hold the last state until StateMachine.failuresBeforeDown.
        var holding = false
        if case .failed(let why) = reach {
            consecutiveFailures += 1
            let d = StateMachine.debounce(previous: reachability, raw: reach, consecutiveFailures: consecutiveFailures)
            if d != reach {
                holding = true
                log.add(.info, "slow: /queue failed (\(why)), \(consecutiveFailures)/\(StateMachine.failuresBeforeDown) - still showing up")
                reach = d
            }
        } else {
            consecutiveFailures = 0
        }

        if reach == .up && !holding {
            if stats == nil || pollCount % 15 == 0 {
                if let s = try? await client.systemStats(quiet: true) { stats = s }
            }
            let active = queue.running.count + queue.pending.count
            if let jobs = try? await client.jobs(limit: settings.recentCount + active + 4, quiet: true) {
                applyJobs(jobs)
                parts.append("jobs \(jobs.count)")
            }
            if runningItem != nil, LaunchGuard.isLoopback(settings.host), let entries = try? await client.logsRaw(quiet: true) {
                applyLogs(entries)
                parts.append("logs \(entries.count)")
            } else if runningItem == nil {
                progress = nil
            }
            if socketIsDown { socket.start() }
        } else if !holding {   // holding: keep the last good picture while the server is slow
            queue = .empty
            progress = nil
            runningStart = nil
        }

        // server process figures (only when we can see the listener on this Mac)
        if let l = listenerNow {
            serverFootprint = MachineStats.footprint(pid: l.pid)
            serverStart = MachineStats.startTime(pid: l.pid)
        } else {
            serverFootprint = nil
            serverStart = nil
        }
        memory = MachineStats.memory()
        swap = MachineStats.swap()

        if StateMachine.wentDown(from: reachability, to: reach) {
            log.add(.state, "server went down: \(reach)")
            if settings.notifyDown {
                notifier.post(title: "ComfyUI went down", body: "\(settings.hostPort) - \(Self.describe(reach))")
            }
        }
        if reachability != reach { log.add(.state, "reachability \(reachability.map(Self.describe) ?? "-") -> \(Self.describe(reach))") }
        reachability = reach
        if case .failed(let why) = reach { lastError = why } else if reach == .up { lastError = nil }

        let obs = Observation(reachability: reach, processListening: local ? (listenerNow != nil) : nil,
                              runningCount: queue.running.count, pendingCount: queue.pending.count,
                              unacknowledgedFailure: unacknowledgedFailure != nil)
        let st = StateMachine.iconState(obs)
        if st != lastIconState { log.add(.state, "icon \(lastIconState?.rawValue ?? "-") -> \(st.rawValue)") }
        lastIconState = st
        iconState = st
        pollCount += 1
        lastPoll = Date()
        // One line per poll would fill the 500-event ring in minutes; log changes, plus a
        // heartbeat every 60 polls.
        let summary = "\(Self.describe(reach)) \(parts.joined(separator: ", "))"
        if summary != lastPollSummary || pollCount % 60 == 0 {
            log.add(.info, "poll \(summary) \(Int(Date().timeIntervalSince(t0) * 1000))ms")
            lastPollSummary = summary
        }
        onChange?()
    }

    private var socketIsDown = true
    private var consecutiveFailures = 0
    /// Finished job ids already seen (nil until the first /api/jobs answer seeds it silently).
    private var knownFinished: Set<String>?
    private var watchingSinceMs: Int64 = 0
    func socketConnected(_ up: Bool) { socketIsDown = !up }

    static func describe(_ r: Reachability) -> String {
        switch r {
        case .up: return "up"
        case .refused: return "not running (connection refused)"
        case .failed(let s): return "unreachable (\(s))"
        }
    }

    private func applyQueue(_ q: QueueSnapshot) {
        let prevRunning = queue.running.first?.promptID
        for p in q.pending { seenPending.insert(p.promptID) }
        if q.running.first?.promptID != prevRunning { lastConsoleBar = nil }
        if let r = q.running.first, r.promptID != prevRunning {
            seenRunningAt[r.promptID] = Date()
            log.add(.state, "running job \(Confirmations.short(r.promptID)) (\(source(of: r).label), \(source(of: r).evidence))")
            unacknowledgedFailure = nil   // a new job started: the failure is old news
        }
        queue = q
        if q.running.isEmpty { runningStart = nil }
    }

    private func applyJobs(_ jobs: [Job]) {
        let finishedIDs = jobs.filter { $0.status.isFinished }.map(\.id)
        let finished: [Job]
        if let known = knownFinished {
            finished = StateMachine.newlyFinished(previouslyActive: activeIDs, known: known,
                                                  watchingSinceMs: watchingSinceMs, now: jobs)
        } else {
            finished = []   // first answer: what is already finished is history, not news
            watchingSinceMs = Int64(Date().timeIntervalSince1970 * 1000)
        }
        knownFinished = (knownFinished ?? []).union(finishedIDs)
        for j in finished {
            let dur = j.durationSeconds.map(Format.seconds) ?? "?"
            log.add(.state, "job \(Confirmations.short(j.id)) \(j.status.rawValue) in \(dur)")
            switch j.status {
            case .completed:
                if settings.notifyFinished {
                    notifier.post(title: "ComfyUI job finished", body: "\(Confirmations.short(j.id))… in \(dur)\(j.previewFilename.map { " - \($0)" } ?? "")")
                }
            case .failed:
                unacknowledgedFailure = j
                if settings.notifyFailed {
                    notifier.post(title: "ComfyUI job failed", body: "\(Confirmations.short(j.id))…\(j.errorNodeType.map { " at \($0)" } ?? ""): \(j.errorMessage ?? "no message")")
                }
            case .cancelled:
                break   // someone chose to end it; not a failure
            default: break
            }
            socketProgress[j.id] = nil
            socketNode[j.id] = nil
        }
        activeIDs = Set(jobs.filter { $0.status.isActive }.map(\.id))
        recent = Array(jobs.filter { $0.status.isFinished }.prefix(settings.recentCount))
        if let r = runningItem {
            runningStart = StateMachine.estimateStart(createTimeMs: r.createTimeMs,
                                                      finishedJobs: jobs.filter { $0.status.isFinished },
                                                      seenRunningAt: seenRunningAt[r.promptID],
                                                      seenPendingBefore: seenPending.contains(r.promptID))
        }
        refreshProgress()
    }

    private var lastConsoleBar: TqdmProgress?

    private func applyLogs(_ entries: [LogEntry]) {
        // Console timestamps are the server's naive local time (app/logger.py:61), comparable
        // with ours only on this Mac - so the bar is used for local servers only, and never
        // from before the running job's start.
        guard LaunchGuard.isLoopback(settings.host), let start = runningStart?.date else { lastConsoleBar = nil; return }
        lastConsoleBar = Tqdm.latest(in: entries, notBefore: start)
        refreshProgress()
    }

    private func refreshProgress() {
        guard let r = runningItem else { progress = nil; return }
        if let s = socketProgress[r.promptID] {
            progress = CurrentProgress(value: s.value, max: s.max, node: s.node ?? socketNode[r.promptID],
                                       source: .socket, barRemainingSeconds: nil, barClosed: false)
        } else if let b = lastConsoleBar {
            progress = CurrentProgress(value: b.current, max: b.total, node: nil, source: .consoleBar,
                                       barRemainingSeconds: b.closed ? nil : b.remainingSeconds, barClosed: b.closed)
        } else {
            progress = nil
        }
        if let p = progress {
            let key = "\(r.promptID) \(p.value)/\(p.max) \(p.source.rawValue)"
            if key != lastStepLogged, p.value == 1 || p.value == p.max || p.value % 10 == 0 || p.source == .consoleBar {
                log.add(.state, "progress \(Confirmations.short(r.promptID)) \(p.value)/\(p.max) via \(p.source.rawValue)")
                lastStepLogged = key
            }
        }
    }

    func acknowledgeFailure() {
        if unacknowledgedFailure != nil {
            unacknowledgedFailure = nil
            log.add(.state, "failure acknowledged (panel opened)")
            let obs = Observation(reachability: reachability ?? .refused, processListening: listener != nil,
                                  runningCount: queue.running.count, pendingCount: queue.pending.count,
                                  unacknowledgedFailure: false)
            iconState = StateMachine.iconState(obs)
            onChange?()
        }
    }
}
