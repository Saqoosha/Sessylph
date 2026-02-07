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
    private static let autosaveName: NSWindow.FrameAutosaveName = "SessylphMainWindow"

    // MARK: - Initialization (empty launcher tab)

    init() {
        self.session = Session(directory: URL(fileURLWithPath: NSHomeDirectory()))

        let window = Self.makeWindow(title: "New Tab")

        super.init(window: window)
        window.delegate = self

        showLauncher()
        restoreWindowFrame(window)
    }

    // MARK: - Initialization (attach to existing tmux session)

    init(session: Session) {
        self.session = session

        let window = Self.makeWindow(title: session.title)

        super.init(window: window)
        window.delegate = self

        showTerminal()
        restoreWindowFrame(window)
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
        // Do NOT setFrameAutosaveName here — NSHostingController will
        // override the frame when set as contentViewController.
        return window
    }

    /// Restores saved window frame after content view is set (which may have
    /// resized the window). Then enables auto-save for future changes.
    private func restoreWindowFrame(_ window: NSWindow) {
        let key = "NSWindow Frame \(Self.autosaveName)"
        if UserDefaults.standard.string(forKey: key) != nil {
            // Saved frame exists — restore it
            window.setFrameUsingName(Self.autosaveName)
        } else {
            // First launch — use default size
            window.setContentSize(Self.defaultSize)
            window.center()
        }
        // Enable auto-save so future resizes/moves are persisted
        window.setFrameAutosaveName(Self.autosaveName)
        logger.info("Window frame: \(window.frame.width)x\(window.frame.height)")
    }

    // MARK: - Content Switching

    private func showLauncher() {
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
        window?.contentViewController = hostingController
    }

    private func showTerminal() {
        let vc = TerminalViewController(session: session)
        vc.delegate = self
        self.terminalVC = vc
        window?.contentViewController = vc
    }

    // MARK: - Launch Claude

    func launchClaude(directory: URL, options: ClaudeCodeOptions) async {
        session = Session(directory: directory, options: options)

        do {
            try await TmuxManager.shared.createSession(
                name: session.tmuxSessionName,
                directory: directory
            )

            let claudePath = try ClaudeCLI.claudePath()
            let command = session.options.buildCommand(claudePath: claudePath)

            try await TmuxManager.shared.launchClaude(
                sessionName: session.tmuxSessionName,
                command: command
            )

            session.isRunning = true
        } catch {
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
        logger.info("Process terminated in session \(self.session.tmuxSessionName) (exit=\(exitCode.map { String($0) } ?? "nil"))")
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        TabManager.shared.windowControllerDidClose(self)
    }
}
