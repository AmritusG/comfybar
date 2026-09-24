import Foundation

/// HTTP client for one ComfyUI server. GET routes are reads; every POST is a control and
/// is only ever called from a user action (or the guarded automation path, never on 8188).
final class ComfyClient {
    let base: URL
    private let session: URLSession
    private let log: EventLog?

    init(base: URL, log: EventLog?, timeout: TimeInterval = 4) {
        self.base = base
        self.log = log
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = timeout
        cfg.timeoutIntervalForResource = timeout * 2
        cfg.waitsForConnectivity = false
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: cfg)
    }

    enum ClientError: Error, CustomStringConvertible {
        case refused
        case http(Int, String)
        case transport(String)

        var description: String {
            switch self {
            case .refused: return "connection refused"
            case .http(let c, let b): return "HTTP \(c) \(b.prefix(120))"
            case .transport(let s): return s
            }
        }
    }

    private func url(_ path: String) -> URL {
        URL(string: path, relativeTo: base)!.absoluteURL
    }

    func request(_ method: String, _ path: String, json: Any? = nil, quiet: Bool = false) async throws -> Data {
        var req = URLRequest(url: url(path))
        req.httpMethod = method
        if let json {
            req.httpBody = try JSONSerialization.data(withJSONObject: json)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if !quiet { log?.add(.request, "\(method) \(path)\(json.map { " " + Self.brief($0) } ?? "")") }
        let t0 = Date()
        do {
            let (data, resp) = try await session.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            if !quiet || code >= 400 {
                log?.add(.response, "\(code) \(method) \(path) \(data.count)B \(ms)ms")
            }
            guard (200..<300).contains(code) else {
                throw ClientError.http(code, String(decoding: data.prefix(300), as: UTF8.self))
            }
            return data
        } catch let e as URLError {
            let err: ClientError = (e.code == .cannotConnectToHost) ? .refused : .transport(e.localizedDescription)
            if !quiet { log?.add(.error, "\(method) \(path): \(err)") }
            throw err
        }
    }

    static func brief(_ json: Any) -> String {
        guard let d = try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]) else { return "" }
        let s = String(decoding: d, as: UTF8.self)
        return s.count > 160 ? String(s.prefix(160)) + "…" : s
    }

    // MARK: reads (GET)

    func systemStats(quiet: Bool = false) async throws -> SystemStats {
        try ComfyParse.systemStats(try await request("GET", "/system_stats", quiet: quiet))
    }
    func queue(quiet: Bool = false) async throws -> QueueSnapshot {
        try ComfyParse.queue(try await request("GET", "/queue", quiet: quiet))
    }
    func jobs(limit: Int, statuses: [String]? = nil, quiet: Bool = false) async throws -> [Job] {
        var path = "/api/jobs?limit=\(limit)&sort_by=created_at&sort_order=desc"
        if let s = statuses { path += "&status=" + s.joined(separator: ",") }
        return try ComfyParse.jobs(try await request("GET", path, quiet: quiet))
    }
    func logsRaw(quiet: Bool = false) async throws -> [LogEntry] {
        try ComfyParse.logsRaw(try await request("GET", "/internal/logs/raw", quiet: quiet))
    }

    // MARK: controls (POST) - server.py:1146-1201, 971-1043

    func interrupt(promptID: String) async throws {
        _ = try await request("POST", "/interrupt", json: ["prompt_id": promptID])
    }
    func cancel(jobID: String) async throws -> Bool {
        let d = try await request("POST", "/api/jobs/\(jobID)/cancel", json: [String: Any]())
        return ((try? ComfyParse.object(d))?["cancelled"] as? Bool) ?? false
    }
    /// POST /queue {"clear": true} - wipes PENDING only (execution.py wipe_queue); the
    /// running job is untouched.
    func clearQueue() async throws {
        _ = try await request("POST", "/queue", json: ["clear": true])
    }
    /// POST /free - sets flags the prompt worker acts on between jobs (server.py:1192).
    func free() async throws {
        _ = try await request("POST", "/free", json: ["unload_models": true, "free_memory": true])
    }
    func queuePrompt(_ graph: [String: Any], clientID: String) async throws -> String {
        let d = try await request("POST", "/prompt", json: ["prompt": graph, "client_id": clientID])
        guard let pid = (try ComfyParse.object(d))["prompt_id"] as? String else { throw ParseError.missing("prompt_id") }
        return pid
    }
}
