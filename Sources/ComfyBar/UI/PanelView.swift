import SwiftUI

/// The panel. Every figure carries its source in the grey caption beneath it (R5).
struct PanelView: View {
    @ObservedObject var monitor: Monitor
    @ObservedObject var settings: AppSettings
    @ObservedObject var pressure: MemoryPressureWatcher
    @ObservedObject var layout: PanelLayout
    let perform: (ControlAction, String?) -> Void
    let openSettings: () -> Void
    let openDebug: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            Divider()
            // The middle scrolls; header, controls and footer stay put. Without the cap a
            // running job makes the panel taller than the space under the menu bar and the
            // popover is pushed off the top of the screen.
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 10) {
                    server
                    currentJob
                    queueSection
                    recentSection
                    machine
                }
                .background(GeometryReader { g in
                    Color.clear.preference(key: ContentHeightKey.self, value: g.size.height)
                })
            }
            .frame(height: scrollHeight)
            .background(GeometryReader { g in
                Color.clear.preference(key: ScrollFrameHeightKey.self, value: g.size.height)
            })
            .onPreferenceChange(ContentHeightKey.self) { contentHeight = $0 }
            .onPreferenceChange(ScrollFrameHeightKey.self) { scrollFrameHeight = $0 }
            Divider()
            controls
            if let m = monitor.busyMessage {
                Text(m).font(.caption).foregroundStyle(.secondary).lineLimit(3)
            }
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 430)
        .background(GeometryReader { g in
            Color.clear.preference(key: TotalHeightKey.self, value: g.size.height)
        })
        .onPreferenceChange(TotalHeightKey.self) { totalHeight = $0 }
    }

    @State private var contentHeight: CGFloat = 0
    @State private var totalHeight: CGFloat = 0
    @State private var scrollFrameHeight: CGFloat = 0

    /// Natural height when it fits; otherwise what the screen leaves after the fixed parts
    /// (header, controls, footer, padding - measured as total minus the scroll area).
    private var scrollHeight: CGFloat {
        let chrome = totalHeight > 0 ? totalHeight - scrollFrameHeight : 330
        let budget = max(160, layout.maxHeight - chrome)
        return min(contentHeight, budget)
    }

    // MARK: header

    private var header: some View {
        HStack(spacing: 8) {
            Image(nsImage: IconRenderer.image(monitor.iconState, progress: monitor.progress.map { Double($0.percent) / 100 }, size: 22))
            VStack(alignment: .leading, spacing: 1) {
                Text("ComfyUI - \(monitor.iconState.title)").font(.headline)
                Text("\(settings.hostPort)\(pollAge)").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var pollAge: String {
        guard let p = monitor.lastPoll else { return " · not polled yet" }
        return " · polled \(max(0, Int(monitor.now.timeIntervalSince(p))))s ago"
    }

    // MARK: server

    private var server: some View {
        Section2(title: "Server") {
            Row("Status", statusText, source: statusSource)
            if let s = monitor.stats, monitor.reachability == .up {
                Row("Version", "ComfyUI \(s.comfyVersion)", source: "GET /system_stats")
                Row("Runtime", "Python \(s.pythonVersion) · torch \(s.pytorchVersion)", source: "GET /system_stats")
            }
            if let l = monitor.listener {
                if let st = monitor.serverStart {
                    Row("Uptime", Format.duration(Int(monitor.now.timeIntervalSince(st))),
                        source: "process start of pid \(l.pid) (kinfo_proc)")
                }
                if let f = monitor.serverFootprint {
                    Row("Process memory", Format.bytes(f), source: "phys_footprint of pid \(l.pid) (proc_pid_rusage)")
                }
                Row("Listening", l.address, source: "lsof")
                if !monitor.exposedAddresses.isEmpty {
                    Text("Reachable from other machines: \(monitor.exposedAddresses.joined(separator: ", ")). ComfyUI's API is unauthenticated.")
                        .font(.caption.weight(.semibold)).foregroundStyle(.red)
                }
            }
        }
    }

    private var statusText: String {
        switch monitor.reachability {
        case .none: return "checking…"
        case .up?: return "up"
        case .refused?: return monitor.listener == nil ? "down - nothing on \(settings.hostPort)" : "port held (pid \(monitor.listener!.pid)) but refusing"
        case .failed(let why)?: return "unreachable - \(why)"
        }
    }
    private var statusSource: String { "GET /queue every \(String(format: "%g", settings.pollInterval))s" }

    // MARK: current job

    @ViewBuilder private var currentJob: some View {
        Section2(title: "Current job") {
            if let r = monitor.runningItem {
                let src = monitor.source(of: r)
                Row("Job", "\(Confirmations.short(r.promptID))… · \(r.nodeCount) nodes", source: "GET /queue")
                Row("Queued by", src.label, source: "inferred: \(src.evidence)")
                if let n = monitor.runningNode {
                    Row("Node", n, source: "ComfyUI progress message")
                } else {
                    Row("Node", "not visible", source: "ComfyUI sends node updates only to the client that queued it")
                }
                if let p = monitor.progress {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(p.source == .consoleBar ? "Sampler step" : "Node progress").foregroundStyle(.secondary)
                            Spacer()
                            Text("\(p.value) / \(p.max)  (\(p.percent)%)\(p.barClosed ? " · pass finished" : "")").monospacedDigit()
                        }
                        ProgressView(value: Double(p.value), total: Double(max(p.max, 1)))
                        Caption(p.source == .consoleBar
                                ? "ComfyUI console sampler bar (GET /internal/logs/raw) - counts sampler steps of the current pass only"
                                : "ComfyUI progress message for the node now running (\(src == .comfyBar ? "ComfyBar's own job" : "prompt had no client_id, so ComfyUI broadcasts it"))")
                    }
                } else {
                    Row("Step", "not visible", source: "no sampler bar in ComfyUI's console yet, and progress messages go only to the client that queued the job")
                }
                if let s = monitor.runningStart {
                    Row("Elapsed", "≈ " + Format.duration(Int(monitor.now.timeIntervalSince(s.date))), source: "since \(s.basis) (GET /api/jobs)")
                }
                if let p = monitor.progress, let rem = p.barRemainingSeconds {
                    Row("Estimate", "~\(Format.duration(rem)) left in this sampler pass",
                        source: "tqdm's own estimate for this pass - an estimate, not the whole job")
                }
            } else {
                Text(monitor.reachability == .up ? "Nothing running." : "-").font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: queue / recent

    @ViewBuilder private var queueSection: some View {
        Section2(title: "Queue - \(monitor.queue.pending.count) pending") {
            if monitor.queue.pending.isEmpty {
                Text("Empty.").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(Array(monitor.queue.pending.prefix(6).enumerated()), id: \.element.promptID) { i, item in
                HStack {
                    Text("\(i + 1).").foregroundStyle(.secondary).monospacedDigit()
                    Text("\(Confirmations.short(item.promptID))…").monospaced()
                    Text(monitor.source(of: item).label).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    Button { perform(.cancel, item.promptID) } label: { Image(systemName: "xmark.circle") }
                        .buttonStyle(.borderless).help("Cancel this queued job")
                }.font(.callout)
            }
            if monitor.queue.pending.count > 6 {
                Text("+ \(monitor.queue.pending.count - 6) more").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var recentSection: some View {
        Section2(title: "Recent") {
            if monitor.recent.isEmpty {
                Text("No finished jobs in ComfyUI's history.").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(monitor.recent) { j in
                HStack(spacing: 6) {
                    Image(systemName: icon(j.status)).foregroundStyle(color(j.status))
                    Text("\(Confirmations.short(j.id))…").monospaced()
                    Text(j.durationSeconds.map(Format.seconds) ?? "-").monospacedDigit()
                    Text(j.previewFilename ?? j.errorNodeType ?? "").foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    Spacer()
                }.font(.callout)
            }
            if !monitor.recent.isEmpty {
                Caption("GET /api/jobs - duration = ComfyUI's execution_start to its end message")
            }
        }
    }

    private func icon(_ s: JobStatus) -> String {
        switch s {
        case .completed: return "checkmark.circle.fill"
        case .failed: return "xmark.octagon.fill"
        case .cancelled: return "stop.circle"
        default: return "circle"
        }
    }
    private func color(_ s: JobStatus) -> Color {
        switch s {
        case .completed: return .green
        case .failed: return .red
        default: return .secondary
        }
    }

    // MARK: machine

    @ViewBuilder private var machine: some View {
        Section2(title: "This Mac") {
            if let m = monitor.memory {
                Row("Memory available", "\(Format.bytes(m.availableBytes)) of \(Format.bytes(m.totalBytes))",
                    source: "free + inactive + speculative + purgeable (vm_statistics64, as vm_stat)")
                Row("Memory in use", Format.bytes(m.inUseBytes), source: "total − available, same definition")
            }
            if let s = monitor.swap {
                Row("Swap in use", "\(Format.bytes(s.usedBytes)) of \(Format.bytes(s.totalBytes))", source: "sysctl vm.swapusage")
            }
            Row("Memory pressure", pressureText, source: "DispatchSource memory-pressure signals since ComfyBar launched")
            Caption("GPU busy % not shown: macOS has no documented non-root source for it.")
        }
    }

    private var pressureText: String {
        guard let s = pressure.lastSignal else { return "no signal since launch" }
        let f = DateFormatter(); f.timeStyle = .short
        return "\(s.level.rawValue) at \(f.string(from: s.at))"
    }

    // MARK: controls

    private var controls: some View {
        let up = monitor.reachability == .up
        let local = LaunchGuard.isLoopback(settings.host)
        let listening = monitor.listener != nil
        return VStack(spacing: 6) {
            HStack(spacing: 6) {
                ctl("Start", "play.fill", .start, enabled: local && !listening && !up)
                ctl("Stop", "stop.fill", .stop, enabled: local && listening)
                ctl("Restart", "arrow.clockwise", .restart, enabled: local && listening)
            }
            HStack(spacing: 6) {
                ctl("Interrupt", "hand.raised.fill", .interrupt, enabled: up && monitor.runningItem != nil)
                ctl("Clear queue", "tray", .clear, enabled: up && !monitor.queue.pending.isEmpty)
                ctl("Free memory", "memorychip", .free, enabled: up)
            }
            HStack(spacing: 6) {
                ctl("Open ComfyUI", "safari", .openBrowser, enabled: up)
                ctl("Output", "folder", .openOutput, enabled: true)
                ctl("Log", "doc.text", .openLog, enabled: true)
            }
        }
    }

    private func ctl(_ title: String, _ symbol: String, _ a: ControlAction, enabled: Bool) -> some View {
        Button { perform(a, nil) } label: {
            Label(title, systemImage: symbol).font(.callout).lineLimit(1).frame(maxWidth: .infinity)
        }
        .controlSize(.regular)
        .disabled(!enabled)
    }

    private var footer: some View {
        HStack {
            Button("Settings…", action: openSettings)
            Button("Debug…", action: openDebug)
            Button("About") {
                NSApp.activate(ignoringOtherApps: true)
                NSApp.orderFrontStandardAboutPanel(nil)
            }
            Spacer()
            Button("Quit ComfyBar") { NSApp.terminate(nil) }
        }.buttonStyle(.borderless).font(.callout)
    }
}

// MARK: - small building blocks

struct Section2<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            content
        }
    }
}

struct Row: View {
    let label: String
    let value: String
    let source: String
    init(_ label: String, _ value: String, source: String) {
        self.label = label; self.value = value; self.source = source
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(label).foregroundStyle(.secondary)
                Spacer(minLength: 12)
                Text(value).multilineTextAlignment(.trailing).monospacedDigit().textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }.font(.callout)
            Caption(source)
        }
    }
}

struct Caption: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.system(size: 9.5)).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
    }
}

/// Height the popover may use: the screen's visible height under the menu bar, set when the
/// panel opens (StatusItemController.open).
final class PanelLayout: ObservableObject {
    @Published var maxHeight: CGFloat = 800
}

private struct ContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

private struct ScrollFrameHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

private struct TotalHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
