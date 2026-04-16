import SwiftUI

struct SessionConfigSheet: View {
    @Binding var options: ClaudeCodeOptions
    @Environment(\.dismiss) private var dismiss
    var onStart: () -> Void

    @State private var cliOptions = ClaudeCLI.CLIOptions(modelAliases: [], permissionModes: [], effortLevels: [])

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Model & Options") {
                    Picker("Model", selection: binding(for: \.model)) {
                        Text("Default").tag("")
                        ForEach(cliOptions.modelAliases, id: \.self) { alias in
                            Text(alias.prefix(1).uppercased() + alias.dropFirst()).tag(alias)
                        }
                    }

                    Picker("Effort Level", selection: binding(for: \.effortLevel)) {
                        Text("Auto").tag("")
                        ForEach(cliOptions.effortLevels, id: \.self) { level in
                            Text(ClaudeCLI.effortLevelLabel(level)).tag(level)
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

                Section("Session") {
                    Toggle("Continue Last Session", isOn: $options.continueSession)
                    Toggle("Verbose Output", isOn: $options.verbose)
                    Toggle("Bare Mode (scripted use)", isOn: $options.bare)
                    Toggle("Scrub Credentials from Subprocesses", isOn: $options.scrubSubprocessEnv)
                    Toggle("Flicker-Free Alt-Screen Rendering", isOn: $options.noFlicker)

                    if let budget = options.maxBudgetUSD {
                        HStack {
                            Text("Max Budget")
                            Spacer()
                            Text("$\(budget, specifier: "%.2f")")
                        }
                    }
                }

                Section("Channels") {
                    TextField("Channel server URLs (comma-separated)", text: channelsBinding)
                        .font(.system(.body, design: .monospaced))
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
        .frame(width: 420, height: 420)
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

    private var channelsBinding: Binding<String> {
        Binding(
            get: {
                options.channels?.joined(separator: ", ") ?? ""
            },
            set: { newValue in
                let urls = newValue.components(separatedBy: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                options.channels = urls.isEmpty ? nil : urls
            }
        )
    }
}
