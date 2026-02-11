import AppKit
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

    private var ghosttyView: GhosttyTerminalView!

    nonisolated(unsafe) private var keyEventMonitor: Any?

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

        view.layer?.backgroundColor = NSColor.white.cgColor

        ghosttyView = GhosttyTerminalView(frame: view.bounds)
        ghosttyView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(ghosttyView)

        NSLayoutConstraint.activate([
            ghosttyView.topAnchor.constraint(equalTo: view.topAnchor),
            ghosttyView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            ghosttyView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            ghosttyView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        installKeyEventMonitor()
    }

    deinit {
        if let keyEventMonitor {
            NSEvent.removeMonitor(keyEventMonitor)
        }
    }

    func teardown() {
        ghosttyView.teardown()
    }

    // MARK: - Key Event Monitor (Cmd+V → image paste)

    private func installKeyEventMonitor() {
        keyEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let keyCode = event.keyCode
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

            // Cmd+V: Image paste (intercept before ghostty's text-only paste)
            guard keyCode == 9 /* V */, flags == .command else { return event }
            guard let eventWindow = event.window else { return event }
            let windowID = ObjectIdentifier(eventWindow)

            let handled = MainActor.assumeIsolated { () -> Bool in
                guard let self,
                      let myWindow = self.view.window,
                      ObjectIdentifier(myWindow) == windowID else { return false }
                return self.handleImagePaste()
            }
            return handled ? nil : event
        }
    }

    /// If the pasteboard contains an image, sends its file path to the terminal.
    /// Returns `true` if an image was handled, `false` to fall through to normal paste.
    private func handleImagePaste() -> Bool {
        guard let path = ImagePasteHelper.imagePathFromPasteboard() else {
            return false
        }
        ghosttyView.feedText(path)
        return true
    }

    /// Gives keyboard focus to the ghostty terminal view.
    func focusTerminal() {
        view.window?.makeFirstResponder(ghosttyView)
    }

    // MARK: - Process

    func startTmuxAttach() {
        let tmuxPath: String
        do {
            tmuxPath = try ClaudeCLI.tmuxPath()
        } catch {
            logger.error("Failed to resolve tmux path: \(error.localizedDescription)")
            feedError("tmux not found: \(error.localizedDescription)")
            return
        }

        let command = "\(tmuxPath) attach-session -t =\(session.tmuxSessionName)"

        var envVars: [(String, String)] = []
        let env = EnvironmentBuilder.loginEnvironment()
        for entry in env {
            if let eqIdx = entry.firstIndex(of: "=") {
                let key = String(entry[entry.startIndex..<eqIdx])
                let value = String(entry[entry.index(after: eqIdx)...])
                if key == "TERM" {
                    envVars.append(("TERM", "xterm-256color"))
                } else {
                    envVars.append((key, value))
                }
            }
        }
        // Ensure TERM is set
        if !envVars.contains(where: { $0.0 == "TERM" }) {
            envVars.append(("TERM", "xterm-256color"))
        }

        ghosttyView.onTitleChange = { [weak self] title in
            guard let self else { return }
            self.delegate?.terminalDidUpdateTitle(self, title: title)
        }

        ghosttyView.onProcessExit = { [weak self] in
            guard let self else { return }
            self.delegate?.terminalProcessDidTerminate(self, exitCode: nil)
        }

        // Working directory is managed by tmux (set via new-session -c),
        // so ghostty only needs a safe CWD for the tmux attach process itself.
        // Using /tmp avoids triggering macOS TCC prompts for ~/Documents.
        let success = ghosttyView.createSurface(
            command: command,
            workingDirectory: NSTemporaryDirectory(),
            envVars: envVars
        )

        guard success else {
            feedError("Failed to create terminal surface")
            return
        }

        logger.info("Attached to tmux session: \(self.session.tmuxSessionName)")
    }

    /// Feeds a visible error message into the terminal view.
    func feedError(_ message: String) {
        ghosttyView.feedText("\r\n\u{1b}[1;31m[Error]\u{1b}[0m \(message)\r\n")
    }

    /// Feeds a visible info message into the terminal view.
    func feedInfo(_ message: String) {
        ghosttyView.feedText("\r\n\u{1b}[2m\(message)\u{1b}[0m\r\n")
    }
}
