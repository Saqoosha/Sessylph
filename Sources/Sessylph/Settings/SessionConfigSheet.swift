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
                            Text(PermissionMode.label(for: mode)).tag(mode)
                        }
                    }

                    Toggle("Skip Permissions", isOn: $options.dangerouslySkipPermissions)
                }

                Section("Effort") {
                    Picker("Effort Level", selection: binding(for: \.effortLevel)) {
                        Text("Auto").tag("")
                        Text("Low").tag("low")
                        Text("Medium").tag("medium")
                        Text("High").tag("high")
                    }
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

    private func binding(for keyPath: WritableKeyPath<ClaudeCodeOptions, String?>) -> Binding<String> {
        Binding(
            get: { options[keyPath: keyPath] ?? "" },
            set: { options[keyPath: keyPath] = $0.isEmpty ? nil : $0 }
        )
    }
}
