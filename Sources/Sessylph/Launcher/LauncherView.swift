import SwiftUI
import UniformTypeIdentifiers

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
    @AppStorage(Defaults.defaultEffortLevel) private var effortLevel = ""
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
    @State private var isDropTargeted = false

    // Remote session support
    @State private var connectionMode: ConnectionMode = .local
    @State private var selectedRemoteHostId: UUID?
    @State private var remoteSessions: [(name: String, windows: Int, created: String)] = []
    @State private var isLoadingRemoteSessions = false
    @State private var remoteDirectory = "~"
    @State private var remoteConnectionError: String?
    @State private var showRemoteBrowser = false
    @State private var remoteHistory: [RemoteHistoryEntry] = []
    @State private var hoveredRemoteHistoryId: String?

    @ObservedObject private var remoteHostStore = RemoteHostStore.shared

    enum ConnectionMode: String, CaseIterable {
        case local = "Local"
        case remote = "Remote"
    }

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
                connectionModeSelector
                if connectionMode == .local {
                    optionsSection
                    directoryCard
                    startButton
                    searchField
                    listsSection
                } else {
                    remoteSection
                }
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
        .onChange(of: selectedRemoteHostId) { _, _ in
            remoteSessions = []
            remoteConnectionError = nil
            loadRemoteSessions()
        }
        .onAppear {
            recentDirectories = RecentDirectories.load()
            remoteHistory = RemoteHistory.load()
            Task.detached {
                let claude = ClaudeCLI.discoverCLIOptions()
                let codex = CodexCLI.discoverCLIOptions()
                await MainActor.run {
                    cliOptions = claude
                    codexCLIOptions = codex
                }
            }
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
            Text("Start a new \(connectionMode == .local ? cliType.displayName : "remote") session")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 4)
    }

    // MARK: - Connection Mode

    private var connectionModeSelector: some View {
        Picker("", selection: $connectionMode) {
            ForEach(ConnectionMode.allCases, id: \.rawValue) { mode in
                Text(mode.rawValue).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .fixedSize()
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

                GridRow {
                    Text("Effort:")
                        .foregroundStyle(.secondary)
                        .gridColumnAlignment(.trailing)
                    Picker("", selection: $effortLevel) {
                        Text("Auto").tag("")
                        Text("Low").tag("low")
                        Text("Medium").tag("medium")
                        Text("High").tag("high")
                    }
                    .labelsHidden()
                    .fixedSize()
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
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
                    .opacity(isDropTargeted ? 1 : 0)
            )
            .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
                guard let provider = providers.first else { return false }
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    var isDir: ObjCBool = false
                    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir),
                          isDir.boolValue else { return }
                    DispatchQueue.main.async {
                        selectedDirectory = url
                    }
                }
                return true
            }
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
        sessionRowContent(
            id: session.id, icon: "text.bubble",
            title: session.title, projectName: session.projectName,
            timestamp: session.timestamp
        ) { launchSession(session) }
    }

    private func codexSessionRow(_ session: CodexSessionEntry) -> some View {
        sessionRowContent(
            id: session.id, icon: "terminal",
            title: session.title, projectName: session.projectName,
            timestamp: session.timestamp
        ) { launchCodexSession(session) }
    }

    private func sessionRowContent(
        id: String, icon: String, title: String, projectName: String,
        timestamp: Date, action: @escaping () -> Void
    ) -> some View {
        let isHovered = hoveredSessionId == id
        return Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .foregroundStyle(.secondary)
                    .font(.callout)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        Text(projectName)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text("\u{00B7}")
                            .font(.caption2)
                            .foregroundStyle(.quaternary)
                        Text(Self.sessionDateFormatter.string(from: timestamp))
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
            hoveredSessionId = hovered ? id : nil
        }
    }

    // MARK: - Remote Section

    private var remoteSection: some View {
        VStack(spacing: 20) {
            // Host picker
            VStack(alignment: .leading, spacing: 8) {
                Text("Remote Host")
                    .font(.headline)

                HStack(spacing: 10) {
                    Picker("", selection: $selectedRemoteHostId) {
                        Text("Select a host...").tag(nil as UUID?)
                        ForEach(remoteHostStore.hosts) { host in
                            Text(host.displayName).tag(host.id as UUID?)
                        }
                    }
                    .labelsHidden()

                    Button("Manage Hosts...") {
                        SettingsWindow.shared.show(tab: .remoteHosts)
                    }
                    .controlSize(.small)
                }
            }

            // Claude options (always visible so history launches use them too)
            claudeCodeOptions

            if selectedRemoteHostId != nil {
                // Remote directory input
                VStack(alignment: .leading, spacing: 8) {
                    Text("Working Directory")
                        .font(.headline)
                    HStack(spacing: 10) {
                        Image(systemName: "folder.fill")
                            .font(.title3)
                            .foregroundStyle(remoteDirectory.isEmpty ? .secondary : Color.accentColor)
                        TextField("Remote path (e.g. ~/projects/myapp)", text: $remoteDirectory)
                            .textFieldStyle(.plain)
                            .onSubmit { }
                        Button("Browse...") {
                            showRemoteBrowser = true
                        }
                    }
                    .padding(12)
                    .background(.regularMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .sheet(isPresented: $showRemoteBrowser) {
                    if let hostId = selectedRemoteHostId,
                       let host = remoteHostStore.hosts.first(where: { $0.id == hostId }) {
                        RemoteDirectoryBrowser(remoteHost: host) { path in
                            remoteDirectory = path
                        }
                    }
                }

                // Start new remote session button
                Button {
                    launchRemoteNewSession()
                } label: {
                    Label("Start Remote Session", systemImage: "play.fill")
                        .frame(width: 200)
                }
                .controlSize(.large)
                .keyboardShortcut(.return, modifiers: [])
                .disabled(selectedRemoteHostId == nil || remoteDirectory.isEmpty || isLaunching)
            }

            // Remote history (always visible when in remote mode)
            remoteHistorySection

            // Remote tmux sessions
            if selectedRemoteHostId != nil {
                remoteSessionsSection
            }
        }
    }

    // MARK: - Remote History

    private var filteredRemoteHistory: [RemoteHistoryEntry] {
        let entries: [RemoteHistoryEntry]
        if let hostId = selectedRemoteHostId {
            entries = remoteHistory.filter { $0.hostId == hostId }
        } else {
            entries = remoteHistory
        }
        guard !searchText.isEmpty else { return entries }
        let query = searchText.lowercased()
        return entries.filter { entry in
            let host = remoteHostStore.hosts.first { $0.id == entry.hostId }
            return entry.directory.lowercased().contains(query)
                || (host?.label.lowercased().contains(query) ?? false)
                || (host?.host.lowercased().contains(query) ?? false)
        }
    }

    private var remoteHistorySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Recent")
                .font(.headline)

            if !remoteHistory.isEmpty {
                searchField
            }

            ScrollView {
                VStack(spacing: 0) {
                    if filteredRemoteHistory.isEmpty {
                        Text("No recent remote sessions")
                            .foregroundStyle(.tertiary)
                            .padding()
                    }
                    ForEach(Array(filteredRemoteHistory.enumerated()), id: \.element.id) { index, entry in
                        remoteHistoryRow(entry)
                        if index < filteredRemoteHistory.count - 1 {
                            Divider().padding(.leading, 34)
                        }
                    }
                }
            }
            .frame(height: Self.rowHeight * CGFloat(min(Self.listRowCount, max(3, filteredRemoteHistory.count))))
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    private func remoteHistoryRow(_ entry: RemoteHistoryEntry) -> some View {
        let isHovered = hoveredRemoteHistoryId == entry.id
        let host = remoteHostStore.hosts.first { $0.id == entry.hostId }
        return Button {
            if let host {
                selectedRemoteHostId = host.id
                remoteDirectory = entry.directory
                launchRemoteNewSession()
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "network")
                    .foregroundStyle(.secondary)
                    .font(.callout)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.directory)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                    if let host {
                        Text(host.displayName)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                if isHovered {
                    Button {
                        removeRemoteHistory(entry)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                } else {
                    Text(Self.relativeDate(entry.lastUsed))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isHovered ? Color.primary.opacity(0.04) : Color.clear)
        }
        .buttonStyle(.plain)
        .onHover { hovered in
            hoveredRemoteHistoryId = hovered ? entry.id : nil
        }
    }

    private static let relativeDateFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    private static func relativeDate(_ date: Date) -> String {
        relativeDateFormatter.localizedString(for: date, relativeTo: Date())
    }

    // MARK: - Remote Sessions

    private var remoteSessionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Active tmux Sessions")
                    .font(.headline)
                Spacer()
                if isLoadingRemoteSessions {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Button {
                        loadRemoteSessions()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.plain)
                }
            }

            if let error = remoteConnectionError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            ScrollView {
                VStack(spacing: 0) {
                    if remoteSessions.isEmpty && !isLoadingRemoteSessions {
                        Text("No active tmux sessions")
                            .foregroundStyle(.tertiary)
                            .padding()
                    }
                    ForEach(Array(remoteSessions.enumerated()), id: \.element.name) { index, session in
                        remoteSessionRow(session)
                        if index < remoteSessions.count - 1 {
                            Divider().padding(.leading, 34)
                        }
                    }
                }
            }
            .frame(height: Self.rowHeight * CGFloat(min(Self.listRowCount, max(3, remoteSessions.count))))
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    private func remoteSessionRow(_ session: (name: String, windows: Int, created: String)) -> some View {
        Button {
            attachToRemoteSession(session.name)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "terminal")
                    .foregroundStyle(.secondary)
                    .font(.callout)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.name)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        Text("\(session.windows) window\(session.windows == 1 ? "" : "s")")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        if !session.created.isEmpty {
                            Text("\u{00B7}")
                                .font(.caption2)
                                .foregroundStyle(.quaternary)
                            Text(session.created)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "arrow.right.circle")
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Remote Actions

    private func loadRemoteSessions() {
        guard let hostId = selectedRemoteHostId,
              let host = remoteHostStore.hosts.first(where: { $0.id == hostId }) else { return }
        isLoadingRemoteSessions = true
        remoteConnectionError = nil
        Task {
            let sessions = await TmuxManager.shared.listAllSessions(remoteHost: host)
            remoteSessions = sessions
            isLoadingRemoteSessions = false
            if sessions.isEmpty {
                // Check if SSH connection even works
                let connected = await TmuxManager.shared.testSSHConnection(remoteHost: host)
                if !connected {
                    remoteConnectionError = "Failed to connect to \(host.host)"
                }
            }
        }
    }

    private func attachToRemoteSession(_ sessionName: String) {
        guard let hostId = selectedRemoteHostId,
              let host = remoteHostStore.hosts.first(where: { $0.id == hostId }),
              !isLaunching else { return }
        isLaunching = true
        onLaunch?(URL(fileURLWithPath: "/"), .remoteAttach(host, sessionName: sessionName))
    }

    private func launchRemoteNewSession() {
        guard let hostId = selectedRemoteHostId,
              let host = remoteHostStore.hosts.first(where: { $0.id == hostId }),
              !isLaunching else { return }
        isLaunching = true

        let opts = makeClaudeCodeOptions()

        RemoteHistory.add(hostId: host.id, directory: remoteDirectory)
        remoteHistory = RemoteHistory.load()

        onLaunch?(URL(fileURLWithPath: remoteDirectory), .remoteNewSession(host, directory: remoteDirectory, opts))
    }

    private func removeRemoteHistory(_ entry: RemoteHistoryEntry) {
        RemoteHistory.remove(entry)
        withAnimation {
            remoteHistory.removeAll { $0.id == entry.id }
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
        var opts = makeClaudeCodeOptions(continueSession: false)
        opts.resumeSessionId = session.id
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

    private func makeClaudeCodeOptions(continueSession: Bool? = nil) -> ClaudeCodeOptions {
        var opts = ClaudeCodeOptions()
        opts.model = model.isEmpty ? nil : model
        opts.permissionMode = permissionMode.isEmpty ? nil : permissionMode
        opts.effortLevel = effortLevel.isEmpty ? nil : effortLevel
        opts.dangerouslySkipPermissions = skipPermissions
        opts.continueSession = continueSession ?? self.continueSession
        opts.verbose = verbose
        return opts
    }

    private func makeLaunchConfig() -> LaunchConfig {
        switch cliType {
        case .claudeCode:
            return .claudeCode(makeClaudeCodeOptions())
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
