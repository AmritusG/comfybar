import SwiftUI
import ServiceManagement

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    let notificationStatus: () -> String
    let applied: () -> Void
    @State private var loginEnabled = SMAppService.mainApp.status == .enabled
    @State private var loginMessage: String?
    @State private var portText = ""
    @State private var hostText = ""
    @State private var folderText = ""
    @State private var extraText = ""
    @State private var fieldMessage: String?

    var body: some View {
        Form {
            Section("ComfyUI") {
                // Text fields apply on Return or when the window closes - not per keystroke
                // (a half-typed host would otherwise reconnect on every character).
                HStack {
                    TextField("Folder", text: $folderText).onSubmit(commitFields)
                    Button("Choose…") { chooseFolder() }
                }
                TextField("Host", text: $hostText).onSubmit(commitFields)
                TextField("Port", text: $portText).onSubmit(commitFields)
                if let m = fieldMessage { Text(m).font(.caption).foregroundStyle(.red) }
                Text("Start runs <folder>/venv/bin/python main.py --port <port> in the folder. It never passes --listen, so ComfyUI binds 127.0.0.1 only. Start / Stop / Restart only work when the host is 127.0.0.1 or localhost.")
                    .font(.caption).foregroundStyle(.secondary)
                TextField("Extra launch arguments", text: $extraText).onSubmit(commitFields)
                Text("Space-separated, no quoting. --listen, --port, --tls*, --enable-cors* (and any abbreviation of them) are refused.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Display") {
                Stepper(value: Binding(get: { settings.pollInterval }, set: { settings.pollInterval = $0; applied() }), in: 0.5...60, step: 0.5) {
                    Text("Poll every \(String(format: "%g", settings.pollInterval)) s")
                }
                Picker("Menu-bar text", selection: Binding(get: { settings.menuBarText }, set: { settings.menuBarText = $0; applied() })) {
                    ForEach(MenuBarText.allCases) { Text($0.label).tag($0) }
                }
                Stepper(value: Binding(get: { settings.recentCount }, set: { settings.recentCount = $0; applied() }), in: 1...50) {
                    Text("Recent jobs shown: \(settings.recentCount)")
                }
            }
            Section("Notifications") {
                Toggle("Job finished", isOn: Binding(get: { settings.notifyFinished }, set: { settings.notifyFinished = $0 }))
                Toggle("Job failed", isOn: Binding(get: { settings.notifyFailed }, set: { settings.notifyFailed = $0 }))
                Toggle("Server went down", isOn: Binding(get: { settings.notifyDown }, set: { settings.notifyDown = $0 }))
                Text("macOS permission: \(notificationStatus())").font(.caption).foregroundStyle(.secondary)
            }
            Section("Login") {
                Toggle("Launch ComfyBar at login", isOn: Binding(get: { loginEnabled }, set: setLogin))
                if let m = loginMessage { Text(m).font(.caption).foregroundStyle(.secondary) }
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: loadFields)
        .onDisappear(perform: commitFields)
        .frame(width: 480)
        .padding(.vertical, 8)
    }

    private func loadFields() {
        folderText = settings.comfyFolder
        hostText = settings.host
        portText = String(settings.port)
        extraText = settings.extraArgs
        loginEnabled = SMAppService.mainApp.status == .enabled
        fieldMessage = nil
    }

    private func commitFields() {
        var problems: [String] = []
        let folder = folderText.trimmingCharacters(in: .whitespaces)
        if !folder.isEmpty { settings.comfyFolder = (folder as NSString).expandingTildeInPath }
        let host = hostText.trimmingCharacters(in: .whitespaces)
        if AppSettings.isValidHost(host) { settings.host = host } else { problems.append("host \"\(host)\" is not a hostname or IPv4 address") }
        if let p = Int(portText.trimmingCharacters(in: .whitespaces)), (1...65535).contains(p) { settings.port = p }
        else { problems.append("port must be 1-65535") }
        let extra = extraText.trimmingCharacters(in: .whitespaces)
        if let bad = extra.split(whereSeparator: \.isWhitespace).map(String.init).first(where: LaunchGuard.isForbidden) {
            problems.append("\"\(bad)\" is refused")
        } else {
            settings.extraArgs = extra
        }
        fieldMessage = problems.isEmpty ? nil : "Not applied: " + problems.joined(separator: "; ")
        loadFields(keepMessage: fieldMessage)
        applied()
    }

    private func loadFields(keepMessage: String?) {
        loadFields()
        fieldMessage = keepMessage
    }

    private func chooseFolder() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.directoryURL = URL(fileURLWithPath: settings.comfyFolder)
        if p.runModal() == .OK, let u = p.url { settings.comfyFolder = u.path; folderText = u.path; applied() }
    }

    private func setLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginMessage = nil
        } catch {
            loginMessage = "Could not change: \(error.localizedDescription)"
        }
        loginEnabled = SMAppService.mainApp.status == .enabled
        if SMAppService.mainApp.status == .requiresApproval {
            loginMessage = "Approve ComfyBar in System Settings › General › Login Items."
        }
    }
}
