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
    private var lastTaskDescription: String = ""
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

    init(session: Session) {
        self.session = session

        let window = Self.makeWindow(title: session.title)

        super.init(window: window)
        window.delegate = self
        restoreWindowFrame()

        showTerminal()
        startTitlePolling()
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

        do {
            try await TmuxManager.shared.createSession(
                name: session.tmuxSessionName,
                directory: directory
            )

            // Configure tmux for title passthrough (best-effort)
            await TmuxManager.shared.configureSession(name: session.tmuxSessionName)

            let claudePath = try ClaudeCLI.claudePath()

            var hookSettingsPath: String? = nil
            if let notifierPath = HookSettingsGenerator.notifierPath() {
                let hooksURL = try HookSettingsGenerator.generate(
                    sessionId: session.id.uuidString,
                    notifierPath: notifierPath
                )
                hookSettingsPath = hooksURL.path
            }

            let command = session.options.buildCommand(
                claudePath: claudePath,
                hookSettingsPath: hookSettingsPath
            )

            try await TmuxManager.shared.launchClaude(
                sessionName: session.tmuxSessionName,
                command: command
            )

            session.isRunning = true
            SessionStore.shared.add(session)
        } catch {
            // Clean up the tmux session if it was already created
            try? await TmuxManager.shared.killSession(name: session.tmuxSessionName)

            logger.error("Failed to launch Claude: \(error.localizedDescription)")
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
        }
        lastTaskDescription = taskDesc
        applyTitles(emoji: needsAttention ? "⚠️" : state.emoji)
    }

    /// Called by AppDelegate when a hook "notification" event is received.
    func markNeedsAttention() {
        needsAttention = true
        applyTitles(emoji: "⚠️")
    }

    // MARK: - Title Polling

    private func startTitlePolling() {
        // Immediate first poll
        Task { await pollPaneTitle() }
        // Then poll every 2 seconds
        titlePollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
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

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if TabManager.shared.isTerminating { return true }
        if !session.isRunning { return true }
        if UserDefaults.standard.bool(forKey: Defaults.suppressCloseTabAlert) { return true }

        Task {
            let alert = NSAlert()
            alert.messageText = "Close Tab?"
            alert.informativeText = "The Claude Code session in \"\(session.title)\" will be terminated."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Close Tab")
            alert.addButton(withTitle: "Cancel")
            alert.showsSuppressionButton = true

            let response: NSApplication.ModalResponse
            if let window {
                response = await alert.beginSheetModal(for: window)
            } else {
                response = alert.runModal()
            }

            if alert.suppressionButton?.state == .on {
                UserDefaults.standard.set(true, forKey: Defaults.suppressCloseTabAlert)
            }

            if response == .alertFirstButtonReturn {
                self.window?.close()
            }
        }
        return false
    }

    func windowDidBecomeKey(_ notification: Notification) {
        if TabManager.shared.needsPtyRefresh {
            TabManager.shared.needsPtyRefresh = false
            guard session.isRunning, let terminalVC else { return }
            terminalVC.refreshPtySize()
        }
    }

    func windowWillClose(_ notification: Notification) {
        stopTitlePolling()

        if session.isRunning && !TabManager.shared.isTerminating {
            let sessionName = session.tmuxSessionName
            session.isRunning = false
            Task {
                try? await TmuxManager.shared.killSession(name: sessionName)
            }
        }

        TabManager.shared.windowControllerDidClose(self)
    }
}
