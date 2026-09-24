import Foundation

/// What one poll of the server found.
enum Reachability: Equatable {
    case up
    /// Connection refused: nothing listening on host:port.
    case refused
    /// Anything else (timeout, HTTP error, garbage) - something is there but not answering.
    case failed(String)
}

/// The five states the menu-bar glyph shows.
enum IconState: String, CaseIterable {
    case notRunning, idle, running, queued, error

    var title: String {
        switch self {
        case .notRunning: return "Not running"
        case .idle: return "Idle"
        case .running: return "Running a job"
        case .queued: return "Jobs queued"
        case .error: return "Error / unreachable"
        }
    }
}

struct Observation: Equatable {
    var reachability: Reachability
    /// A process is listening on the port (lsof); nil when unknown (remote host).
    var processListening: Bool?
    var runningCount: Int
    var pendingCount: Int
    /// A job failed and nobody has opened the panel since, and no new job has started.
    var unacknowledgedFailure: Bool
}

enum StateMachine {
    static func iconState(_ o: Observation) -> IconState {
        switch o.reachability {
        case .refused:
            // Refused but a process holds the port -> it is there and broken, not absent.
            return o.processListening == true ? .error : .notRunning
        case .failed:
            return .error
        case .up:
            if o.pendingCount > 0 { return .queued }
            if o.runningCount > 0 { return .running }
            return o.unacknowledgedFailure ? .error : .idle
        }
    }

    /// Up -> not up: "server went down" (notification 3).
    static func wentDown(from old: Reachability?, to new: Reachability) -> Bool {
        old == .up && new != .up
    }

    /// A timeout can be a busy server (event loop stalled by a big model load), not a dead one.
    /// Report it only after this many consecutive failed polls; "connection refused" is certain
    /// and counts at once.
    static let failuresBeforeDown = 3

    static func debounce(previous: Reachability?, raw: Reachability, consecutiveFailures: Int) -> Reachability {
        if case .failed = raw, previous == .up, consecutiveFailures < failuresBeforeDown { return .up }
        return raw
    }

    /// Finished jobs to announce: ones seen active before, plus ones that were queued AND
    /// finished between two polls (never seen active) - but never history that merely scrolled
    /// into the listing, hence the "created since we started watching" bound.
    static func newlyFinished(previouslyActive: Set<String>, known: Set<String>, watchingSinceMs: Int64,
                              now jobs: [Job]) -> [Job] {
        jobs.filter { j in
            guard j.status.isFinished, !known.contains(j.id) else { return false }
            return previouslyActive.contains(j.id) || (j.createTimeMs ?? 0) >= watchingSinceMs
        }
    }

    /// When did the running job start? /queue and /api/jobs carry no start time for a job
    /// that is still running (jobs.py:186 normalize_queue_item). ComfyUI runs one prompt at
    /// a time (main.py prompt_worker), so a job starts when it was queued or when the job
    /// before it ended, whichever is later. If ComfyBar saw the job go from pending to
    /// running, that sighting is an upper bound and the tighter figure wins.
    struct StartEstimate: Equatable {
        let date: Date
        let basis: String
    }

    static func estimateStart(createTimeMs: Int64?, finishedJobs: [Job], seenRunningAt: Date?,
                              seenPendingBefore: Bool) -> StartEstimate? {
        let created = createTimeMs.map { Date(timeIntervalSince1970: Double($0) / 1000) }
        let lastEnd = finishedJobs.compactMap(\.endTimeMs).max().map { Date(timeIntervalSince1970: Double($0) / 1000) }
        var derived: StartEstimate?
        switch (created, lastEnd) {
        case let (c?, e?) where e > c:
            derived = StartEstimate(date: e, basis: "previous job's end")
        case let (c?, _):
            derived = StartEstimate(date: c, basis: "queued time (queue was empty)")
        default:
            derived = nil
        }
        if seenPendingBefore, let seen = seenRunningAt {
            // Observed transition. Use the derived figure if it is consistent with the
            // sighting (earlier), else the sighting.
            if let d = derived, d.date <= seen { return d }
            return StartEstimate(date: seen, basis: "seen starting by ComfyBar")
        }
        return derived
    }
}
