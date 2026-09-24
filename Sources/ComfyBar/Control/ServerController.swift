import Foundation
import Darwin

/// Start / Stop / Restart of a ComfyUI server on this Mac.
final class ServerController {
    enum ControlError: Error, CustomStringConvertible {
        case guardRefused(LaunchGuard.Refusal)
        case missing(String)
        case portBusy(Int, pid_t)
        case notComfy(pid_t, String)
        case launch(String)
        case alreadyStarted(pid_t)
        case notOnPort(pid_t, Int)

        var description: String {
            switch self {
            case .guardRefused(let r): return r.description
            case .missing(let s): return s
            case .portBusy(let p, let pid): return "Port \(p) is already in use (pid \(pid))."
            case .notComfy(let pid, let why): return "pid \(pid) does not look like this ComfyUI install (\(why)); not signalling it."
            case .launch(let s): return "Launch failed: \(s)"
            case .alreadyStarted(let pid): return "ComfyBar already started ComfyUI (pid \(pid)); it may still be loading."
            case .notOnPort(let pid, let port): return "pid \(pid) no longer listens on port \(port); not signalling it."
            }
        }
    }

    private let log: EventLog
    private(set) var ownProcess: Process?
    private(set) var ownPort: Int?
    private(set) var ownLogURL: URL?

    init(log: EventLog) { self.log = log }

    static var logDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/ComfyBar")
    }

    static func pythonURL(folder: String) -> URL {
        URL(fileURLWithPath: folder).appendingPathComponent("venv/bin/python")
    }

    /// Launch `<folder>/venv/bin/python main.py --port <port> [extra]` in <folder>.
    /// Never --listen (LaunchGuard); ComfyUI's default bind is 127.0.0.1.
    @discardableResult
    func start(folder: String, host: String, port: Int, extra: String) throws -> pid_t {
        let args: [String]
        do { args = try LaunchGuard.arguments(port: port, host: host, extra: extra) }
        catch let r as LaunchGuard.Refusal { log.add(.control, "Start refused: \(r)"); throw ControlError.guardRefused(r) }
        let fm = FileManager.default
        guard fm.fileExists(atPath: folder + "/main.py") else { throw ControlError.missing("No main.py in \(folder).") }
        let py = Self.pythonURL(folder: folder)
        guard fm.isExecutableFile(atPath: py.path) else { throw ControlError.missing("No venv python at \(py.path).") }
        // A second Start while the first server is still loading would launch another process
        // (and every ComfyUI start wipes the shared temp dir, main.py:531).
        if let p = ownProcess, p.isRunning { throw ControlError.alreadyStarted(p.processIdentifier) }
        if let l = PortProbe.listeners(port: port).first { throw ControlError.portBusy(port, l.pid) }

        try? fm.createDirectory(at: Self.logDirectory, withIntermediateDirectories: true)
        let logURL = Self.logDirectory.appendingPathComponent("comfyui-\(port).log")
        if !fm.fileExists(atPath: logURL.path) { fm.createFile(atPath: logURL.path, contents: nil) }
        guard let handle = try? FileHandle(forWritingTo: logURL) else { throw ControlError.launch("cannot open \(logURL.path)") }
        handle.seekToEndOfFile()
        let cmd = ([py.path] + args).joined(separator: " ")
        handle.write("\n=== ComfyBar Start \(ISO8601DateFormatter().string(from: Date())) cwd=\(folder)\n=== \(cmd)\n".data(using: .utf8)!)

        let p = Process()
        p.executableURL = py
        p.arguments = args
        p.currentDirectoryURL = URL(fileURLWithPath: folder)
        var env = ProcessInfo.processInfo.environment
        env["PYTHONUNBUFFERED"] = "1"
        p.environment = env
        p.standardOutput = handle
        p.standardError = handle
        p.standardInput = FileHandle.nullDevice
        p.terminationHandler = { [weak self] proc in
            self?.log.add(.control, "ComfyUI pid \(proc.processIdentifier) exited status=\(proc.terminationStatus) reason=\(proc.terminationReason == .exit ? "exit" : "signal")")
            try? handle.close()
        }
        do { try p.run() } catch { throw ControlError.launch(error.localizedDescription) }
        ownProcess = p
        ownPort = port
        ownLogURL = logURL
        log.add(.control, "Start pid \(p.processIdentifier): \(cmd)")
        return p.processIdentifier
    }

    /// Is `pid` a ComfyUI main.py from `folder`? Guards Stop against signalling anything else
    /// that happens to hold the port.
    static func identify(pid: pid_t, folder: String) -> (ok: Bool, why: String) {
        guard let args = MachineStats.arguments(pid: pid) else { return (false, "cannot read its arguments") }
        guard let main = args.first(where: { $0 == "main.py" || $0.hasSuffix("/main.py") }) else {
            return (false, "no main.py in its arguments")
        }
        let root = URL(fileURLWithPath: folder).resolvingSymlinksInPath().path
        if main.hasPrefix("/") {
            let dir = URL(fileURLWithPath: main).deletingLastPathComponent().resolvingSymlinksInPath().path
            return dir == root ? (true, "main.py at \(main)") : (false, "main.py is \(main), not in \(root)")
        }
        guard let cwd = MachineStats.currentDirectory(pid: pid) else { return (false, "cannot read its working directory") }
        let c = URL(fileURLWithPath: cwd).resolvingSymlinksInPath().path
        return c == root ? (true, "main.py, cwd \(c)") : (false, "cwd is \(c), not \(root)")
    }

    /// A server ComfyBar started is listening beyond loopback: end it now, no grace period.
    func emergencyStop(pid: pid_t) {
        guard ownProcess?.processIdentifier == pid else { return }
        log.add(.error, "EMERGENCY STOP pid \(pid): listening on a non-loopback address")
        kill(pid, SIGKILL)
    }

    /// Graceful first: SIGINT (ComfyUI treats it as Ctrl-C: "Stopped server", then its
    /// finally-block cleanup, main.py:612-616), then SIGTERM, then SIGKILL.
    func stop(pid: pid_t, port: Int, folder: String, sigintWait: TimeInterval = 20, sigtermWait: TimeInterval = 10) async throws -> String {
        let id = Self.identify(pid: pid, folder: folder)
        guard id.ok else { log.add(.control, "Stop refused: pid \(pid) \(id.why)"); throw ControlError.notComfy(pid, id.why) }
        // The pid must still be the one on THIS port (settings may have just changed, and two
        // servers from one folder can run on different ports).
        guard PortProbe.listeners(port: port).contains(where: { $0.pid == pid }) else {
            log.add(.control, "Stop refused: pid \(pid) is not listening on \(port)")
            throw ControlError.notOnPort(pid, port)
        }
        let steps: [(Int32, String, TimeInterval)] = [(SIGINT, "SIGINT", sigintWait), (SIGTERM, "SIGTERM", sigtermWait), (SIGKILL, "SIGKILL", 5)]
        for (sig, name, wait) in steps {
            // Before escalating, make sure the pid is still that ComfyUI (not a reused pid).
            if sig != SIGINT, !Self.identify(pid: pid, folder: folder).ok {
                let msg = "pid \(pid) ended (no longer that ComfyUI) before \(name)"
                log.add(.control, msg)
                return msg
            }
            log.add(.control, "Stop pid \(pid): \(name)")
            kill(pid, sig)
            let deadline = Date().addingTimeInterval(wait)
            while Date() < deadline {
                if !MachineStats.isAlive(pid) || (ownProcess?.processIdentifier == pid && ownProcess?.isRunning == false) {
                    let msg = "pid \(pid) ended after \(name)"
                    log.add(.control, msg)
                    return msg
                }
                try await Task.sleep(nanoseconds: 200_000_000)
            }
        }
        let msg = "pid \(pid) still alive after SIGKILL"
        log.add(.error, msg)
        return msg
    }
}
