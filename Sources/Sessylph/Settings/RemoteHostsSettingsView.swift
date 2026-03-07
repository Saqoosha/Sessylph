import SwiftUI

struct RemoteHostsSettingsView: View {
    @ObservedObject private var store = RemoteHostStore.shared
    @State private var selectedHostId: UUID?
    @State private var editingHost: RemoteHost?
    @State private var testResult: String?
    @State private var isTesting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Remote Hosts")
                .font(.headline)

            List(selection: $selectedHostId) {
                ForEach(store.hosts) { host in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(host.label)
                                .font(.body.weight(.medium))
                            Text(host.sshDestination)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .tag(host.id)
                }
            }
            .frame(minHeight: 120)
            .clipShape(RoundedRectangle(cornerRadius: 6))

            HStack(spacing: 8) {
                Button(action: addHost) {
                    Image(systemName: "plus")
                }
                Button(action: removeHost) {
                    Image(systemName: "minus")
                }
                .disabled(selectedHostId == nil)

                Spacer()

                Button("Test Connection") {
                    testConnection()
                }
                .disabled(selectedHostId == nil || isTesting)

                Button("Edit...") {
                    editHost()
                }
                .disabled(selectedHostId == nil)
            }

            if let testResult {
                Text(testResult)
                    .font(.caption)
                    .foregroundStyle(testResult.contains("Success") ? .green : .red)
            }
        }
        .sheet(item: $editingHost) { host in
            RemoteHostEditSheet(host: host) { updatedHost in
                if store.hosts.contains(where: { $0.id == updatedHost.id }) {
                    store.update(updatedHost)
                } else {
                    store.add(updatedHost)
                }
                editingHost = nil
            }
        }
    }

    private func addHost() {
        editingHost = RemoteHost(label: "", host: "")

    }

    private func editHost() {
        guard let id = selectedHostId,
              let host = store.hosts.first(where: { $0.id == id }) else { return }
        editingHost = host

    }

    private func removeHost() {
        guard let id = selectedHostId else { return }
        store.remove(id: id)
        selectedHostId = nil
        testResult = nil
    }

    private func testConnection() {
        guard let id = selectedHostId,
              let host = store.hosts.first(where: { $0.id == id }) else { return }
        isTesting = true
        testResult = "Testing..."
        Task {
            let success = await TmuxManager.shared.testSSHConnection(remoteHost: host)
            isTesting = false
            testResult = success ? "Success -- connected to \(host.host)" : "Failed -- could not connect to \(host.host)"
        }
    }
}

// MARK: - Edit Sheet

struct RemoteHostEditSheet: View {
    @State var host: RemoteHost
    var onSave: (RemoteHost) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 16) {
            Text(host.label.isEmpty ? "New Remote Host" : "Edit Remote Host")
                .font(.headline)

            Form {
                TextField("Label:", text: $host.label)
                TextField("Host:", text: $host.host)
                    .textContentType(.URL)
                TextField("User:", text: Binding(
                    get: { host.user ?? "" },
                    set: { host.user = $0.isEmpty ? nil : $0 }
                ))
                TextField("Port:", text: Binding(
                    get: { host.port.map(String.init) ?? "" },
                    set: {
                        if let value = Int($0), (1...65535).contains(value) {
                            host.port = value
                        } else if $0.isEmpty {
                            host.port = nil
                        }
                    }
                ))
                HStack {
                    TextField("Identity File:", text: Binding(
                        get: { host.identityFile ?? "" },
                        set: { host.identityFile = $0.isEmpty ? nil : $0 }
                    ))
                    Button("Browse...") {
                        let panel = NSOpenPanel()
                        panel.canChooseFiles = true
                        panel.canChooseDirectories = false
                        panel.allowsMultipleSelection = false
                        panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory() + "/.ssh")
                        if panel.runModal() == .OK, let url = panel.url {
                            host.identityFile = url.path
                        }
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save") {
                    onSave(host)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!host.isValid)
            }
        }
        .padding()
        .frame(width: 400)
    }
}
