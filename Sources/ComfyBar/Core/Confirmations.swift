import Foundation

enum ControlAction: String, CaseIterable {
    case start, stop, restart, interrupt, cancel, clear, free
    case openBrowser, openOutput, openLog, calibrate

    /// Actions that can end work in progress ask first.
    var endsWork: Bool { [.stop, .restart, .interrupt, .clear, .cancel].contains(self) }
    var mutatesServer: Bool { ![.openBrowser, .openOutput, .openLog].contains(self) }
}

/// The running job as the confirmation needs to name it.
struct RunningJobInfo: Equatable {
    let promptID: String
    let source: JobSource
    let elapsedSeconds: Int?
}

enum Confirmations {
    static func short(_ id: String) -> String { String(id.prefix(8)) }

    static func describe(_ r: RunningJobInfo) -> String {
        var s = "job \(short(r.promptID))…"
        if let e = r.elapsedSeconds { s += " (running \(Format.duration(e)))" }
        s += ", queued by \(r.source.label) (\(r.source.evidence))"
        return s
    }

    /// Returns nil when there is nothing to confirm (nothing would end).
    static func text(for action: ControlAction, hostPort: String, running: RunningJobInfo?,
                     pendingCount: Int, cancelTarget: String? = nil) -> (title: String, body: String)? {
        let run = running.map(describe)
        let queued = pendingCount == 1 ? "1 queued job" : "\(pendingCount) queued jobs"
        switch action {
        case .stop, .restart:
            let verb = action == .stop ? "Stop" : "Restart"
            var lines = ["\(verb) ComfyUI on \(hostPort)."]
            if let run { lines.append("This ends the running \(run).") }
            if pendingCount > 0 { lines.append("\(queued) will be lost (ComfyUI keeps no queue across restarts).") }
            if run == nil && pendingCount == 0 { lines.append("Nothing is running or queued.") }
            return ("\(verb) ComfyUI?", lines.joined(separator: "\n"))
        case .interrupt:
            guard let run else { return nil }
            return ("Interrupt the running job?", "This ends the running \(run).\nQueued jobs continue.")
        case .clear:
            guard pendingCount > 0 else { return nil }
            return ("Clear the queue?", "This removes \(queued) that have not started.\nThe running job, if any, continues.")
        case .cancel:
            guard let t = cancelTarget else { return nil }
            return ("Cancel queued job \(short(t))…?", "This removes it from the queue before it starts.")
        default:
            return nil
        }
    }
}

enum Format {
    static func duration(_ s: Int) -> String {
        if s < 60 { return "\(s)s" }
        if s < 3600 { return String(format: "%dm %02ds", s / 60, s % 60) }
        return String(format: "%dh %02dm", s / 3600, (s % 3600) / 60)
    }

    /// Job durations: tenths under 10 s (framer steps finish in well under a second).
    static func seconds(_ s: Double) -> String {
        s < 10 ? String(format: "%.1fs", s) : duration(Int(s.rounded()))
    }

    static func bytes(_ b: UInt64) -> String {
        let gib = Double(b) / 1_073_741_824
        if gib >= 10 { return String(format: "%.0f GiB", gib) }
        if gib >= 1 { return String(format: "%.1f GiB", gib) }
        return String(format: "%.0f MiB", Double(b) / 1_048_576)
    }
}
