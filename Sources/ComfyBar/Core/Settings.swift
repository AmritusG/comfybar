import Foundation

enum MenuBarText: String, CaseIterable, Identifiable {
    case nothing, progress, queueCount, memoryInUse, elapsed
    var id: String { rawValue }
    var label: String {
        switch self {
        case .nothing: return "Nothing"
        case .progress: return "Progress %"
        case .queueCount: return "Queue count"
        case .memoryInUse: return "Memory in use"
        case .elapsed: return "Elapsed (current job)"
        }
    }
}

/// UserDefaults-backed settings. Launch arguments override any key for one
/// run without writing it (NSArgumentDomain), e.g. `-port 8199` - that is how the test
/// instance is driven without touching saved settings.
final class AppSettings: ObservableObject {
    enum Key {
        static let comfyFolder = "comfyFolder", host = "host", port = "port"
        static let pollInterval = "pollInterval", menuBarText = "menuBarText"
        static let notifyFinished = "notifyFinished", notifyFailed = "notifyFailed", notifyDown = "notifyDown"
        static let extraArgs = "extraArgs", recentCount = "recentCount"
    }

    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.comfyFolder: NSHomeDirectory() + "/ComfyUI",
            Key.host: "127.0.0.1",
            Key.port: 8188,
            Key.pollInterval: 2.0,
            Key.menuBarText: MenuBarText.nothing.rawValue,
            Key.notifyFinished: true,
            Key.notifyFailed: true,
            Key.notifyDown: true,
            Key.extraArgs: "",
            Key.recentCount: 8,
        ])
    }

    /// Writes only a real change. A value that merely equals what is already in effect -
    /// including one supplied as a launch argument (NSArgumentDomain) - is never persisted.
    private func set<T: Equatable>(_ v: T, _ k: String, current: T) {
        guard v != current else { return }
        objectWillChange.send()
        defaults.set(v, forKey: k)
    }

    var comfyFolder: String {
        get { (defaults.string(forKey: Key.comfyFolder) ?? "") as String }
        set { set(newValue, Key.comfyFolder, current: comfyFolder) }
    }
    var host: String {
        get { defaults.string(forKey: Key.host) ?? "127.0.0.1" }
        set { set(newValue, Key.host, current: host) }
    }
    var port: Int {
        get { defaults.integer(forKey: Key.port) }
        set { set(newValue, Key.port, current: port) }
    }
    var pollInterval: Double {
        get { min(max(defaults.double(forKey: Key.pollInterval), 0.5), 60) }
        set { set(newValue, Key.pollInterval, current: pollInterval) }
    }
    var menuBarText: MenuBarText {
        get { MenuBarText(rawValue: defaults.string(forKey: Key.menuBarText) ?? "") ?? .nothing }
        set { set(newValue.rawValue, Key.menuBarText, current: menuBarText.rawValue) }
    }
    var notifyFinished: Bool {
        get { defaults.bool(forKey: Key.notifyFinished) }
        set { set(newValue, Key.notifyFinished, current: notifyFinished) }
    }
    var notifyFailed: Bool {
        get { defaults.bool(forKey: Key.notifyFailed) }
        set { set(newValue, Key.notifyFailed, current: notifyFailed) }
    }
    var notifyDown: Bool {
        get { defaults.bool(forKey: Key.notifyDown) }
        set { set(newValue, Key.notifyDown, current: notifyDown) }
    }
    /// Extra arguments for Start, space-separated. Validated by LaunchGuard before use.
    var extraArgs: String {
        get { defaults.string(forKey: Key.extraArgs) ?? "" }
        set { set(newValue, Key.extraArgs, current: extraArgs) }
    }
    var recentCount: Int {
        get { min(max(defaults.integer(forKey: Key.recentCount), 1), 50) }
        set { set(newValue, Key.recentCount, current: recentCount) }
    }

    /// A host ComfyBar will accept: a DNS name or IPv4 address, no scheme, port or spaces.
    static func isValidHost(_ h: String) -> Bool {
        !h.isEmpty && h.count <= 253 && h.range(of: #"^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$"#, options: .regularExpression) != nil
    }

    var baseURL: URL? {
        var c = URLComponents()
        c.scheme = "http"
        c.host = host
        c.port = port
        return c.url
    }
    var hostPort: String { "\(host):\(port)" }
}

/// R2: ComfyUI's API writes files and is unauthenticated. Start never passes --listen and
/// never binds anything but loopback. ComfyUI's default --listen is 127.0.0.1
/// (comfy/cli_args.py:63), so omitting the flag is the loopback bind.
enum LaunchGuard {
    enum Refusal: Error, Equatable, CustomStringConvertible {
        case nonLoopbackHost(String)
        case forbiddenArgument(String)
        case badPort(Int)

        var description: String {
            switch self {
            case .nonLoopbackHost(let h): return "Start only runs ComfyUI on this Mac; host \(h) is not 127.0.0.1/localhost."
            case .forbiddenArgument(let a): return "Refused argument \"\(a)\": ComfyBar never passes --listen or a non-loopback address."
            case .badPort(let p): return "Port \(p) is outside 1024-65535."
            }
        }
    }

    static func isLoopback(_ host: String) -> Bool {
        // IPv4 only: ComfyUI's default bind is 127.0.0.1 (cli_args.py:63), so "::1" would
        // never reach the server ComfyBar starts.
        ["127.0.0.1", "localhost"].contains(host.lowercased())
    }

    /// Options that change where or how the server can be reached. ComfyUI's parser is a stock
    /// argparse.ArgumentParser (comfy/cli_args.py:61) with allow_abbrev left on, so any
    /// unambiguous prefix means the same option: "--lis" is --listen with no value, which
    /// binds 0.0.0.0 (cli_args.py:63). Prefixes are therefore refused too.
    static let forbiddenOptions = ["--listen", "--port", "--tls-keyfile", "--tls-certfile", "--enable-cors-header"]

    static func isForbidden(_ token: String) -> Bool {
        let l = token.lowercased()
        if l.contains("0.0.0.0") || l == "::" || l.contains("[::]") { return true }
        guard l.hasPrefix("--"), l.count > 2 else { return false }
        let name = String(l.split(separator: "=", maxSplits: 1)[0])
        return forbiddenOptions.contains { $0.hasPrefix(name) }
    }

    /// Splits extra args on whitespace (no quoting - paths with spaces are not supported,
    /// stated in Settings) and rejects anything that could change the bind address.
    static func arguments(port: Int, host: String, extra: String) throws -> [String] {
        guard isLoopback(host) else { throw Refusal.nonLoopbackHost(host) }
        guard (1024...65535).contains(port) else { throw Refusal.badPort(port) }
        let tokens = extra.split(whereSeparator: \.isWhitespace).map(String.init)
        for t in tokens where isForbidden(t) {
            throw Refusal.forbiddenArgument(t)
        }
        return ["main.py", "--port", String(port)] + tokens
    }
}
