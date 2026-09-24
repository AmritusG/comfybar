import AppKit

/// Test hook, OFF unless launched with `-ComfyBarAutomationDir <dir>` on the command line (the
/// argument domain only - a saved preference never turns it on). Commands arrive as
/// distributed notifications named com.amritus.comfybar.automation whose object is the
/// command line (scripts/cbctl.swift sends them). Controls run through Actions.perform - the
/// same path as the panel buttons, confirmations included. R3: any mutating command is
/// refused while the target port is 8188.
@MainActor
final class Automation {
    static let name = Notification.Name("com.amritus.comfybar.automation")
    private weak var app: AppDelegate?
    private var observer: NSObjectProtocol?
    /// Every file a command writes must be inside this directory.
    let directory: URL

    /// The automation directory, if and only if it was given as a launch argument and exists.
    static func launchDirectory() -> URL? {
        let args = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        guard let path = args["ComfyBarAutomationDir"] as? String, path.hasPrefix("/") else { return nil }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { return nil }
        return URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
    }

    /// `name` resolved inside the automation directory, or nil if it would land outside it.
    private func confined(_ name: String) -> URL? {
        let u = directory.appendingPathComponent(name).standardizedFileURL
        let dir = directory.path.hasSuffix("/") ? directory.path : directory.path + "/"
        guard u.path.hasPrefix(dir) else {
            app?.log.add(.error, "automation: REFUSED path outside \(directory.path): \(name)")
            return nil
        }
        return u
    }

    init(app: AppDelegate, directory: URL) {
        self.app = app
        self.directory = directory
        observer = DistributedNotificationCenter.default().addObserver(forName: Self.name, object: nil, queue: .main) { [weak self] n in
            let line = n.object as? String ?? ""
            MainActor.assumeIsolated { self?.handle(line) }
        }
    }

    private func handle(_ line: String) {
        guard let app else { return }
        let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
        guard let cmd = parts.first else { return }
        let arg = parts.count > 1 ? parts[1] : nil
        app.log.add(.info, "automation: \(line)")
        switch cmd {
        case "open": app.status.open()
        case "close": app.status.close()
        case "debug": app.showDebug()
        case "settings": app.showSettings()
        case "poll": app.monitor.pokePoll()
        case "state": if let p = arg, let u = confined(p) { dumpState(to: u.path) }
        case "menubartext": if let a = arg, let c = MenuBarText(rawValue: a) { app.settings.menuBarText = c; app.status.update() }
        case "autoconfirm": if let a = arg { app.actions.autoConfirmAnswer = (a != "no") }
        case "renderglyphs": if let d = confined(arg ?? "."), (try? d.checkResourceIsReachable()) == true { renderGlyphs(to: d.path) }
        case "about":
            app.status.close()
            NSApp.activate(ignoringOtherApps: true)
            NSApp.orderFrontStandardAboutPanel(nil)
        default:
            guard let action = ControlAction(rawValue: cmd) else {
                app.log.add(.error, "automation: unknown command \(cmd)")
                return
            }
            if action.mutatesServer && app.settings.port == 8188 {
                app.log.add(.error, "automation: REFUSED \(cmd) - target port is 8188 (R3)")
                return
            }
            app.run(action, arg)
        }
    }

    /// Every state's glyph drawn by the shipping IconRenderer under the Aqua (light) and
    /// DarkAqua appearances, at 2x, on the menu bar's plain light / dark colour. A render,
    /// not a screen capture: the real menu bar takes its tint from the wallpaper.
    private func renderGlyphs(to dir: String) {
        for (name, appearance, bg) in [("light", NSAppearance.Name.aqua, NSColor(white: 0.93, alpha: 1)),
                                       ("dark", NSAppearance.Name.darkAqua, NSColor(white: 0.12, alpha: 1))] {
            guard let ap = NSAppearance(named: appearance) else { continue }
            let pt: CGFloat = 18, pad: CGFloat = 8
            let states = IconState.allCases
            let w = (pt + pad) * CGFloat(states.count) + pad, h = pt + 2 * pad
            guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(w * 2), pixelsHigh: Int(h * 2),
                                             bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                             colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { continue }
            rep.size = NSSize(width: w, height: h)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            ap.performAsCurrentDrawingAppearance {
                bg.setFill(); NSRect(x: 0, y: 0, width: w, height: h).fill()
                for (i, st) in states.enumerated() {
                    let prog: Double? = (st == .running || st == .queued) ? 0.6 : nil
                    IconRenderer.image(st, progress: prog, size: pt)
                        .draw(in: NSRect(x: pad + CGFloat(i) * (pt + pad), y: pad, width: pt, height: pt))
                }
            }
            NSGraphicsContext.restoreGraphicsState()
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(dir)/glyphs-render-\(name)-appearance-2x.png"))
        }
        app?.log.add(.info, "rendered glyphs to \(dir)")
    }

    private func frameDict(_ r: NSRect) -> [String: Double] {
        ["x": r.origin.x, "y": r.origin.y, "w": r.size.width, "h": r.size.height]
    }

    /// JSON the tests read: state + on-screen geometry for screencapture.
    private func dumpState(to path: String) {
        guard let app else { return }
        let m = app.monitor
        var d: [String: Any] = [
            "icon": m.iconState.rawValue,
            "reachability": m.reachability.map(Monitor.describe) ?? "-",
            "running": m.queue.running.map(\.promptID),
            "pending": m.queue.pending.map(\.promptID),
            "recent": m.recent.map { ["id": $0.id, "status": $0.status.rawValue, "duration": $0.durationSeconds ?? -1] },
            "listenerPid": m.listener.map { Int($0.pid) } ?? -1,
            "listenerAddress": m.listener?.address ?? "",
            "port": app.settings.port,
            "extraArgs": app.settings.extraArgs,
            "menuBarText": StatusItemController.menuBarText(app.settings.menuBarText, monitor: m),
            "clientId": m.socket.clientID,
            "notifications": Notifier.describe(app.notifier.authorization),
            "panelShown": app.status.popover.isShown,
        ]
        if let p = m.progress {
            d["progress"] = ["value": p.value, "max": p.max, "source": p.source.rawValue, "node": p.node ?? ""]
        }
        if let r = m.runningInfo { d["runningSource"] = r.source.label; d["runningEvidence"] = r.source.evidence }
        if let s = m.runningStart { d["runningStart"] = s.date.timeIntervalSince1970; d["runningStartBasis"] = s.basis }
        if let mem = m.memory {
            d["memory"] = ["available": mem.availableBytes, "inUse": mem.inUseBytes, "total": mem.totalBytes,
                           "free": mem.freePages, "inactive": mem.inactivePages, "speculative": mem.speculativePages,
                           "purgeable": mem.purgeablePages, "pageSize": mem.pageSize]
        }
        if let s = m.swap { d["swapUsed"] = s.usedBytes }
        if let f = m.serverFootprint { d["serverFootprint"] = f }
        if let st = m.serverStart { d["serverStart"] = st.timeIntervalSince1970 }
        if let b = app.status.item.button, let w = b.window { d["statusItemFrame"] = frameDict(w.frame) }
        if let w = app.status.panelWindow { d["panelFrame"] = frameDict(w.frame); d["panelWindowNumber"] = w.windowNumber }
        if let w = app.debugWindowRef, w.isVisible { d["debugWindowNumber"] = w.windowNumber }
        if let w = app.settingsWindowRef, w.isVisible { d["settingsWindowNumber"] = w.windowNumber }
        let alerts = NSApp.windows.filter { $0.isVisible && $0.className.contains("Alert") }
        if let a = alerts.first { d["alertWindowNumber"] = a.windowNumber; d["alertFrame"] = frameDict(a.frame) }
        d["screenHeight"] = NSScreen.main?.frame.height ?? 0
        if let v = (app.status.item.button?.window?.screen ?? NSScreen.main)?.visibleFrame {
            d["visibleTop"] = v.maxY; d["visibleBottom"] = v.minY
        }
        if let data = try? JSONSerialization.data(withJSONObject: d, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }
}
