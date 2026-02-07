import SwiftUI

struct SessionConfigSheet: View {
    @Binding var options: ClaudeCodeOptions
    @Environment(\.dismiss) private var dismiss
    var onStart: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Model & Permissions") {
                    Picker("Model", selection: binding(for: \.model)) {
                        Text("Default").tag("")
                        Text("Sonnet").tag("sonnet")
                        Text("Opus").tag("opus")
                        Text("Haiku").tag("haiku")
                    }

                    Picker("Permission Mode", selection: binding(for: \.permissionMode)) {
                        Text("Default").tag("")
                        Text("Plan").tag("plan")
                        Text("Accept Edits").tag("acceptEdits")
                        Text("Bypass").tag("bypassPermissions")
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
    }

    private func binding(for keyPath: WritableKeyPath<ClaudeCodeOptions, String?>) -> Binding<String> {
        Binding(
            get: { options[keyPath: keyPath] ?? "" },
            set: { options[keyPath: keyPath] = $0.isEmpty ? nil : $0 }
        )
    }
}
