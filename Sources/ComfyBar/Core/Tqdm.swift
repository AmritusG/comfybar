import Foundation

/// Step progress read from ComfyUI's own console, via GET /internal/logs/raw.
///
/// Why this route: websocket "progress"/"progress_state" go only to the client that queued
/// the prompt (main.py:471, progress.py:183-185). Samplers print a tqdm bar to stderr
/// (comfy/k_diffusion/sampling.py:194 via comfy/utils.py:1264 model_trange); ComfyUI's
/// LogInterceptor keeps the last 300 writes and collapses "\r" rewrites to the latest one
/// (app/logger.py:60-70). Reading that buffer is a plain GET: it steals nothing from any
/// client. Caveats (stated in the UI): the route is /internal (not a stable API), and only
/// loops that print tqdm show up - ComfyUI's ProgressBar hook alone does not print.
struct TqdmProgress: Equatable {
    let percent: Int
    let current: Int
    let total: Int
    let elapsedSeconds: Int?
    /// tqdm's own estimate for the remainder of THIS bar (one sampler pass), not the job.
    let remainingSeconds: Int?
    let rate: String?
    /// Bar written with a closing newline after it: this pass is over.
    let closed: Bool
    let time: Date?
}

enum Tqdm {
    static func stripANSI(_ s: String) -> String {
        s.replacingOccurrences(of: "\u{1B}\\[[0-9;]*[A-Za-z]", with: "", options: .regularExpression)
    }

    /// "1:02:03" / "02:03" / "?" -> seconds
    static func clock(_ s: String) -> Int? {
        let parts = s.split(separator: ":").map { Int($0) }
        guard !parts.isEmpty, parts.allSatisfy({ $0 != nil }) else { return nil }
        return parts.reduce(0) { $0 * 60 + $1! }
    }

    private static let re = try! NSRegularExpression(
        pattern: #"(\d{1,3})%\|[^|]*\|\s*(\d+)/(\d+)\s*\[([0-9:]+)<([0-9:?]+)(?:,\s*([^,\]]+))?"#)

    static func parse(_ line: String, time: Date? = nil, closed: Bool = false) -> TqdmProgress? {
        let s = stripANSI(line).replacingOccurrences(of: "\r", with: "")
        let ns = s as NSString
        guard let m = re.matches(in: s, range: NSRange(location: 0, length: ns.length)).last else { return nil }
        func g(_ i: Int) -> String? {
            let r = m.range(at: i)
            return r.location == NSNotFound ? nil : ns.substring(with: r)
        }
        guard let pct = g(1).flatMap(Int.init), let cur = g(2).flatMap(Int.init),
              let tot = g(3).flatMap(Int.init), tot > 0 else { return nil }
        return TqdmProgress(percent: pct, current: cur, total: tot,
                            elapsedSeconds: g(4).flatMap(clock),
                            remainingSeconds: g(5).flatMap(clock),
                            rate: g(6)?.trimmingCharacters(in: .whitespaces),
                            closed: closed, time: time)
    }

    /// The most recent tqdm bar in the buffer, if it was written at or after `notBefore`
    /// (so a bar from a previous job is never attributed to the current one).
    static func latest(in entries: [LogEntry], notBefore: Date?) -> TqdmProgress? {
        var closed = false
        for e in entries.reversed() {
            if let p = parse(e.message, time: e.time, closed: closed) {
                if let nb = notBefore, let t = e.time, t < nb { return nil }
                return p
            }
            // A bare newline written after the bar is tqdm closing it.
            if stripANSI(e.message).trimmingCharacters(in: .whitespaces) == "\n" || e.message == "\n" {
                closed = true
            } else if !e.message.hasPrefix("\r") {
                // Any other console line after the bar: the bar is no longer the live line.
                closed = true
            }
        }
        return nil
    }
}
