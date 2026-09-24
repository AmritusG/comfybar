import AppKit

/// Every control goes through perform() - the panel buttons and the automation hook alike -
/// so what the tests exercise is what a person clicks.
@MainActor
final class Actions {
    private let monitor: Monitor
    private let server: ServerController
    private let log: EventLog
    private let settings: AppSettings
    /// Automation mode: confirmations are shown, logged verbatim, and auto-answered.
    var autoConfirmAfter: TimeInterval?
    var autoConfirmAnswer = true
    /// Called before a modal alert so the panel can get out of the way.
    var willPresentModal: (() -> Void)?

    init(monitor: Monitor, server: ServerController, log: EventLog, settings: AppSettings) {
        self.monitor = monitor
        self.server = server
        self.log = log
        self.settings = settings
    }

    // MARK: confirmation

    private func confirm(_ title: String, _ body: String, button: String) -> Bool {
        log.add(.control, "CONFIRM \"\(title)\" | \(body.replacingOccurrences(of: "\n", with: " | "))")
        willPresentModal?()
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.alertStyle = .warning
        a.messageText = title
        a.informativeText = body
        a.addButton(withTitle: button)
        a.addButton(withTitle: "Cancel")
        if let t = autoConfirmAfter {
            let answer: NSApplication.ModalResponse = autoConfirmAnswer ? .alertFirstButtonReturn : .alertSecondButtonReturn
            let timer = Timer(timeInterval: t, repeats: false) { _ in NSApp.stopModal(withCode: answer) }
            RunLoop.main.add(timer, forMode: .modalPanel)
        }
        let ok = a.runModal() == .alertFirstButtonReturn
        log.add(.control, "CONFIRM answer: \(ok ? button : "Cancel")")
        return ok
    }

    private func report(_ s: String, error: Bool = false) {
        log.add(error ? .error : .control, s)
        monitor.busyMessage = s
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
            if self?.monitor.busyMessage == s { self?.monitor.busyMessage = nil }
        }
    }

    // MARK: perform

    func perform(_ action: ControlAction, arg: String? = nil) async {
        log.add(.control, "action \(action.rawValue)\(arg.map { " \($0)" } ?? "") on \(settings.hostPort)")
        let hostPort = settings.hostPort
        let pending = monitor.queue.pending.count
        let running = monitor.runningInfo

        if action.endsWork {
            var target: String?
            if action == .cancel {
                target = (arg == nil || arg == "first") ? monitor.queue.pending.first?.promptID : arg
                if target == nil { report("Nothing queued to cancel."); return }
            }
            if let t = Confirmations.text(for: action, hostPort: hostPort, running: running,
                                           pendingCount: pending, cancelTarget: target) {
                let button = ["stop": "Stop", "restart": "Restart", "interrupt": "Interrupt",
                              "clear": "Clear Queue", "cancel": "Cancel Job"][action.rawValue] ?? "OK"
                guard confirm(t.title, t.body, button: button) else { report("\(action.rawValue) cancelled - nothing changed."); return }
            } else if action == .interrupt || action == .clear {
                report(action == .interrupt ? "Nothing is running." : "The queue is empty.")
                return
            }
            if action == .cancel, let t = target {
                do {
                    let ok = try await monitor.client.cancel(jobID: t)
                    report(ok ? "Cancelled \(Confirmations.short(t))…" : "\(Confirmations.short(t))… was no longer queued.")
                } catch { report("Cancel failed: \(error)", error: true) }
                monitor.pokePoll()
                return
            }
        }

        do {
            switch action {
            case .start:
                let pid = try server.start(folder: settings.comfyFolder, host: settings.host, port: settings.port, extra: settings.extraArgs)
                report("Starting ComfyUI (pid \(pid)) on \(hostPort)…")
            case .stop:
                guard let l = monitor.listener else { report("Nothing is listening on \(hostPort)."); return }
                report("Stopping pid \(l.pid)…")
                let r = try await server.stop(pid: l.pid, port: settings.port, folder: settings.comfyFolder)
                report("Stopped: \(r)")
            case .restart:
                if let l = monitor.listener {
                    report("Restart: stopping pid \(l.pid)…")
                    _ = try await server.stop(pid: l.pid, port: settings.port, folder: settings.comfyFolder)
                }
                let pid = try server.start(folder: settings.comfyFolder, host: settings.host, port: settings.port, extra: settings.extraArgs)
                report("Restart: started pid \(pid)")
            case .interrupt:
                guard let r = running else { return }
                try await monitor.client.interrupt(promptID: r.promptID)
                report("Interrupt sent for \(Confirmations.short(r.promptID))…")
            case .clear:
                try await monitor.client.clearQueue()
                report("Queue cleared (\(pending) removed).")
            case .free:
                try await monitor.client.free()
                report("Free memory requested - ComfyUI acts on it between jobs.")
            case .calibrate:
                guard settings.port != 8188 else { report("Calibration never runs on 8188.", error: true); return }
                let parts = (arg ?? "").split(separator: " ").compactMap { Int($0) }
                let frames = parts.first ?? 300
                let stages = parts.count > 1 ? parts[1] : 4
                let size = parts.count > 2 ? parts[2] : 256
                let g = Calibration.graph(frames: frames, stages: stages, size: size, seed: Int(Date().timeIntervalSince1970))
                let pid = try await monitor.client.queuePrompt(g, clientID: monitor.socket.clientID)
                report("Calibration job \(Confirmations.short(pid))… queued (\(frames) frames × \(stages) stages at \(size)px)")
            case .openBrowser:
                if let u = settings.baseURL { NSWorkspace.shared.open(u); log.add(.control, "opened \(u.absoluteString) in the browser") }
            case .openOutput:
                let dir = outputDirectory()
                try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
                NSWorkspace.shared.open(URL(fileURLWithPath: dir))
                log.add(.control, "opened output folder \(dir)")
            case .openLog:
                let url = await logFile()
                NSWorkspace.shared.open(url)
                log.add(.control, "opened log \(url.path)")
            case .cancel:
                break
            }
        } catch {
            report("\(action.rawValue) failed: \(error)", error: true)
        }
        monitor.pokePoll()
    }

    /// The server's own --output-directory when it reports one (system_stats argv), else
    /// <folder>/output (folder_paths default).
    func outputDirectory() -> String {
        if let argv = monitor.stats?.argv, let i = argv.firstIndex(of: "--output-directory"), i + 1 < argv.count {
            return argv[i + 1]
        }
        return settings.comfyFolder + "/output"
    }

    /// ComfyBar's own capture when it started this server; else the console log ComfyUI's
    /// user directory holds (<folder>/user/comfyui.log, written by ComfyUI-Manager's
    /// prestartup, where installed); else a snapshot of ComfyUI's 300-line console buffer.
    func logFile() async -> URL {
        if server.ownPort == settings.port, let u = server.ownLogURL { return u }
        var userDir = settings.comfyFolder + "/user"
        if let argv = monitor.stats?.argv, let i = argv.firstIndex(of: "--user-directory"), i + 1 < argv.count {
            userDir = argv[i + 1]
        }
        let own = ServerController.logDirectory.appendingPathComponent("comfyui-\(settings.port).log")
        let candidates = [userDir + "/comfyui.log", own.path]
        if let c = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }) {
            return URL(fileURLWithPath: c)
        }
        let snap = ServerController.logDirectory.appendingPathComponent("console-buffer-\(settings.port).log")
        try? FileManager.default.createDirectory(at: ServerController.logDirectory, withIntermediateDirectories: true)
        let text = ((try? await monitor.client.logsRaw()) ?? []).map { Tqdm.stripANSI($0.message) }.joined()
        try? text.write(to: snap, atomically: true, encoding: .utf8)
        return snap
    }
}
