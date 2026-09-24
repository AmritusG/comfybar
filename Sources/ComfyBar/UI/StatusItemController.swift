import AppKit
import SwiftUI

/// AppKit NSStatusItem + NSPopover hosting the SwiftUI panel.
///
/// Why not MenuBarExtra (which the house reference vpngate uses): the glyph here is a
/// coloured, non-template image with live text beside it, and the panel must be opened and
/// closed programmatically (failure acknowledgement, confirmations, screenshots). NSStatusItem
/// gives direct control of both; MenuBarExtra has no API to open its window.
@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate {
    let item: NSStatusItem
    let popover = NSPopover()
    private let monitor: Monitor
    private let settings: AppSettings
    private let layout: PanelLayout
    private var appearanceObservation: NSKeyValueObservation?

    init(monitor: Monitor, settings: AppSettings, layout: PanelLayout, panel: PanelView) {
        self.monitor = monitor
        self.settings = settings
        self.layout = layout
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        popover.behavior = .transient
        popover.animates = false
        let host = NSHostingController(rootView: panel)
        host.sizingOptions = [.preferredContentSize]   // popover follows the SwiftUI height
        popover.contentViewController = host
        popover.delegate = self
        if let b = item.button {
            b.target = self
            b.action = #selector(toggle)
            b.imagePosition = .imageLeading
            // The B is drawn in labelColor for the menu bar's appearance; redraw when the
            // menu bar flips light <-> dark (wallpaper or system appearance change).
            appearanceObservation = b.observe(\.effectiveAppearance) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.update() }
            }
        }
        update()
    }

    @objc func toggle() {
        if popover.isShown { close() } else { open() }
    }

    func open() {
        guard let b = item.button else { return }
        monitor.acknowledgeFailure()
        layout.maxHeight = Self.maxPanelHeight(for: b.window?.screen ?? NSScreen.main)
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: b.bounds, of: b, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    func close() { popover.performClose(nil) }

    /// Room under the menu bar: the screen's visible height (menu bar and Dock excluded) less
    /// the popover arrow and a margin. `-ComfyBarPanelMaxHeight N` lowers it (testing only).
    static func maxPanelHeight(for screen: NSScreen?) -> CGFloat {
        var h = (screen?.visibleFrame.height ?? 800) - 36
        let cap = UserDefaults.standard.double(forKey: "ComfyBarPanelMaxHeight")
        if cap > 0 { h = min(h, cap) }
        return max(300, h)
    }

    var panelWindow: NSWindow? { popover.isShown ? popover.contentViewController?.view.window : nil }

    static func menuBarText(_ choice: MenuBarText, monitor: Monitor) -> String {
        switch choice {
        case .nothing: return ""
        case .progress: return monitor.progress.map { "\($0.percent)%" } ?? ""
        case .queueCount:
            let n = monitor.queue.running.count + monitor.queue.pending.count
            return n > 0 ? "\(n)" : ""
        case .memoryInUse: return monitor.memory.map { Format.bytes($0.inUseBytes) } ?? ""
        case .elapsed:
            guard monitor.runningItem != nil, let s = monitor.runningStart else { return "" }
            return Format.duration(Int(Date().timeIntervalSince(s.date)))
        }
    }

    func update() {
        guard let b = item.button else { return }
        let frac = monitor.progress.map { Double($0.value) / Double(max($0.max, 1)) }
        b.image = IconRenderer.image(monitor.iconState, progress: frac)
        let text = Self.menuBarText(settings.menuBarText, monitor: monitor)
        b.attributedTitle = NSAttributedString(string: text.isEmpty ? "" : " " + text, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize - 1, weight: .regular),
        ])
        b.toolTip = "ComfyUI \(settings.hostPort): \(monitor.iconState.title)"
    }
}
