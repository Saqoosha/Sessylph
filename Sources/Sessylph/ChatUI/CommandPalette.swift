// Sources/Sessylph/ChatUI/CommandPalette.swift
import SwiftUI

struct CommandPalette: View {
    let commands: [String]
    let onSelect: (String) -> Void
    @State private var searchText = ""
    @FocusState private var isFocused: Bool

    private var filtered: [String] {
        guard !searchText.isEmpty else { return commands }
        return commands.filter { $0.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Type a command...", text: $searchText)
                    .textFieldStyle(.plain)
                    .focused($isFocused)
                    .onSubmit {
                        if let first = filtered.first {
                            onSelect("/\(first) ")
                        }
                    }
            }
            .padding(12)

            Divider()

            List {
                let builtIn = filtered.filter { !$0.contains(":") }
                let skills = filtered.filter { $0.contains(":") }

                if !builtIn.isEmpty {
                    Section("Commands") {
                        ForEach(builtIn, id: \.self) { cmd in
                            Button {
                                onSelect("/\(cmd) ")
                            } label: {
                                HStack {
                                    Text("/\(cmd)")
                                        .fontWeight(.medium)
                                    Spacer()
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                if !skills.isEmpty {
                    Section("Skills") {
                        ForEach(skills, id: \.self) { cmd in
                            Button {
                                onSelect("/\(cmd) ")
                            } label: {
                                HStack {
                                    Text("/\(cmd)")
                                    Spacer()
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .frame(width: 400, height: 350)
        .onAppear { isFocused = true }
    }
}
