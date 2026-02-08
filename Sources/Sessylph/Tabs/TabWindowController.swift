import AppKit
import SwiftUI
import os.log

private let logger = Logger(subsystem: "sh.saqoo.Sessylph", category: "TabWindowController")

@MainActor
final class TabWindowController: NSWindowController, NSWindowDelegate, TerminalViewControllerDelegate {

    // MARK: - Properties

    var session: Session
    private var terminalVC: TerminalViewController?

    private static let defaultSize = NSSize(width: 900, height: 600)

    // MARK: - Initialization (empty launcher tab)

    init() {
        self.session = Session(directory: URL(fileURLWithPath: NSHomeDirectory()))

        let window = Self.makeWindow(title: "New Tab")

        super.init(window: window)
        window.delegate = self

        showLauncher()
    }

    // MARK: - Initialization (attach to existing tmux session)

    init(session: Session) {
        self.session = session

        let window = Self.makeWindow(title: session.title)

        super.init(window: window)
        window.delegate = self

        showTerminal()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    // MARK: - Window Factory

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
        window.contentViewController = hostingController
        // Reset content size constraints so NSHostingController doesn't lock the window
        window.contentMinSize = NSSize(width: 480, height: 320)
        window.contentMaxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
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
            let command = session.options.buildCommand(claudePath: claudePath)

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

        window?.title = session.title
        window?.tab.title = session.title
        showTerminal()

        logger.info("Launched Claude in \(directory.path)")
    }

    // MARK: - TerminalViewControllerDelegate

    func terminalDidUpdateTitle(_ vc: TerminalViewController, title: String) {
        session.title = title
        window?.title = title
        window?.tab.title = title
    }

    func terminalProcessDidTerminate(_ vc: TerminalViewController, exitCode: Int32?) {
        session.isRunning = false
        let exitStr = exitCode.map { String($0) } ?? "nil"
        logger.info("Process terminated in session \(self.session.tmuxSessionName) (exit=\(exitStr))")

        // Show termination message in terminal so user knows what happened
        vc.feedInfo("[Process exited with code \(exitStr)]")

        // Update tab title to indicate session ended
        let title = session.title + " (Exited)"
        window?.title = title
        window?.tab.title = title
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        TabManager.shared.windowControllerDidClose(self)
    }
}
