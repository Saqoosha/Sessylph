import AppKit
import SwiftUI

struct CommandListView: View {
    let commands: [SlashCommand]
    let onSelect: (String) -> Void
    var onAdd: ((String) -> Void)?

    @State private var searchText = ""
    @State private var isAddingCommand = false
    @State private var newCommandText = ""
    @FocusState private var isNewCommandFocused: Bool

    private var globalCommands: [SlashCommand] {
        commands.filter(\.isGlobal).filtered(by: searchText)
    }

    private var projectCommands: [SlashCommand] {
        commands.filter { !$0.isGlobal }.filtered(by: searchText)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Search field
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 11))
                TextField("Filter commands…", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)

            Divider()

            if globalCommands.isEmpty && projectCommands.isEmpty && !isAddingCommand {
                Text("No commands found")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if !globalCommands.isEmpty {
                            sectionHeader("Global")
                            ForEach(globalCommands) { cmd in
                                commandRow(cmd)
                            }
                        }
                        if !projectCommands.isEmpty {
                            sectionHeader("This Project")
                            ForEach(projectCommands) { cmd in
                                commandRow(cmd)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }

            if isAddingCommand {
                Divider()
                HStack(spacing: 6) {
                    TextField("/command or phrase", text: $newCommandText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12, design: .monospaced))
                        .focused($isNewCommandFocused)
                        .onSubmit { commitNewCommand() }
                        .onAppear { isNewCommandFocused = true }
                    Button {
                        isAddingCommand = false
                        newCommandText = ""
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            }

            Divider()

            Button {
                isAddingCommand = true
                newCommandText = ""
            } label: {
                HStack {
                    Image(systemName: "plus")
                        .font(.system(size: 11))
                    Text("Add Shortcut")
                        .font(.system(size: 12))
                    Spacer()
                }
                .contentShape(Rectangle())
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
    }

    private func commitNewCommand() {
        let text = newCommandText.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else {
            isAddingCommand = false
            return
        }
        onAdd?(text)
        isAddingCommand = false
        newCommandText = ""
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 2)
    }

    private func commandRow(_ command: SlashCommand) -> some View {
        Button {
            onSelect(command.command)
        } label: {
            HStack {
                Text(command.command)
                    .font(.system(size: 12, design: .monospaced))
                Spacer()
                Text("\(command.useCount)×")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
    }
}

private extension Array where Element == SlashCommand {
    func filtered(by searchText: String) -> [SlashCommand] {
        guard !searchText.isEmpty else { return self }
        let query = searchText.lowercased()
        return filter { $0.command.lowercased().contains(query) }
    }
}

// MARK: - Hosting Controller

final class CommandListHostingController: NSHostingController<CommandListView> {
    override func viewDidLoad() {
        super.viewDidLoad()
        preferredContentSize = NSSize(width: 240, height: 320)
    }
}
