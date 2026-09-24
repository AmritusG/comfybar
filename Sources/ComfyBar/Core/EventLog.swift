import Foundation

/// Ring buffer of the last 500 events for the Debug window.
final class EventLog: ObservableObject {
    enum Kind: String {
        case request = "REQ", response = "RES", socket = "WS", state = "STATE"
        case control = "CTRL", error = "ERR", info = "INFO"
    }

    struct Event: Identifiable, Equatable {
        let id: Int
        let date: Date
        let kind: Kind
        let text: String
    }

    static let capacity = 500

    @Published private(set) var events: [Event] = []
    private var nextID = 0
    private let lock = NSLock()
    /// Mirror to a file too (the automation/test path reads it); nil = memory only.
    var mirrorURL: URL?

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    /// Safe from any thread; publishes on the main thread.
    func add(_ kind: Kind, _ text: String) {
        lock.lock()
        let e = Event(id: nextID, date: Date(), kind: kind, text: text)
        nextID += 1
        lock.unlock()
        if let url = mirrorURL, let line = (Self.format(e) + "\n").data(using: .utf8) {
            if let h = try? FileHandle(forWritingTo: url) {
                h.seekToEndOfFile(); h.write(line); try? h.close()
            } else {
                try? line.write(to: url)
            }
        }
        let apply = { [weak self] in
            guard let self else { return }
            self.events.append(e)
            if self.events.count > Self.capacity { self.events.removeFirst(self.events.count - Self.capacity) }
        }
        if Thread.isMainThread { apply() } else { DispatchQueue.main.async(execute: apply) }
    }

    static func format(_ e: Event) -> String {
        "\(stamp.string(from: e.date)) \(e.kind.rawValue.padding(toLength: 5, withPad: " ", startingAt: 0)) \(e.text)"
    }

    func exportText(header: String) -> String {
        header + "\n\n" + events.map(Self.format).joined(separator: "\n") + "\n"
    }
}
