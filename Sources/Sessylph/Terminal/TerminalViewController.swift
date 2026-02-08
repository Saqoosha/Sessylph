import AppKit
import SwiftTerm
import os.log

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Sessylph", category: "Terminal")

private let terminalPadding: CGFloat = 4

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
        let container = NSView()
        container.wantsLayer = true
        view = container
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        // Appearance
        let fontSize = CGFloat(UserDefaults.standard.double(forKey: Defaults.terminalFontSize))
        let fontName = UserDefaults.standard.string(forKey: Defaults.terminalFontName) ?? "SF Mono"
        let bgColor: NSColor = .white

        // Container background matches terminal
        view.layer?.backgroundColor = bgColor.cgColor

        // Create terminal view with padding via Auto Layout
        terminalView = LocalProcessTerminalView(frame: .zero)
        terminalView.translatesAutoresizingMaskIntoConstraints = false
        let processDelegate = TerminalProcessDelegate(owner: self)
        self.processDelegate = processDelegate
        terminalView.processDelegate = processDelegate
        view.addSubview(terminalView)

        NSLayoutConstraint.activate([
            terminalView.topAnchor.constraint(equalTo: view.topAnchor, constant: terminalPadding),
            terminalView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: terminalPadding),
            terminalView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -terminalPadding),
            terminalView.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -terminalPadding),
        ])

        terminalView.font = NSFont(name: fontName, size: fontSize)
            ?? NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        terminalView.nativeBackgroundColor = bgColor
        terminalView.nativeForegroundColor = .black

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
            feedError("tmux not found: \(error.localizedDescription)")
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

    /// Feeds a visible error message into the terminal view.
    func feedError(_ message: String) {
        terminalView?.feed(text: "\r\n\u{1b}[1;31m[Error]\u{1b}[0m \(message)\r\n")
    }

    /// Feeds a visible info message into the terminal view.
    func feedInfo(_ message: String) {
        terminalView?.feed(text: "\r\n\u{1b}[2m\(message)\u{1b}[0m\r\n")
    }
}

// MARK: - Delegate Bridge (nonisolated for SwiftTerm callback thread safety)

/// Bridges SwiftTerm's nonisolated delegate callbacks to the @MainActor TerminalViewController.
private final class TerminalProcessDelegate: NSObject, LocalProcessTerminalViewDelegate, @unchecked Sendable {
    weak var owner: TerminalViewController?

    init(owner: TerminalViewController) {
        self.owner = owner
    }

    func sizeChanged(source _: LocalProcessTerminalView, newCols _: Int, newRows _: Int) {
        // tmux handles resize via the pty; nothing extra needed here.
    }

    func setTerminalTitle(source _: LocalProcessTerminalView, title: String) {
        Task { @MainActor [weak owner] in
            guard let owner else { return }
            owner.delegate?.terminalDidUpdateTitle(owner, title: title)
        }
    }

    func processTerminated(source _: TerminalView, exitCode: Int32?) {
        logger.info("Terminal process terminated (exit=\(exitCode.map { String($0) } ?? "nil"))")
        Task { @MainActor [weak owner] in
            guard let owner else { return }
            owner.delegate?.terminalProcessDidTerminate(owner, exitCode: exitCode)
        }
    }

    func hostCurrentDirectoryUpdate(source _: TerminalView, directory: String?) {
        if let directory {
            logger.debug("Host directory changed: \(directory)")
        }
    }
}
