import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let log = EventLog()
    lazy var settings = AppSettings()
    lazy var notifier = Notifier(log: log)
    lazy var monitor = Monitor(settings: settings, log: log, notifier: notifier)
    lazy var server = ServerController(log: log)
    lazy var actions = Actions(monitor: monitor, server: server, log: log, settings: settings)
    var status: StatusItemController!
    private var settingsWindow: NSWindow?
    private var debugWindow: NSWindow?
    private var automation: Automation?

    func applicationDidFinishLaunching(_ note: Notification) {
        let automationDir = Automation.launchDirectory()
        if let dir = automationDir { log.mirrorURL = dir.appendingPathComponent("events.log") }
        let info = Bundle.main.infoDictionary
        log.add(.info, "ComfyBar \(info?["CFBundleShortVersionString"] ?? "?") (\(info?["CFBundleVersion"] ?? "?")) pid \(getpid()) target \(settings.hostPort) folder \(settings.comfyFolder)")

        let layout = PanelLayout()
        let panel = PanelView(monitor: monitor, settings: settings, pressure: monitor.pressure, layout: layout,
                              perform: { [weak self] a, arg in self?.run(a, arg) },
                              openSettings: { [weak self] in self?.showSettings() },
                              openDebug: { [weak self] in self?.showDebug() })
        status = StatusItemController(monitor: monitor, settings: settings, layout: layout, panel: panel)
        actions.willPresentModal = { [weak self] in self?.status.close() }
        monitor.onChange = { [weak self] in self?.status.update() }
        monitor.onExposedListeners = { [weak self] exposed in
            guard let self, let own = self.server.ownProcess?.processIdentifier,
                  let hit = exposed.first(where: { $0.pid == own }) else { return }
            self.server.emergencyStop(pid: own)
            self.notifier.post(title: "ComfyBar stopped ComfyUI",
                               body: "It was listening on \(hit.address), not just this Mac.")
        }
        notifier.requestAuthorization()
        monitor.start()

        if let dir = automationDir {
            let args = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
            actions.autoConfirmAfter = (args["ComfyBarAutoConfirmSeconds"] as? String).flatMap(Double.init) ?? 3
            automation = Automation(app: self, directory: dir)
            log.add(.info, "automation hook ON, files confined to \(dir.path) (mutating commands refused on port 8188)")
        }
    }

    func applicationWillTerminate(_ note: Notification) {
        monitor.stop()
    }

    func run(_ a: ControlAction, _ arg: String?) {
        if a.endsWork || a == .start { status.close() }
        Task { await actions.perform(a, arg: arg) }
    }

    func systemInfo() -> String {
        let info = Bundle.main.infoDictionary
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        var lines = [
            "ComfyBar \(info?["CFBundleShortVersionString"] ?? "?") build \(info?["CFBundleVersion"] ?? "?") · \(Bundle.main.bundleIdentifier ?? "?") · pid \(getpid())",
            "macOS \(os)",
            "target \(settings.hostPort) · folder \(settings.comfyFolder) · poll \(settings.pollInterval)s",
            "own websocket clientId \(monitor.socket.clientID)",
            "notifications: \(Notifier.describe(notifier.authorization))",
            "state \(monitor.iconState.rawValue) · reachability \(monitor.reachability.map(Monitor.describe) ?? "-")",
        ]
        if let s = monitor.stats {
            lines.append("ComfyUI \(s.comfyVersion) · Python \(s.pythonVersion) · torch \(s.pytorchVersion) · argv \(s.argv.joined(separator: " "))")
        }
        if let l = monitor.listener { lines.append("listener pid \(l.pid) \(l.address)") }
        if server.ownProcess != nil { lines.append("started by ComfyBar: pid \(server.ownProcess!.processIdentifier) log \(server.ownLogURL?.path ?? "-")") }
        return lines.joined(separator: "\n")
    }

    func showSettings() {
        status.close()
        if settingsWindow == nil {
            let v = SettingsView(settings: settings,
                                 notificationStatus: { [weak self] in Notifier.describe(self?.notifier.authorization ?? .notDetermined) },
                                 applied: { [weak self] in self?.monitor.reconfigureIfNeeded(); self?.status.update() })
            settingsWindow = Self.window("ComfyBar Settings", NSHostingController(rootView: v))
        }
        notifier.refreshStatus()
        present(settingsWindow!)
    }

    func showDebug() {
        status.close()
        if debugWindow == nil {
            let v = DebugView(log: log, systemInfo: { [weak self] in self?.systemInfo() ?? "" },
                              calibrate: { [weak self] in self?.run(.calibrate, nil) })
            debugWindow = Self.window("ComfyBar Debug", NSHostingController(rootView: v))
            debugWindow?.setContentSize(NSSize(width: 820, height: 600))
        }
        present(debugWindow!)
    }

    var debugWindowRef: NSWindow? { debugWindow }
    var settingsWindowRef: NSWindow? { settingsWindow }

    private func present(_ w: NSWindow) {
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    private static func window(_ title: String, _ vc: NSViewController) -> NSWindow {
        let w = NSWindow(contentViewController: vc)
        w.title = title
        w.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        w.isReleasedWhenClosed = false
        w.center()
        return w
    }
}
