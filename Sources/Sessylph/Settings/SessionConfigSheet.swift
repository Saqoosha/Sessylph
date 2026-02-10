import SwiftUI

struct SessionConfigSheet: View {
    @Binding var options: ClaudeCodeOptions
    @Environment(\.dismiss) private var dismiss
    var onStart: () -> Void

    @State private var cliOptions = ClaudeCLI.CLIOptions(modelAliases: [], permissionModes: [])

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Model & Permissions") {
                    Picker("Model", selection: binding(for: \.model)) {
                        Text("Default").tag("")
                        ForEach(cliOptions.modelAliases, id: \.self) { alias in
                            Text(alias.prefix(1).uppercased() + alias.dropFirst()).tag(alias)
                        }
                    }

                    Picker("Permission Mode", selection: binding(for: \.permissionMode)) {
                        Text("Default").tag("")
                        ForEach(cliOptions.permissionModes.filter({ $0 != "default" }), id: \.self) { mode in
                            Text(Self.permissionModeLabel(mode)).tag(mode)
                        }
                    }

                    Toggle("Skip Permissions", isOn: $options.dangerouslySkipPermissions)
                }

                Section("Session") {
                    Toggle("Continue Last Session", isOn: $options.continueSession)
                    Toggle("Verbose Output", isOn: $options.verbose)

                    if let budget = options.maxBudgetUSD {
                        HStack {
                            Text("Max Budget")
                            Spacer()
                            Text("$\(budget, specifier: "%.2f")")
                        }
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Start") {
                    onStart()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 400, height: 350)
        .onAppear {
            cliOptions = ClaudeCLI.discoverCLIOptions()
        }
    }

    private static func permissionModeLabel(_ mode: String) -> String {
        switch mode {
        case "default": "Default"
        case "plan": "Plan"
        case "acceptEdits": "Accept Edits"
        case "delegate": "Delegate"
        case "dontAsk": "Don't Ask"
        case "bypassPermissions": "Bypass Permissions"
        default: mode
        }
    }

    private func binding(for keyPath: WritableKeyPath<ClaudeCodeOptions, String?>) -> Binding<String> {
        Binding(
            get: { options[keyPath: keyPath] ?? "" },
            set: { options[keyPath: keyPath] = $0.isEmpty ? nil : $0 }
        )
    }
}
