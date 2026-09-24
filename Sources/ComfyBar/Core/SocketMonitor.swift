import Foundation

/// A listening websocket under ComfyBar's OWN fresh client id - never another client's.
///
/// Measured on a scratch instance (8199): connecting with another client's clientId evicts
/// that client's socket from server.sockets (server.py:273-276) and it receives nothing
/// further, even after ours closes. So ComfyBar only ever joins as itself. What its own
/// socket receives:
///   - "status" (queue_remaining) - broadcast on every queue change;
///   - full progress for prompts queued with NO client_id (execution.py:736-739 sets
///     server.client_id = None, and send_sync(..., None) broadcasts, server.py:1385-1388);
///   - progress for ComfyBar's own calibration job.
///
/// Threading: every callback (URLSession delegate, receive completions, reconnect timer) runs
/// on the main queue, so the state below is only ever touched from one thread.
final class SocketMonitor: NSObject, URLSessionWebSocketDelegate {
    let clientID: String
    private let url: URL?
    private let log: EventLog?
    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var stopped = true
    private var generation = 0
    private var isOpen = false
    private var ignoredTypesLogged: Set<String> = []
    var onMessage: ((SocketMessage) -> Void)?
    var onConnected: ((Bool) -> Void)?

    init(host: String, port: Int, log: EventLog?) {
        clientID = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        var c = URLComponents()
        c.scheme = "ws"; c.host = host; c.port = port; c.path = "/ws"
        c.queryItems = [URLQueryItem(name: "clientId", value: clientID)]
        url = c.url   // nil for a host that cannot form a URL: the monitor then never connects
        self.log = log
        super.init()
    }

    func start() {
        guard stopped, url != nil else { return }
        stopped = false
        if session == nil {
            session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: .main)
        }
        connect()
    }

    func stop() {
        stopped = true
        generation += 1
        isOpen = false
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
        session?.invalidateAndCancel()
        session = nil
    }

    private func connect() {
        guard !stopped, let url, let session else { return }
        generation += 1
        let gen = generation
        let t = session.webSocketTask(with: url)
        t.maximumMessageSize = 16 << 20  // preview images can be large; we drop them
        task = t
        t.resume()
        receive(t, gen)
    }

    private func receive(_ t: URLSessionWebSocketTask, _ gen: Int) {
        t.receive { [weak self] result in
            guard let self, gen == self.generation else { return }
            switch result {
            case .success(.string(let s)):
                if let m = ComfyParse.socketMessage(s) {
                    if case .other(let type) = m {
                        // progress_state etc. arrive many times a second; note each type once
                        if self.ignoredTypesLogged.insert(type).inserted {
                            self.log?.add(.socket, "\(type) (not used; further ones not logged)")
                        }
                    } else if case .progress = m {
                        // progress floods; the state layer logs step changes
                    } else {
                        self.log?.add(.socket, "\(m)")
                    }
                    self.onMessage?(m)
                }
                self.receive(t, gen)
            case .success:
                self.receive(t, gen)   // binary previews: not ours to show
            case .failure(let e):
                if self.isOpen { self.log?.add(.socket, "closed: \(e.localizedDescription)") }
                self.isOpen = false
                self.onConnected?(false)
                // Reconnect after a pause while running; the poller decides reachability.
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                    guard let self, gen == self.generation, !self.stopped else { return }
                    self.connect()
                }
            }
        }
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didOpenWithProtocol protocol: String?) {
        guard webSocketTask === task else { return }   // an old connection opening late
        isOpen = true
        log?.add(.socket, "open as own clientId \(clientID.prefix(8))…")
        onConnected?(true)
    }
}
