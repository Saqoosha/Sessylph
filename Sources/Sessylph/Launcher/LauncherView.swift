import SwiftUI

struct LauncherView: View {
    // Shared with General Settings
    @AppStorage(Defaults.defaultModel) private var model = ""
    @AppStorage(Defaults.defaultPermissionMode) private var permissionMode = ""
    // Launcher-only options
    @AppStorage(Defaults.launcherSkipPermissions) private var skipPermissions = false
    @AppStorage(Defaults.launcherContinueSession) private var continueSession = false
    @AppStorage(Defaults.launcherVerbose) private var verbose = false

    @State private var selectedDirectory: URL?
    @State private var recentDirectories: [URL] = []
    @State private var hoveredDirectory: URL?
    @State private var isLaunching = false
    @State private var cliOptions = ClaudeCLI.CLIOptions(modelAliases: [], permissionModes: [])

    var onLaunch: ((URL, ClaudeCodeOptions) -> Void)?

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                header
                directoryCard
                if !recentDirectories.isEmpty {
                    recentSection
                }
                optionsSection
                startButton
            }
            .padding(.horizontal, 36)
            .padding(.vertical, 36)
            .frame(maxWidth: 480)
            .frame(maxWidth: .infinity)
            .frame(minHeight: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .scrollBounceBehavior(.basedOnSize)
        .contentMargins(.vertical, 0, for: .scrollContent)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .disabled(isLaunching)
        .defaultScrollAnchor(.center)
        .onAppear {
            recentDirectories = RecentDirectories.load()
            cliOptions = ClaudeCLI.discoverCLIOptions()
        }
    }

    // MARK: - Start Button

    private var startButton: some View {
        Button {
            launch()
        } label: {
            Group {
                if isLaunching {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Starting...")
                    }
                } else {
                    Label("Start Claude", systemImage: "play.fill")
                }
            }
            .frame(width: 140)
        }
        .controlSize(.large)
        .keyboardShortcut(.return, modifiers: [])
        .disabled(selectedDirectory == nil || isLaunching)
        .padding(.top, 4)
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 6) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 64, height: 64)
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
                    .foregroundStyle(selectedDirectory != nil ? Color.accentColor : Color.secondary)

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

            VStack(spacing: 0) {
                ForEach(Array(recentDirectories.prefix(RecentDirectories.maxCount).enumerated()), id: \.element.path) { index, dir in
                    recentRow(dir)
                    if index < min(recentDirectories.count, RecentDirectories.maxCount) - 1 {
                        Divider().padding(.leading, 34)
                    }
                }
            }
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    private func recentRow(_ dir: URL) -> some View {
        let isSelected = selectedDirectory == dir
        let isHovered = hoveredDirectory == dir
        return Button {
            selectedDirectory = dir
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "folder.fill")
                    .foregroundStyle(.secondary)
                    .font(.callout)
                    .frame(width: 16)
                Text(dir.lastPathComponent)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                Spacer(minLength: 0)
                if isHovered {
                    Button {
                        removeRecent(dir)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                } else {
                    Text(dir.deletingLastPathComponent().abbreviatingWithTildeInPath)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                isSelected
                    ? Color.accentColor.opacity(0.15)
                    : isHovered ? Color.primary.opacity(0.04) : Color.clear
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
                        Text("Auto").tag("")
                        ForEach(cliOptions.modelAliases, id: \.self) { alias in
                            Text(alias.prefix(1).uppercased() + alias.dropFirst()).tag(alias)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                GridRow {
                    Text("Permission:")
                        .foregroundStyle(.secondary)
                        .gridColumnAlignment(.trailing)
                    Picker("", selection: $permissionMode) {
                        ForEach(cliOptions.permissionModes, id: \.self) { mode in
                            Text(Self.permissionModeLabel(mode)).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .disabled(skipPermissions)
                }
            }

            HStack(spacing: 16) {
                Toggle("Skip permissions", isOn: $skipPermissions)
                Toggle("Continue session", isOn: $continueSession)
                Toggle("Verbose", isOn: $verbose)
            }
            .toggleStyle(.checkbox)
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Helpers

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

    // MARK: - Actions

    private func launch() {
        guard let dir = selectedDirectory, !isLaunching else { return }
        isLaunching = true
        RecentDirectories.add(dir)
        var opts = ClaudeCodeOptions()
        opts.model = model.isEmpty ? nil : model
        opts.permissionMode = permissionMode.isEmpty ? nil : permissionMode
        opts.dangerouslySkipPermissions = skipPermissions
        opts.continueSession = continueSession
        opts.verbose = verbose
        onLaunch?(dir, opts)
    }

    private func removeRecent(_ dir: URL) {
        RecentDirectories.remove(dir)
        withAnimation {
            recentDirectories.removeAll { $0 == dir }
        }
        if selectedDirectory == dir {
            selectedDirectory = nil
        }
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
    static let maxCount = 10

    static func load() -> [URL] {
        guard let paths = UserDefaults.standard.stringArray(forKey: Defaults.recentDirectories) else {
            return []
        }
        return paths.map { URL(fileURLWithPath: $0) }
    }

    static func remove(_ url: URL) {
        var paths = UserDefaults.standard.stringArray(forKey: Defaults.recentDirectories) ?? []
        paths.removeAll { $0 == url.path }
        UserDefaults.standard.set(paths, forKey: Defaults.recentDirectories)
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
