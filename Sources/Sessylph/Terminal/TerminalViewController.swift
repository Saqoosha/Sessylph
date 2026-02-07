import AppKit
import SwiftTerm
import os.log

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Sessylph", category: "Terminal")

// MARK: - Delegate Protocol

@MainActor
protocol TerminalViewControllerDelegate: AnyObject {
    func terminalDidUpdateTitle(_ vc: TerminalViewController, title: String)
    func terminalProcessDidTerminate(_ vc: TerminalViewController, exitCode: Int32?)
}

// MARK: - TerminalViewController

final class TerminalViewController: NSViewController {
    let session: Session
    weak var delegate: TerminalViewControllerDelegate?
    private var terminalView: LocalProcessTerminalView!
    private var processDelegate: TerminalProcessDelegate?

    init(session: Session) {
        self.session = session
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError() }

    // MARK: - Lifecycle

    override func loadView() {
        view = NSView()
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        // Create terminal view
        terminalView = LocalProcessTerminalView(frame: view.bounds)
        terminalView.autoresizingMask = [.width, .height]
        let processDelegate = TerminalProcessDelegate(owner: self)
        self.processDelegate = processDelegate
        terminalView.processDelegate = processDelegate
        view.addSubview(terminalView)

        // Appearance
        terminalView.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        terminalView.nativeBackgroundColor = NSColor(red: 0.1, green: 0.1, blue: 0.12, alpha: 1.0)
        terminalView.nativeForegroundColor = NSColor(red: 0.9, green: 0.9, blue: 0.9, alpha: 1.0)

        // TODO: Detect bell sequences (\a) for notification fallback
        //       when the active session is not visible.

        // Start tmux attach
        startTmuxAttach()
    }

    // MARK: - Process

    private func startTmuxAttach() {
        let tmuxPath: String
        do {
            tmuxPath = try ClaudeCLI.tmuxPath()
        } catch {
            logger.error("Failed to resolve tmux path: \(error.localizedDescription)")
            return
        }

        let environment = EnvironmentBuilder.loginEnvironment()
        let args = ["attach-session", "-t", session.tmuxSessionName]

        terminalView.startProcess(
            executable: tmuxPath,
            args: args,
            environment: environment,
            execName: "tmux"
        )

        logger.info("Attached to tmux session: \(self.session.tmuxSessionName)")
    }
}

// MARK: - Delegate Bridge (nonisolated for SwiftTerm callback thread safety)

/// Bridges SwiftTerm's nonisolated delegate callbacks to the @MainActor TerminalViewController.
private final class TerminalProcessDelegate: NSObject, LocalProcessTerminalViewDelegate, @unchecked Sendable {
    unowned let owner: TerminalViewController

    init(owner: TerminalViewController) {
        self.owner = owner
    }

    func sizeChanged(source _: LocalProcessTerminalView, newCols _: Int, newRows _: Int) {
        // tmux handles resize via the pty; nothing extra needed here.
    }

    func setTerminalTitle(source _: LocalProcessTerminalView, title: String) {
        Task { @MainActor [owner] in
            owner.delegate?.terminalDidUpdateTitle(owner, title: title)
        }
    }

    func processTerminated(source _: TerminalView, exitCode: Int32?) {
        logger.info("Terminal process terminated (exit=\(exitCode.map { String($0) } ?? "nil"))")
        Task { @MainActor [owner] in
            owner.delegate?.terminalProcessDidTerminate(owner, exitCode: exitCode)
        }
    }

    func hostCurrentDirectoryUpdate(source _: TerminalView, directory: String?) {
        if let directory {
            logger.debug("Host directory changed: \(directory)")
        }
    }
}
