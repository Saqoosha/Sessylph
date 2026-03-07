import SwiftUI

private enum CodexExecutionMode: String, CaseIterable {
    case ask
    case fullAuto
    case yolo

    var displayName: String {
        switch self {
        case .ask: return "Ask"
        case .fullAuto: return "Full auto"
        case .yolo: return "YOLO"
        }
    }

    var description: String {
        switch self {
        case .ask: return "Uses the selected approval policy."
        case .fullAuto: return "Runs sandboxed with low-friction approvals."
        case .yolo: return "No sandbox, no approvals. Extremely dangerous."
        }
    }

    var detailLabel: String {
        switch self {
        case .ask: return "Approval:"
        case .fullAuto: return "Behavior:"
        case .yolo: return "Warning:"
        }
    }

    var detailValue: String {
        switch self {
        case .ask: return ""
        case .fullAuto: return "workspace-write + on-request"
        case .yolo: return "No sandbox / no approvals"
        }
    }
}

struct LauncherView: View {
    // CLI type selection
    @AppStorage(Defaults.defaultCLIType) private var cliTypeRaw = CLIType.claudeCode.rawValue
    // Claude Code options
    @AppStorage(Defaults.defaultModel) private var model = ""
    @AppStorage(Defaults.defaultPermissionMode) private var permissionMode = ""
    @AppStorage(Defaults.launcherSkipPermissions) private var skipPermissions = false
    @AppStorage(Defaults.launcherContinueSession) private var continueSession = false
    @AppStorage(Defaults.launcherVerbose) private var verbose = false
    // Codex options
    @AppStorage(Defaults.codexModel) private var codexModel = ""
    @AppStorage(Defaults.codexApprovalMode) private var codexApprovalMode = "on-request"
    @AppStorage(Defaults.codexFullAuto) private var codexFullAuto = false
    @AppStorage(Defaults.codexDangerouslyBypass) private var codexDangerouslyBypass = false

    @State private var selectedDirectory: URL?
    @State private var recentDirectories: [URL] = []
    @State private var hoveredDirectory: URL?
    @State private var isLaunching = false
    @State private var cliOptions = ClaudeCLI.CLIOptions(modelAliases: [], permissionModes: [])
    @State private var codexCLIOptions = CodexCLI.CLIOptions(approvalModes: [])
    @State private var searchText = ""
    @State private var ccSessions: [ClaudeSessionEntry] = []
    @State private var codexSessions: [CodexSessionEntry] = []
    @State private var hoveredSessionId: String?

    private var cliType: CLIType {
        CLIType(rawValue: cliTypeRaw) ?? .claudeCode
    }

    private var codexExecutionMode: Binding<CodexExecutionMode> {
        Binding(
            get: {
                if codexDangerouslyBypass { return .yolo }
                if codexFullAuto { return .fullAuto }
                return .ask
            },
            set: { newValue in
                switch newValue {
                case .ask:
                    codexFullAuto = false
                    codexDangerouslyBypass = false
                case .fullAuto:
                    codexFullAuto = true
                    codexDangerouslyBypass = false
                case .yolo:
                    codexFullAuto = false
                    codexDangerouslyBypass = true
                }
            }
        )
    }

    var onLaunch: ((URL, LaunchConfig) -> Void)?

    /// Row height for list items (used to calculate fixed list height)
    private static let rowHeight: CGFloat = 34
    private static let listRowCount = 10

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                header
                optionsSection
                directoryCard
                startButton
                searchField
                listsSection
            }
            .padding(.horizontal, 36)
            .padding(.vertical, 36)
            .frame(maxWidth: 720)
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
            codexCLIOptions = CodexCLI.discoverCLIOptions()
            Task {
                async let claudeSessions = ClaudeSessionHistory.shared.loadSessions()
                async let codexSessions = CodexSessionHistory.shared.loadSessions()
                ccSessions = await claudeSessions
                self.codexSessions = await codexSessions
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 6) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 64, height: 64)
            Text("Sessylph")
                .font(.title.bold())
            Text("Start a new \(cliType.displayName) session")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 4)
    }

    // MARK: - Options

    private var optionsSection: some View {
        VStack(spacing: 12) {
            // CLI type picker
            Picker("", selection: $cliTypeRaw) {
                ForEach(CLIType.allCases, id: \.rawValue) { type in
                    Text(type.displayName).tag(type.rawValue)
                }
            }
            .pickerStyle(.segmented)
            .fixedSize()

            if cliType == .claudeCode {
                claudeCodeOptions
            } else {
                codexOptionsView
            }
        }
    }

    private var claudeCodeOptions: some View {
        VStack(spacing: 12) {
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
                    .fixedSize()
                }

                GridRow {
                    Text("Permission:")
                        .foregroundStyle(.secondary)
                        .gridColumnAlignment(.trailing)
                    Picker("", selection: $permissionMode) {
                        ForEach(cliOptions.permissionModes, id: \.self) { mode in
                            Text(PermissionMode.label(for: mode)).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
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
        .frame(minHeight: 94, alignment: .top)
    }

    private var codexOptionsView: some View {
        VStack(spacing: 12) {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    Text("Model:")
                        .foregroundStyle(.secondary)
                        .gridColumnAlignment(.trailing)
                    ComboBox(items: CodexCLI.knownModels, text: $codexModel, placeholder: "Default")
                        .frame(width: 180, height: 24)
                }

                GridRow {
                    Text("Mode:")
                        .foregroundStyle(.secondary)
                        .gridColumnAlignment(.trailing)
                    Picker("", selection: codexExecutionMode) {
                        ForEach(CodexExecutionMode.allCases, id: \.rawValue) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }

                GridRow {
                    Text(codexExecutionMode.wrappedValue.detailLabel)
                        .foregroundStyle(.secondary)
                        .gridColumnAlignment(.trailing)
                    Group {
                        if codexExecutionMode.wrappedValue == .ask {
                            Picker("", selection: $codexApprovalMode) {
                                ForEach(codexCLIOptions.approvalModes, id: \.self) { mode in
                                    Text(mode).tag(mode)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 180, alignment: .leading)
                        } else {
                            Text(codexExecutionMode.wrappedValue.detailValue)
                                .font(.callout)
                                .foregroundStyle(codexExecutionMode.wrappedValue == .yolo ? .red : .secondary)
                                .frame(width: 180, alignment: .leading)
                        }
                    }
                }
            }
        }
        .frame(minHeight: 94, alignment: .top)
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
                    Label("Start \(cliType.displayName)", systemImage: "play.fill")
                }
            }
            .frame(width: 140)
        }
        .controlSize(.large)
        .keyboardShortcut(.return, modifiers: [])
        .disabled(selectedDirectory == nil || isLaunching)
        .padding(.top, 4)
    }

    // MARK: - Search

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.tertiary)
                .font(.callout)
            TextField("Filter...", text: $searchText)
                .textFieldStyle(.plain)
                .font(.callout)
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                        .font(.callout)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Lists (side by side)

    private var filteredDirectories: [URL] {
        guard !searchText.isEmpty else { return recentDirectories }
        let query = searchText.lowercased()
        return recentDirectories.filter { dir in
            dir.lastPathComponent.lowercased().contains(query)
                || dir.path.lowercased().contains(query)
        }
    }

    private var filteredSessions: [ClaudeSessionEntry] {
        guard !searchText.isEmpty else { return ccSessions }
        let query = searchText.lowercased()
        return ccSessions.filter { session in
            session.title.lowercased().contains(query)
                || session.projectName.lowercased().contains(query)
                || session.projectPath.lowercased().contains(query)
        }
    }

    private var filteredCodexSessions: [CodexSessionEntry] {
        guard !searchText.isEmpty else { return codexSessions }
        let query = searchText.lowercased()
        return codexSessions.filter { session in
            session.title.lowercased().contains(query)
                || session.projectName.lowercased().contains(query)
                || session.projectPath.lowercased().contains(query)
        }
    }

    private var listsSection: some View {
        HStack(alignment: .top, spacing: 20) {
            // Recent directories (left)
            VStack(alignment: .leading, spacing: 8) {
                Text("Recents")
                    .font(.headline)

                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(filteredDirectories.enumerated()), id: \.element.path) { index, dir in
                            recentRow(dir)
                            if index < filteredDirectories.count - 1 {
                                Divider().padding(.leading, 34)
                            }
                        }
                    }
                }
                .frame(height: Self.rowHeight * CGFloat(Self.listRowCount))
                .background(.regularMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .frame(maxWidth: .infinity)

            // Sessions (right)
            VStack(alignment: .leading, spacing: 8) {
                Text(cliType == .claudeCode ? "Claude Sessions" : "Codex Sessions")
                    .font(.headline)

                if cliType == .claudeCode {
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(Array(filteredSessions.enumerated()), id: \.element.id) { index, session in
                                sessionRow(session)
                                if index < filteredSessions.count - 1 {
                                    Divider().padding(.leading, 34)
                                }
                            }
                        }
                    }
                    .frame(height: Self.rowHeight * CGFloat(Self.listRowCount))
                    .background(.regularMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                } else {
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(Array(filteredCodexSessions.enumerated()), id: \.element.id) { index, session in
                                codexSessionRow(session)
                                if index < filteredCodexSessions.count - 1 {
                                    Divider().padding(.leading, 34)
                                }
                            }
                        }
                    }
                    .frame(height: Self.rowHeight * CGFloat(Self.listRowCount))
                    .background(.regularMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Recent Row

    private func recentRow(_ dir: URL) -> some View {
        let isSelected = selectedDirectory == dir
        let isHovered = hoveredDirectory == dir
        return Button {
            selectedDirectory = dir
            launch()
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

    // MARK: - Session Row

    private static let sessionDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.doesRelativeDateFormatting = true
        f.dateStyle = .short
        f.timeStyle = .short
        return f
    }()

    private func sessionRow(_ session: ClaudeSessionEntry) -> some View {
        let isHovered = hoveredSessionId == session.id
        return Button {
            launchSession(session)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "text.bubble")
                    .foregroundStyle(.secondary)
                    .font(.callout)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.title)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        Text(session.projectName)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text("\u{00B7}")
                            .font(.caption2)
                            .foregroundStyle(.quaternary)
                        Text(Self.sessionDateFormatter.string(from: session.timestamp))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isHovered ? Color.primary.opacity(0.04) : Color.clear)
        }
        .buttonStyle(.plain)
        .onHover { hovered in
            hoveredSessionId = hovered ? session.id : nil
        }
    }

    private func codexSessionRow(_ session: CodexSessionEntry) -> some View {
        let isHovered = hoveredSessionId == session.id
        return Button {
            launchCodexSession(session)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "terminal")
                    .foregroundStyle(.secondary)
                    .font(.callout)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.title)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        Text(session.projectName)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text("\u{00B7}")
                            .font(.caption2)
                            .foregroundStyle(.quaternary)
                        Text(Self.sessionDateFormatter.string(from: session.timestamp))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isHovered ? Color.primary.opacity(0.04) : Color.clear)
        }
        .buttonStyle(.plain)
        .onHover { hovered in
            hoveredSessionId = hovered ? session.id : nil
        }
    }

    // MARK: - Actions

    private func launch() {
        guard let dir = selectedDirectory, !isLaunching else { return }
        isLaunching = true
        RecentDirectories.add(dir)

        onLaunch?(dir, makeLaunchConfig())
    }

    private func launchSession(_ session: ClaudeSessionEntry) {
        guard !isLaunching else { return }
        let dir = URL(fileURLWithPath: session.projectPath)
        selectedDirectory = dir
        isLaunching = true
        RecentDirectories.add(dir)
        var opts = ClaudeCodeOptions()
        opts.model = model.isEmpty ? nil : model
        opts.permissionMode = permissionMode.isEmpty ? nil : permissionMode
        opts.dangerouslySkipPermissions = skipPermissions
        opts.resumeSessionId = session.id
        opts.verbose = verbose
        onLaunch?(dir, .claudeCode(opts))
    }

    private func launchCodexSession(_ session: CodexSessionEntry) {
        guard !isLaunching else { return }
        let dir = URL(fileURLWithPath: session.projectPath)
        selectedDirectory = dir
        isLaunching = true
        RecentDirectories.add(dir)
        var opts = makeCodexOptions()
        opts.resumeSessionId = session.id
        onLaunch?(dir, .codex(opts))
    }

    private func makeLaunchConfig() -> LaunchConfig {
        switch cliType {
        case .claudeCode:
            var opts = ClaudeCodeOptions()
            opts.model = model.isEmpty ? nil : model
            opts.permissionMode = permissionMode.isEmpty ? nil : permissionMode
            opts.dangerouslySkipPermissions = skipPermissions
            opts.continueSession = continueSession
            opts.verbose = verbose
            return .claudeCode(opts)

        case .codex:
            return .codex(makeCodexOptions())
        }
    }

    private func makeCodexOptions() -> CodexOptions {
        var opts = CodexOptions()
        opts.model = codexModel.isEmpty ? nil : codexModel
        switch codexExecutionMode.wrappedValue {
        case .ask:
            let validModes = Set(codexCLIOptions.approvalModes)
            opts.approvalMode = validModes.contains(codexApprovalMode) ? codexApprovalMode : nil
        case .fullAuto:
            opts.fullAuto = true
        case .yolo:
            opts.dangerouslyBypassApprovalsAndSandbox = true
        }
        return opts
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
        panel.message = "Choose a working directory"

        if panel.runModal() == .OK, let url = panel.url {
            selectedDirectory = url
        }
    }
}
