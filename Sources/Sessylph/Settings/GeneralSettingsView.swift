import SwiftUI

struct GeneralSettingsView: View {
    @AppStorage(Defaults.defaultModel) private var defaultModel = ""
    @AppStorage(Defaults.defaultPermissionMode) private var defaultPermissionMode = ""
    @AppStorage(Defaults.notificationsEnabled) private var notificationsEnabled = true
    @AppStorage(Defaults.notifyOnStop) private var notifyOnStop = true
    @AppStorage(Defaults.notifyOnPermission) private var notifyOnPermission = true
    @AppStorage(Defaults.activateOnStop) private var activateOnStop = false
    @AppStorage(Defaults.terminalFontSize) private var terminalFontSize = 13.0
    @AppStorage(Defaults.suppressCloseTabAlert) private var suppressCloseTabAlert = false
    @AppStorage(Defaults.suppressQuitAlert) private var suppressQuitAlert = false

    private let models = ["", "sonnet", "opus", "haiku"]
    private let permissionModes = ["", "default", "plan", "acceptEdits", "bypassPermissions"]

    var body: some View {
        Form {
            Section("Claude Code Defaults") {
                Picker("Default Model", selection: $defaultModel) {
                    Text("Auto").tag("")
                    Text("Sonnet").tag("sonnet")
                    Text("Opus").tag("opus")
                    Text("Haiku").tag("haiku")
                }

                Picker("Permission Mode", selection: $defaultPermissionMode) {
                    Text("Default").tag("")
                    Text("Plan").tag("plan")
                    Text("Accept Edits").tag("acceptEdits")
                    Text("Bypass Permissions").tag("bypassPermissions")
                }
            }

            Section("Notifications") {
                Toggle("Enable Notifications", isOn: $notificationsEnabled)
                Toggle("Notify on Task Completion", isOn: $notifyOnStop)
                    .disabled(!notificationsEnabled)
                Toggle("Notify on Permission Request", isOn: $notifyOnPermission)
                    .disabled(!notificationsEnabled)
                Toggle("Bring to Front on Task Completion", isOn: $activateOnStop)
            }

            Section("Terminal") {
                HStack {
                    Text("Font Size")
                    Slider(value: $terminalFontSize, in: 10...24, step: 1) {
                        Text("Font Size")
                    }
                    Text("\(Int(terminalFontSize))pt")
                        .monospacedDigit()
                        .frame(width: 40)
                }
            }

            Section("Confirmations") {
                Toggle("Confirm before closing a running tab", isOn: Binding(
                    get: { !suppressCloseTabAlert },
                    set: { suppressCloseTabAlert = !$0 }
                ))
                Toggle("Confirm before quitting with active sessions", isOn: Binding(
                    get: { !suppressQuitAlert },
                    set: { suppressQuitAlert = !$0 }
                ))
            }

            Section("Info") {
                if let version = ClaudeCLI.claudeVersion() {
                    LabeledContent("Claude Code", value: version)
                } else {
                    LabeledContent("Claude Code", value: "Not found")
                        .foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .frame(minWidth: 450)
    }
}
