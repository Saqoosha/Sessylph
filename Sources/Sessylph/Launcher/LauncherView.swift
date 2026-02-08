import SwiftUI

struct LauncherView: View {
    // Persisted launcher options
    @AppStorage(Defaults.launcherModel) private var model = ""
    @AppStorage(Defaults.launcherPermissionMode) private var permissionMode = ""
    @AppStorage(Defaults.launcherSkipPermissions) private var skipPermissions = false
    @AppStorage(Defaults.launcherContinueSession) private var continueSession = false
    @AppStorage(Defaults.launcherVerbose) private var verbose = false

    @State private var selectedDirectory: URL?
    @State private var recentDirectories: [URL] = []
    @State private var hoveredDirectory: URL?

    var onLaunch: ((URL, ClaudeCodeOptions) -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 28) {
                    header
                    directoryCard
                    if !recentDirectories.isEmpty {
                        recentSection
                    }
                    optionsSection
                }
                .padding(.horizontal, 36)
                .padding(.top, 36)
                .padding(.bottom, 20)
            }

            Divider()

            // Footer
            HStack {
                Spacer()
                Button {
                    launch()
                } label: {
                    Label("Start Claude", systemImage: "play.fill")
                        .frame(width: 140)
                }
                .controlSize(.large)
                .keyboardShortcut(.return, modifiers: [])
                .disabled(selectedDirectory == nil)
                Spacer()
            }
            .padding(.vertical, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            recentDirectories = RecentDirectories.load()
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 6) {
            Image(systemName: "terminal.fill")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text("Sessylph")
                .font(.title.bold())
            Text("Start a new Claude Code session")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 4)
    }

    // MARK: - Directory Card

    private var directoryCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Working Directory")
                .font(.headline)

            HStack(spacing: 10) {
                Image(systemName: "folder.fill")
                    .font(.title3)
                    .foregroundStyle(selectedDirectory != nil ? .orange : .secondary)

                if let dir = selectedDirectory {
                    Text(dir.abbreviatingWithTildeInPath)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.primary)
                } else {
                    Text("No folder selected")
                        .foregroundStyle(.tertiary)
                }

                Spacer()

                Button("Browse...") {
                    chooseFolder()
                }
            }
            .padding(12)
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    // MARK: - Recent Directories

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Recents")
                .font(.headline)

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 160, maximum: 240), spacing: 8)],
                spacing: 8
            ) {
                ForEach(recentDirectories.prefix(8), id: \.path) { dir in
                    recentCard(dir)
                }
            }
        }
    }

    private func recentCard(_ dir: URL) -> some View {
        let isSelected = selectedDirectory == dir
        let isHovered = hoveredDirectory == dir
        return Button {
            selectedDirectory = dir
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "folder.fill")
                    .foregroundStyle(.orange.opacity(0.8))
                    .font(.callout)
                VStack(alignment: .leading, spacing: 2) {
                    Text(dir.lastPathComponent)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                    Text(dir.deletingLastPathComponent().abbreviatingWithTildeInPath)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                isSelected
                    ? Color.accentColor.opacity(0.15)
                    : isHovered ? Color.primary.opacity(0.04) : Color.clear
            )
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(
                        isSelected ? Color.accentColor.opacity(0.4) : Color.primary.opacity(0.08),
                        lineWidth: 1
                    )
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered in
            hoveredDirectory = isHovered ? dir : nil
        }
    }

    // MARK: - Options Section

    private var optionsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Options")
                .font(.headline)

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    Text("Model:")
                        .foregroundStyle(.secondary)
                        .gridColumnAlignment(.trailing)
                    Picker("", selection: $model) {
                        Text("Default").tag("")
                        Text("claude-sonnet-4-5-20250929").tag("claude-sonnet-4-5-20250929")
                        Text("claude-opus-4-6").tag("claude-opus-4-6")
                        Text("claude-haiku-4-5-20251001").tag("claude-haiku-4-5-20251001")
                    }
                    .labelsHidden()
                    .frame(width: 280)
                }

                GridRow {
                    Text("Permission:")
                        .foregroundStyle(.secondary)
                        .gridColumnAlignment(.trailing)
                    Picker("", selection: $permissionMode) {
                        Text("Default").tag("")
                        Text("Plan mode").tag("plan")
                        Text("Auto-accept edits").tag("auto-edit")
                        Text("Full auto").tag("full-auto")
                    }
                    .labelsHidden()
                    .frame(width: 280)
                }
            }

            HStack(spacing: 16) {
                Toggle("Skip permissions", isOn: $skipPermissions)
                Toggle("Continue session", isOn: $continueSession)
                Toggle("Verbose", isOn: $verbose)
            }
            .toggleStyle(.checkbox)
        }
    }

    // MARK: - Actions

    private func launch() {
        guard let dir = selectedDirectory else { return }
        RecentDirectories.add(dir)
        var opts = ClaudeCodeOptions()
        opts.model = model.isEmpty ? nil : model
        opts.permissionMode = permissionMode.isEmpty ? nil : permissionMode
        opts.dangerouslySkipPermissions = skipPermissions
        opts.continueSession = continueSession
        opts.verbose = verbose
        onLaunch?(dir, opts)
    }

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
