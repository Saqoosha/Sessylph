import AppKit
import SwiftUI
import os.log

private let logger = Logger(subsystem: "sh.saqoo.Sessylph", category: "TabWindowController")

@MainActor
final class TabWindowController: NSWindowController, NSWindowDelegate, TerminalViewControllerDelegate {

    // MARK: - Properties

    var session: Session
    var needsAttention: Bool = false
    private var terminalVC: TerminalViewController?
    private(set) var lastTaskDescription: String = ""
    private var titlePollTimer: Timer?
    private var lastPolledTitle: String?

    private static let defaultSize = NSSize(width: 900, height: 600)

    // MARK: - Initialization (empty launcher tab)

    init() {
        self.session = Session(directory: URL(fileURLWithPath: NSHomeDirectory()))

        let window = Self.makeWindow(title: "New Tab")

        super.init(window: window)
        window.delegate = self
        restoreWindowFrame()

        showLauncher()
    }

    // MARK: - Initialization (attach to existing tmux session)

    /// Creates a controller for an existing tmux session.
    /// The terminal view is created but tmux is NOT attached yet —
    /// call `attachToTmux()` after the window is positioned in the tab group
    /// so the pty size matches the final window size.
    init(session: Session) {
        self.session = session

        let window = Self.makeWindow(title: session.title)

        super.init(window: window)
        window.delegate = self
        restoreWindowFrame()

        showTerminal()
        startTitlePolling()
    }

    /// Starts the tmux attach-session process.
    /// Call after the window has been added to the tab group and laid out.
    func attachToTmux() {
        terminalVC?.startTmuxAttach()
    }

    private func restoreWindowFrame() {
        self.windowFrameAutosaveName = Self.frameAutosaveName
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    // MARK: - Window Factory

    private static let frameAutosaveName = "SessylphTerminalWindow"

    private static func makeWindow(title: String) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: defaultSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: true
        )
        window.title = title
        window.tabbingMode = .preferred
        window.tabbingIdentifier = "sh.saqoo.Sessylph.terminal"
        window.minSize = NSSize(width: 480, height: 320)

        window.setContentSize(defaultSize)
        window.center()

        return window
    }

    // MARK: - Content Switching

    private func showLauncher() {
        guard let window else {
            logger.error("Window is nil in showLauncher")
            return
        }
        let savedFrame = window.frame

        var launcherView = LauncherView()
        launcherView.onLaunch = { [weak self] directory, options in
            guard let self else { return }
            Task {
                await self.launchClaude(directory: directory, options: options)
            }
        }
        let hostingController = NSHostingController(
            rootView: launcherView.frame(maxWidth: .infinity, maxHeight: .infinity)
        )
        // Prevent NSHostingController from auto-resizing the window to fit SwiftUI content
        hostingController.sizingOptions = []
        window.contentViewController = hostingController

        // Reset content size constraints so NSHostingController doesn't lock the window
        window.contentMinSize = NSSize(width: 480, height: 320)
        window.contentMaxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)

        // Restore frame after content swap to prevent window from shrinking
        window.setFrame(savedFrame, display: false)
    }

    private func showTerminal() {
        guard let window else {
            logger.error("Window is nil in showTerminal")
            return
        }
        let savedFrame = window.frame

        let vc = TerminalViewController(session: session)
        vc.delegate = self
        self.terminalVC = vc
        window.contentViewController = vc

        // Reset content size constraints so the window is freely resizable
        window.contentMinSize = NSSize(width: 480, height: 320)
        window.contentMaxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)

        // Restore frame after content swap to prevent window from jumping
        window.setFrame(savedFrame, display: false)
    }

    // MARK: - Launch Claude

    func launchClaude(directory: URL, options: ClaudeCodeOptions) async {
        session = Session(directory: directory, options: options)

        // Update tab title immediately so the user sees feedback before tmux finishes
        applyTitles(emoji: "⏳")

        do {
            // Resolve paths and generate hooks before the tmux call (sync, fast)
            let claudePath = try ClaudeCLI.claudePath()

            var hookSettingsPath: String? = nil
            if let notifierPath = HookSettingsGenerator.notifierPath() {
                let hooksURL = try HookSettingsGenerator.generate(
                    sessionId: session.id.uuidString,
                    notifierPath: notifierPath
                )
                hookSettingsPath = hooksURL.path
            } else {
                logger.warning("sessylph-notifier not found in bundle — notifications will be disabled")
            }

            let command = session.options.buildCommand(
                claudePath: claudePath,
                hookSettingsPath: hookSettingsPath
            )

            // Single tmux invocation: create session + configure + launch
            try await TmuxManager.shared.createAndLaunchSession(
                name: session.tmuxSessionName,
                directory: directory,
                command: command
            )

            session.isRunning = true
            SessionStore.shared.add(session)
        } catch {
            // Clean up the tmux session if it was already created
            do {
                try await TmuxManager.shared.killSession(name: session.tmuxSessionName)
            } catch {
                logger.warning("Failed to clean up tmux session: \(error.localizedDescription)")
            }

            logger.error("Failed to launch Claude: \(error.localizedDescription)")

            // Reset launcher UI before showing the error alert
            showLauncher()

            let alert = NSAlert()
            alert.messageText = "Failed to Launch"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            if let window {
                await alert.beginSheetModal(for: window)
            }
            return
        }

        applyTitles(emoji: ClaudeState.idle.emoji)
        showTerminal()
        attachToTmux()
        startTitlePolling()

        logger.info("Launched Claude in \(directory.path)")
    }

    // MARK: - TerminalViewControllerDelegate

    func terminalDidUpdateTitle(_ vc: TerminalViewController, title: String) {
        lastPolledTitle = title // sync with polling to avoid duplicate processing
        updateTitle(from: title)
    }

    private func updateTitle(from rawTitle: String) {
        let (state, taskDesc) = Self.parseClaudeTitle(rawTitle)
        if state == .working {
            needsAttention = false
            // Only rename tmux session for actual working tasks (keep last task when idle)
            if taskDesc != lastTaskDescription {
                renameTmuxSession(task: taskDesc)
            }
        }
        lastTaskDescription = taskDesc
        applyTitles(emoji: needsAttention ? "❓" : state.emoji)
    }

    private func renameTmuxSession(task: String) {
        let newName = TmuxManager.sessionName(for: session.id, directory: session.directory, task: task)
        guard newName != session.tmuxSessionName else { return }

        let oldName = session.tmuxSessionName
        session.tmuxSessionName = newName
        SessionStore.shared.update(session)

        Task { [weak self] in
            let success = await TmuxManager.shared.renameSession(from: oldName, to: newName)
            if !success {
                self?.session.tmuxSessionName = oldName
                if let session = self?.session { SessionStore.shared.update(session) }
            }
        }
    }

    /// Called by AppDelegate when a hook "notification" event is received.
    func markNeedsAttention() {
        needsAttention = true
        applyTitles(emoji: "❓")
    }

    // MARK: - Title Polling

    private func startTitlePolling() {
        Task { await pollPaneTitle() }
        titlePollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.pollPaneTitle()
            }
        }
    }

    private func stopTitlePolling() {
        titlePollTimer?.invalidate()
        titlePollTimer = nil
    }

    private func pollPaneTitle() async {
        guard session.isRunning else { return }
        guard let title = await TmuxManager.shared.getPaneTitle(sessionName: session.tmuxSessionName) else { return }
        guard title != lastPolledTitle else { return }
        lastPolledTitle = title
        updateTitle(from: title)
    }

    private func applyTitles(emoji: String) {
        let dirName = session.title
        let title = lastTaskDescription.isEmpty
            ? "\(emoji) \(dirName)"
            : "\(emoji) \(dirName) — \(lastTaskDescription)"

        if window?.tab.title != title {
            window?.tab.title = title
        }
        if window?.title != title {
            window?.title = title
        }
    }

    // MARK: - Claude Code Title Parsing

    enum ClaudeState {
        case idle
        case working
        case unknown

        var emoji: String {
            switch self {
            case .idle: "✅"
            case .working: "🔄"
            case .unknown: "💻"
            }
        }
    }

    /// Parses Claude Code's terminal title and maps prefixes to state.
    ///
    /// Known formats:
    /// - `✳ Claude Code` — idle/ready
    /// - `⠂ Task description` / `⠐ Task description` — working (braille spinner)
    private static func parseClaudeTitle(_ rawTitle: String) -> (state: ClaudeState, taskDescription: String) {
        guard let first = rawTitle.unicodeScalars.first else {
            return (.unknown, "")
        }

        // Braille spinner (U+2800–U+28FF) → working
        if first.value >= 0x2800, first.value <= 0x28FF {
            let rest = String(rawTitle.dropFirst()).trimmingCharacters(in: .whitespaces)
            return (.working, rest)
        }

        // ✳ (U+2733 Eight Spoked Asterisk) → idle/ready
        if first == Unicode.Scalar(0x2733) {
            let rest = String(rawTitle.dropFirst()).trimmingCharacters(in: .whitespaces)
            return (.idle, rest)
        }

        return (.unknown, rawTitle)
    }

    func terminalProcessDidTerminate(_ vc: TerminalViewController, exitCode: Int32?) {
        session.isRunning = false
        let exitStr = exitCode.map { String($0) } ?? "nil"
        logger.info("Process terminated in session \(self.session.tmuxSessionName) (exit=\(exitStr))")

        // Close the tab/window when the shell process exits
        window?.close()
    }

    // MARK: - NSWindowDelegate

    private var closeConfirmed = false

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if closeConfirmed { return true }
        if TabManager.shared.isTerminating { return true }
        if !session.isRunning { return true }
        if UserDefaults.standard.bool(forKey: Defaults.suppressCloseTabAlert) { return true }

        Task { [weak self] in
            guard let self else { return }
            let alert = NSAlert()
            alert.messageText = "Close Tab?"
            alert.informativeText = "The Claude Code session in \"\(self.session.title)\" will be terminated."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Close Tab")
            alert.addButton(withTitle: "Cancel")
            alert.showsSuppressionButton = true

            let response: NSApplication.ModalResponse
            if let window = self.window {
                response = await alert.beginSheetModal(for: window)
            } else {
                response = alert.runModal()
            }

            if alert.suppressionButton?.state == .on {
                UserDefaults.standard.set(true, forKey: Defaults.suppressCloseTabAlert)
            }

            if response == .alertFirstButtonReturn {
                self.closeConfirmed = true
                self.window?.close()
            }
        }
        return false
    }

    func windowDidBecomeKey(_ notification: Notification) {
        let needsCheck = TabManager.shared.needsPtyRefresh
        guard session.isRunning, let terminalVC else { return }
        // Only clear the flag after the guard — non-running tabs (e.g. launcher)
        // must not consume it so the next running tab still gets the check.
        TabManager.shared.needsPtyRefresh = false
        terminalVC.focusTerminal()

        if needsCheck {
            // App just became active — an external tmux client may have
            // changed the session's window size while we were in background.
            // Query tmux and only force-refresh if sizes actually differ.
            let sessionName = session.tmuxSessionName
            let expectedCols = terminalVC.terminalSize.cols
            let expectedRows = terminalVC.terminalSize.rows
            Task {
                guard let tmuxSize = await TmuxManager.shared.getWindowSize(sessionName: sessionName) else {
                    // Query failed — fall back to unconditional refresh
                    terminalVC.refreshPtySize(force: true)
                    return
                }
                if tmuxSize.cols != expectedCols || tmuxSize.rows != expectedRows {
                    terminalVC.refreshPtySize(force: true)
                }
            }
        }
    }

    func windowWillClose(_ notification: Notification) {
        stopTitlePolling()
        terminalVC?.teardown()

        if session.isRunning && !TabManager.shared.isTerminating {
            let sessionName = session.tmuxSessionName
            session.isRunning = false
            Task {
                do {
                    try await TmuxManager.shared.killSession(name: sessionName)
                } catch {
                    logger.warning("Failed to kill tmux session \(sessionName): \(error.localizedDescription)")
                }
            }
        }

        TabManager.shared.windowControllerDidClose(self)
    }
}
