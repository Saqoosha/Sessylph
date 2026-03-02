import AppKit
import SwiftUI
import os.log

private let logger = Logger(subsystem: "sh.saqoo.Sessylph", category: "TabWindowController")

@MainActor
final class TabWindowController: NSWindowController, NSWindowDelegate, TerminalViewControllerDelegate,
    ClaudeStateTrackerDelegate
{

    // MARK: - Properties

    var session: Session
    var needsAttention: Bool {
        get { stateTracker.needsAttention }
        set { stateTracker.needsAttention = newValue }
    }
    private var terminalVC: TerminalViewController?
    var lastTaskDescription: String { stateTracker.lastTaskDescription }
    /// The last task description observed while Claude was actively working.
    /// Retained across idle transitions so notifications can reference the completed task.
    var lastWorkingTaskDescription: String { stateTracker.lastWorkingTaskDescription }
    private lazy var stateTracker: ClaudeStateTracker = ClaudeStateTracker(
        sessionName: session.tmuxSessionName,
        isRunning: { [weak self] in self?.session.isRunning ?? false }
    )
    private static let claudeOrange = NSColor(srgbRed: 0xD9/255.0, green: 0x78/255.0, blue: 0x58/255.0, alpha: 1.0)

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

        stateTracker.delegate = self
        showTerminal()
        stateTracker.startTitlePolling()
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
        window.titlebarSeparatorStyle = .none
        window.titlebarAppearsTransparent = true

        window.isRestorable = false
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
        applyTitles(icon: "⏳")

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

        stateTracker.delegate = self
        stateTracker.updateSessionName(session.tmuxSessionName)
        applyTitles(icon: ClaudeState.idle.icon)
        showTerminal()
        attachToTmux()
        stateTracker.startTitlePolling()

        // Explicitly focus the terminal — windowDidBecomeKey already fired
        // before the session was running, so it skipped focusTerminal().
        terminalVC?.focusTerminal()

        logger.info("Launched Claude in \(directory.path)")
    }

    // MARK: - TerminalViewControllerDelegate

    func terminalDidUpdateTitle(_ vc: TerminalViewController, title: String) {
        stateTracker.updateTitle(from: title)
    }

    /// Called by AppDelegate when a hook "notification" event is received.
    func markNeedsAttention() {
        stateTracker.markNeedsAttention()
    }

    // MARK: - ClaudeStateTrackerDelegate

    func stateTracker(_ tracker: ClaudeStateTracker, didUpdateState state: ClaudeState, icon: String) {
        applyTitles(icon: icon)
    }

    func stateTracker(_ tracker: ClaudeStateTracker, wantsRename newName: String) {
        renameTmuxSession(task: newName)
    }

    private func renameTmuxSession(task: String) {
        let newName = TmuxManager.sessionName(for: session.id, directory: session.directory, task: task)
        guard newName != session.tmuxSessionName else { return }

        let oldName = session.tmuxSessionName
        session.tmuxSessionName = newName
        stateTracker.updateSessionName(newName)
        SessionStore.shared.update(session)

        Task { [weak self] in
            let success = await TmuxManager.shared.renameSession(from: oldName, to: newName)
            if !success {
                self?.session.tmuxSessionName = oldName
                self?.stateTracker.updateSessionName(oldName)
                if let session = self?.session { SessionStore.shared.update(session) }
            }
        }
    }

    private func applyTitles(icon: String) {
        let dirName = session.title
        let rest = lastTaskDescription.isEmpty ? dirName : "\(dirName) — \(lastTaskDescription)"

        let monoFont = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .bold)
        let attributed = NSMutableAttributedString()
        var iconAttrs: [NSAttributedString.Key: Any] = [.font: monoFont]
        if stateTracker.isSpinning {
            iconAttrs[.foregroundColor] = Self.claudeOrange
        }
        attributed.append(NSAttributedString(string: "\(icon) ", attributes: iconAttrs))
        attributed.append(NSAttributedString(string: rest))
        window?.tab.attributedTitle = attributed

        if window?.title != rest {
            window?.title = rest
        }
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
        guard session.isRunning, let terminalVC else { return }
        terminalVC.focusTerminal()
    }

    func windowWillClose(_ notification: Notification) {
        stateTracker.stopSpinner()
        stateTracker.stopTitlePolling()
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
