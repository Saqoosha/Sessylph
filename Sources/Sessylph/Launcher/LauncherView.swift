import SwiftUI

struct LauncherView: View {
    @State private var selectedDirectory: URL?
    @State private var options = ClaudeCodeOptions()
    @State private var recentDirectories: [URL] = []

    var onLaunch: ((URL, ClaudeCodeOptions) -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            // Folder section
            folderSection
                .padding(.horizontal, 32)
                .padding(.top, 28)
                .padding(.bottom, 20)

            Divider()
                .padding(.horizontal, 24)

            // Options section
            optionsSection
                .padding(.horizontal, 32)
                .padding(.top, 20)
                .padding(.bottom, 24)

            Spacer()

            // Launch button
            launchButton
                .padding(.bottom, 28)
        }
        .frame(minWidth: 900, minHeight: 600)
        .onAppear {
            recentDirectories = RecentDirectories.load()
        }
    }

    // MARK: - Folder Section

    private var folderSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Working Directory")
                .font(.headline)

            HStack {
                if let dir = selectedDirectory {
                    Image(systemName: "folder.fill")
                        .foregroundStyle(.secondary)
                    Text(dir.abbreviatingWithTildeInPath)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else {
                    Text("No folder selected")
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                Button("Choose...") {
                    chooseFolder()
                }
            }
            .padding(10)
            .background(.quaternary.opacity(0.5))
            .cornerRadius(8)

            if !recentDirectories.isEmpty {
                Text("Recent")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                VStack(spacing: 2) {
                    ForEach(recentDirectories.prefix(8), id: \.path) { dir in
                        Button {
                            selectedDirectory = dir
                        } label: {
                            HStack {
                                Image(systemName: "folder")
                                    .foregroundStyle(.secondary)
                                    .frame(width: 16)
                                Text(dir.abbreviatingWithTildeInPath)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .padding(.vertical, 4)
                        .padding(.horizontal, 8)
                        .background(
                            selectedDirectory == dir
                                ? Color.accentColor.opacity(0.15)
                                : Color.clear
                        )
                        .cornerRadius(4)
                    }
                }
            }
        }
    }

    // MARK: - Options Section

    private var optionsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Options")
                .font(.headline)

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow {
                    Text("Model:")
                        .gridColumnAlignment(.trailing)
                    Picker("", selection: $options.model ?? "") {
                        Text("Default").tag("")
                        Text("claude-sonnet-4-5-20250929").tag("claude-sonnet-4-5-20250929")
                        Text("claude-opus-4-6").tag("claude-opus-4-6")
                        Text("claude-haiku-4-5-20251001").tag("claude-haiku-4-5-20251001")
                    }
                    .labelsHidden()
                    .frame(width: 260)
                }

                GridRow {
                    Text("Permission:")
                        .gridColumnAlignment(.trailing)
                    Picker("", selection: $options.permissionMode ?? "") {
                        Text("Default").tag("")
                        Text("Plan mode").tag("plan")
                        Text("Auto-accept edits").tag("auto-edit")
                        Text("Full auto").tag("full-auto")
                    }
                    .labelsHidden()
                    .frame(width: 260)
                }
            }

            Toggle("Dangerously skip permissions", isOn: $options.dangerouslySkipPermissions)
            Toggle("Continue previous session", isOn: $options.continueSession)
            Toggle("Verbose output", isOn: $options.verbose)
        }
    }

    // MARK: - Launch Button

    private var launchButton: some View {
        Button {
            guard let dir = selectedDirectory else { return }
            RecentDirectories.add(dir)
            // Normalize empty string options to nil
            var opts = options
            if opts.model?.isEmpty == true { opts.model = nil }
            if opts.permissionMode?.isEmpty == true { opts.permissionMode = nil }
            onLaunch?(dir, opts)
        } label: {
            Text("Start Claude")
                .frame(width: 160)
        }
        .controlSize(.large)
        .keyboardShortcut(.return, modifiers: [])
        .disabled(selectedDirectory == nil)
    }

    // MARK: - Actions

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Select"
        panel.message = "Choose a working directory for Claude Code"

        if panel.runModal() == .OK, let url = panel.url {
            selectedDirectory = url
        }
    }
}

// MARK: - Optional Binding Extension

private extension Binding where Value == String? {
    init(_ source: Binding<String?>, default defaultValue: String) {
        self.init(
            get: { source.wrappedValue ?? defaultValue },
            set: { source.wrappedValue = $0 == defaultValue ? nil : $0 }
        )
    }

    static func ?? (lhs: Binding<String?>, rhs: String) -> Binding<String> {
        Binding<String>(
            get: { lhs.wrappedValue ?? rhs },
            set: { lhs.wrappedValue = $0 == rhs ? nil : $0 }
        )
    }
}

// MARK: - Recent Directories

enum RecentDirectories {
    private static let maxCount = 10

    static func load() -> [URL] {
        guard let paths = UserDefaults.standard.stringArray(forKey: Defaults.recentDirectories) else {
            return []
        }
        return paths.map { URL(fileURLWithPath: $0) }
    }

    static func add(_ url: URL) {
        var paths = UserDefaults.standard.stringArray(forKey: Defaults.recentDirectories) ?? []
        paths.removeAll { $0 == url.path }
        paths.insert(url.path, at: 0)
        if paths.count > maxCount {
            paths = Array(paths.prefix(maxCount))
        }
        UserDefaults.standard.set(paths, forKey: Defaults.recentDirectories)
    }
}

// MARK: - URL Extension

extension URL {
    var abbreviatingWithTildeInPath: String {
        (path as NSString).abbreviatingWithTildeInPath
    }
}
