import Foundation

// Payload shapes, as read from ~/ComfyUI 0.34.0 (commit 77739723). File:line cites are in
// docs/GROUNDING.md. Parsing is deliberately loose (JSONSerialization): ComfyUI payloads
// are untyped Python dicts and fields come and go between versions.

enum ParseError: Error, Equatable {
    case notJSON
    case missing(String)
}

// MARK: - GET /system_stats  (server.py:686)

struct SystemStats: Equatable {
    struct Device: Equatable {
        let name: String
        let type: String
        let vramTotal: Int64
        let vramFree: Int64
    }
    let os: String
    let comfyVersion: String
    let pythonVersion: String
    let pytorchVersion: String
    /// comfy.system_memory.virtual_memory_total() -> psutil total (host RAM on macOS).
    let ramTotal: Int64
    /// psutil.virtual_memory().available = inactive + free_count (psutil _psosx.py:97).
    /// NOT ComfyBar's AVAILABLE definition (no purgeable) - ComfyBar does not display it as such.
    let ramFree: Int64
    let argv: [String]
    let devices: [Device]
}

// MARK: - GET /queue  (server.py:1064)

/// One queue tuple: (number, prompt_id, prompt, extra_data, outputs_to_execute)
/// with the sensitive 6th element removed (server.py:69).
struct QueueItem: Equatable {
    let number: Double
    let promptID: String
    /// extra_data.client_id - set when the queuing client passed one (server.py:1116).
    let clientID: String?
    /// extra_data.create_time, ms since epoch, stamped at POST /prompt (server.py:1130).
    let createTimeMs: Int64?
    /// Every filename_prefix input in the graph (SaveImage / SaveVideo / ...).
    let outputPrefixes: [String]
    /// extra_data.extra_pnginfo.workflow present - the ComfyUI page attaches its workflow.
    let hasWorkflow: Bool
    let nodeCount: Int
}

struct QueueSnapshot: Equatable {
    let running: [QueueItem]
    let pending: [QueueItem]
    static let empty = QueueSnapshot(running: [], pending: [])
}

// MARK: - GET /api/jobs  (server.py:821, comfy_execution/jobs.py)

enum JobStatus: String, Equatable {
    case pending, inProgress = "in_progress", completed, failed, cancelled, unknown
    var isActive: Bool { self == .pending || self == .inProgress }
    var isFinished: Bool { self == .completed || self == .failed || self == .cancelled }
}

struct Job: Equatable, Identifiable {
    let id: String
    let status: JobStatus
    let priority: Double?
    let createTimeMs: Int64?
    /// Timestamp of the execution_start status message (jobs.py:231). History only.
    let startTimeMs: Int64?
    /// Timestamp of execution_success / _error / _interrupted (jobs.py:233). History only.
    let endTimeMs: Int64?
    let errorMessage: String?
    let errorNodeType: String?
    let outputsCount: Int
    let previewFilename: String?
    let previewSubfolder: String?

    /// Wall time between ComfyUI's own start and end messages. Nil unless both exist.
    var durationSeconds: Double? {
        guard let s = startTimeMs, let e = endTimeMs, e >= s else { return nil }
        return Double(e - s) / 1000
    }
}

// MARK: - GET /internal/logs/raw  (api_server/routes/internal/internal_routes.py:26)

struct LogEntry: Equatable {
    /// datetime.now().isoformat() in the server's local time (app/logger.py:61).
    let time: Date?
    let message: String
}

// MARK: - websocket  (server.py:269)

enum SocketMessage: Equatable {
    /// Broadcast on every queue change (server.py:1396 queue_updated) and on connect.
    case status(queueRemaining: Int, sid: String?)
    /// Per-client unless the prompt had no client_id (execution.py:736 -> sid None = broadcast).
    case progress(value: Int, max: Int, promptID: String?, node: String?)
    case executing(node: String?, promptID: String?)
    case executionStart(promptID: String)
    case executionSuccess(promptID: String)
    case executionError(promptID: String, message: String?)
    case executionInterrupted(promptID: String)
    case other(type: String)
}

enum ComfyParse {
    static func object(_ data: Data) throws -> [String: Any] {
        guard let o = try? JSONSerialization.jsonObject(with: data), let d = o as? [String: Any] else {
            throw ParseError.notJSON
        }
        return d
    }

    static func int64(_ v: Any?) -> Int64? {
        switch v {
        case let n as NSNumber: return n.int64Value
        case let s as String: return Int64(s)
        default: return nil
        }
    }

    static func double(_ v: Any?) -> Double? {
        (v as? NSNumber)?.doubleValue
    }

    static func systemStats(_ data: Data) throws -> SystemStats {
        let d = try object(data)
        guard let sys = d["system"] as? [String: Any] else { throw ParseError.missing("system") }
        let devs = (d["devices"] as? [[String: Any]] ?? []).map {
            SystemStats.Device(name: $0["name"] as? String ?? "?",
                               type: $0["type"] as? String ?? "?",
                               vramTotal: int64($0["vram_total"]) ?? 0,
                               vramFree: int64($0["vram_free"]) ?? 0)
        }
        return SystemStats(os: sys["os"] as? String ?? "?",
                           comfyVersion: sys["comfyui_version"] as? String ?? "?",
                           pythonVersion: (sys["python_version"] as? String ?? "?").components(separatedBy: " ").first ?? "?",
                           pytorchVersion: sys["pytorch_version"] as? String ?? "?",
                           ramTotal: int64(sys["ram_total"]) ?? 0,
                           ramFree: int64(sys["ram_free"]) ?? 0,
                           argv: sys["argv"] as? [String] ?? [],
                           devices: devs)
    }

    static func queueItem(_ raw: Any) -> QueueItem? {
        guard let t = raw as? [Any], t.count >= 4,
              let number = double(t[0]), let pid = t[1] as? String else { return nil }
        let graph = t[2] as? [String: Any] ?? [:]
        let extra = t[3] as? [String: Any] ?? [:]
        var prefixes: [String] = []
        for (_, node) in graph {
            if let n = node as? [String: Any], let inputs = n["inputs"] as? [String: Any],
               let p = inputs["filename_prefix"] as? String {
                prefixes.append(p)
            }
        }
        prefixes.sort()
        let pnginfo = extra["extra_pnginfo"] as? [String: Any]
        return QueueItem(number: number, promptID: pid,
                         clientID: extra["client_id"] as? String,
                         createTimeMs: int64(extra["create_time"]),
                         outputPrefixes: prefixes,
                         hasWorkflow: pnginfo?["workflow"] != nil,
                         nodeCount: graph.count)
    }

    static func queue(_ data: Data) throws -> QueueSnapshot {
        let d = try object(data)
        guard let r = d["queue_running"] as? [Any], let p = d["queue_pending"] as? [Any] else {
            throw ParseError.missing("queue_running/queue_pending")
        }
        // ComfyUI executes pending items in ascending `number` order (heapq, execution.py:1262-1274).
        let pending = p.compactMap(queueItem).sorted { $0.number < $1.number }
        return QueueSnapshot(running: r.compactMap(queueItem), pending: pending)
    }

    static func job(_ j: [String: Any]) -> Job? {
        guard let id = j["id"] as? String else { return nil }
        let err = j["execution_error"] as? [String: Any]
        let preview = j["preview_output"] as? [String: Any]
        return Job(id: id,
                   status: JobStatus(rawValue: j["status"] as? String ?? "") ?? .unknown,
                   priority: double(j["priority"]),
                   createTimeMs: int64(j["create_time"]),
                   startTimeMs: int64(j["execution_start_time"]),
                   endTimeMs: int64(j["execution_end_time"]),
                   errorMessage: err?["exception_message"] as? String,
                   errorNodeType: err?["node_type"] as? String,
                   outputsCount: Int(int64(j["outputs_count"]) ?? 0),
                   previewFilename: preview?["filename"] as? String,
                   previewSubfolder: preview?["subfolder"] as? String)
    }

    static func jobs(_ data: Data) throws -> [Job] {
        let d = try object(data)
        guard let list = d["jobs"] as? [[String: Any]] else { throw ParseError.missing("jobs") }
        return list.compactMap(job)
    }

    private static let isoLocal: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current  // Python's naive datetime.now() is local time
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSS"
        return f
    }()
    private static let isoLocalNoFrac: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return f
    }()

    static func logTime(_ s: String) -> Date? {
        isoLocal.date(from: s) ?? isoLocalNoFrac.date(from: s)
    }

    static func logsRaw(_ data: Data) throws -> [LogEntry] {
        let d = try object(data)
        guard let e = d["entries"] as? [[String: Any]] else { throw ParseError.missing("entries") }
        return e.map { LogEntry(time: ($0["t"] as? String).flatMap(logTime), message: $0["m"] as? String ?? "") }
    }

    static func socketMessage(_ text: String) -> SocketMessage? {
        guard let data = text.data(using: .utf8), let d = try? object(data),
              let type = d["type"] as? String else { return nil }
        let body = d["data"] as? [String: Any] ?? [:]
        let pid = body["prompt_id"] as? String
        switch type {
        case "status":
            let st = body["status"] as? [String: Any]
            let ei = st?["exec_info"] as? [String: Any]
            guard let q = int64(ei?["queue_remaining"]) else { return .other(type: type) }
            return .status(queueRemaining: Int(q), sid: body["sid"] as? String)
        case "progress":
            return .progress(value: Int(int64(body["value"]) ?? 0), max: Int(int64(body["max"]) ?? 0),
                             promptID: pid, node: body["node"] as? String)
        case "executing":
            return .executing(node: body["node"] as? String, promptID: pid)
        case "execution_start":
            return pid.map { .executionStart(promptID: $0) } ?? .other(type: type)
        case "execution_success":
            return pid.map { .executionSuccess(promptID: $0) } ?? .other(type: type)
        case "execution_error":
            return pid.map { .executionError(promptID: $0, message: body["exception_message"] as? String) } ?? .other(type: type)
        case "execution_interrupted":
            return pid.map { .executionInterrupted(promptID: $0) } ?? .other(type: type)
        default:
            return .other(type: type)
        }
    }
}
