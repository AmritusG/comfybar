import SwiftUI

/// Debug window: last 500 events, system info, Copy All.
struct DebugView: View {
    @ObservedObject var log: EventLog
    let systemInfo: () -> String
    let calibrate: (() -> Void)?
    @State private var filter = ""
    @State private var copied = false

    private var shown: [EventLog.Event] {
        filter.isEmpty ? log.events : log.events.filter { $0.text.localizedCaseInsensitiveContains(filter) || $0.kind.rawValue.localizedCaseInsensitiveContains(filter) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            GroupBox("System") {
                Text(systemInfo()).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                TextField("Filter", text: $filter).textFieldStyle(.roundedBorder).frame(width: 220)
                Text("\(log.events.count) / \(EventLog.capacity) events").foregroundStyle(.secondary).font(.caption)
                Spacer()
                if let calibrate {
                    Button("Queue calibration job", action: calibrate)
                        .help("Tiny model-free graph that reports steps. Refused on port 8188.")
                }
                Button(copied ? "Copied" : "Copy All") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(log.exportText(header: systemInfo()), forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                }
            }
            ScrollViewReader { proxy in
                List(shown) { e in
                    Text(EventLog.format(e)).font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(e.kind == .error ? Color.red : e.kind == .control ? Color.orange : Color.primary)
                        .textSelection(.enabled)
                        .id(e.id)
                }
                .onChange(of: log.events.last?.id) { _, id in
                    if let id, filter.isEmpty { proxy.scrollTo(id, anchor: .bottom) }
                }
            }
        }
        .padding(12)
        .frame(minWidth: 760, minHeight: 520)
    }
}
