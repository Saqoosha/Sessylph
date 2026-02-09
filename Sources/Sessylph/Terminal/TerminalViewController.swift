import AppKit
import WebKit
import os.log

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Sessylph", category: "Terminal")

// MARK: - Delegate Protocol

@MainActor
protocol TerminalViewControllerDelegate: AnyObject {
    func terminalDidUpdateTitle(_ vc: TerminalViewController, title: String)
    func terminalProcessDidTerminate(_ vc: TerminalViewController, exitCode: Int32?)
}

// MARK: - TerminalViewController

final class TerminalViewController: NSViewController, TerminalBridgeDelegate, PTYProcessDelegate {
    let session: Session
    weak var delegate: TerminalViewControllerDelegate?

    private var bridge: TerminalBridge!
    private var ptyProcess: PTYProcess!
    private var webView: WKWebView!

    private var pendingTmuxAttach = false

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

        let bgColor = NSColor.white
        view.layer?.backgroundColor = bgColor.cgColor

        // Terminal bridge + WKWebView
        bridge = TerminalBridge()
        bridge.delegate = self
        webView = bridge.createWebView(frame: view.bounds)
        webView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(webView)

        // Full bleed — padding handled in CSS
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: view.topAnchor),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        // PTY process
        ptyProcess = PTYProcess()
        ptyProcess.delegate = self

        // Load xterm.js with user-configured font
        let fontSize = CGFloat(UserDefaults.standard.double(forKey: Defaults.terminalFontSize))
        let fontName = UserDefaults.standard.string(forKey: Defaults.terminalFontName) ?? "monospace"

        bridge.loadTerminal(config: TerminalConfig(
            fontFamily: fontName,
            fontSize: fontSize > 0 ? fontSize : 13,
            background: "#ffffff",
            foreground: "#000000"
        ))

        installKeyEventMonitor()
    }

    deinit {
        if let keyEventMonitor {
            NSEvent.removeMonitor(keyEventMonitor)
        }
    }

    // MARK: - Key Event Monitor (Shift+Enter → newline, Cmd+V → image paste)

    private func installKeyEventMonitor() {
        keyEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let keyCode = event.keyCode
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

            // --- Cmd+V: Image paste (intercept before WKWebView's text-only paste) ---
            if keyCode == 9 /* V */, flags == .command {
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

            // --- Shift+Enter: newline ---
            guard keyCode == 36 /* Return */ else { return event }
            guard flags.contains(.shift),
                  !flags.contains(.command),
                  !flags.contains(.control),
                  !flags.contains(.option) else {
                return event
            }
            guard let eventWindow = event.window else { return event }
            let windowID = ObjectIdentifier(eventWindow)

            let handled = MainActor.assumeIsolated { () -> Bool in
                guard let self,
                      let myWindow = self.view.window,
                      ObjectIdentifier(myWindow) == windowID else { return false }
                self.ptyProcess.send(data: Data([0x0a]))
                return true
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

        let bracketedPaste = bridge.bracketedPasteMode
        if bracketedPaste {
            // ESC [ 200 ~
            ptyProcess.send(data: Data([0x1b, 0x5b, 0x32, 0x30, 0x30, 0x7e]))
        }
        ptyProcess.send(data: Data(path.utf8))
        if bracketedPaste {
            // ESC [ 201 ~
            ptyProcess.send(data: Data([0x1b, 0x5b, 0x32, 0x30, 0x31, 0x7e]))
        }

        return true
    }

    // MARK: - Terminal Size

    /// Returns the current terminal grid dimensions.
    var terminalSize: (cols: Int, rows: Int) {
        (bridge.cols, bridge.rows)
    }

    /// Re-sends the current terminal size to the pty so tmux picks up
    /// this client's dimensions (e.g. after switching from another terminal).
    func refreshPtySize(force: Bool = false) {
        guard ptyProcess.running else { return }
        let fd = ptyProcess.childfd
        guard fd >= 0 else { return }

        if !force {
            var current = winsize()
            if ioctl(fd, TIOCGWINSZ, &current) == 0 {
                if current.ws_col == UInt16(bridge.cols), current.ws_row == UInt16(bridge.rows) {
                    return
                }
            }
        }

        // Bump size by 1 row to force SIGWINCH (macOS suppresses it when unchanged)
        var bumped = winsize(ws_row: UInt16(bridge.rows) + 1, ws_col: UInt16(bridge.cols), ws_xpixel: 0, ws_ypixel: 0)
        ptyProcess.setWindowSize(bumped)

        // Restore real size on the next run-loop cycle
        DispatchQueue.main.async { [weak self] in
            guard let self, self.ptyProcess.running else { return }
            var real = winsize(ws_row: UInt16(self.bridge.rows), ws_col: UInt16(self.bridge.cols), ws_xpixel: 0, ws_ypixel: 0)
            self.ptyProcess.setWindowSize(real)
        }

        // Scroll to bottom after tmux finishes redrawing
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.scrollToBottom()
        }
    }

    /// Scrolls the terminal view to the very bottom of the buffer.
    func scrollToBottom() {
        bridge.scrollToBottom()
    }

    /// Gives keyboard focus to the terminal web view.
    func focusTerminal() {
        webView.window?.makeFirstResponder(webView)
        bridge.focus()
    }

    // MARK: - Process

    func startTmuxAttach() {
        guard bridge.isReady else {
            pendingTmuxAttach = true
            return
        }
        performTmuxAttach()
    }

    private func performTmuxAttach() {
        let tmuxPath: String
        do {
            tmuxPath = try ClaudeCLI.tmuxPath()
        } catch {
            logger.error("Failed to resolve tmux path: \(error.localizedDescription)")
            feedError("tmux not found: \(error.localizedDescription)")
            return
        }

        if session.isRunning {
            // Reattach: preload scrollback history before starting PTY
            Task {
                await preloadScrollback()
                launchTmuxPty(tmuxPath: tmuxPath)
            }
        } else {
            launchTmuxPty(tmuxPath: tmuxPath)
        }
    }

    private func launchTmuxPty(tmuxPath: String) {
        var environment = EnvironmentBuilder.loginEnvironment()
        if let idx = environment.firstIndex(where: { $0.hasPrefix("TERM=") }) {
            environment[idx] = "TERM=xterm-256color"
        } else {
            environment.append("TERM=xterm-256color")
        }
        let args = ["attach-session", "-t", "=\(session.tmuxSessionName)"]

        let size = winsize(
            ws_row: UInt16(bridge.rows),
            ws_col: UInt16(bridge.cols),
            ws_xpixel: 0,
            ws_ypixel: 0
        )

        ptyProcess.startProcess(
            executable: tmuxPath,
            args: args,
            environment: environment,
            execName: "tmux",
            desiredWindowSize: size
        )

        // Scroll to bottom after tmux sends its initial repaint
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.scrollToBottom()
        }

        logger.info("Attached to tmux session: \(self.session.tmuxSessionName)")
    }

    /// Pre-populates xterm.js scrollback buffer with tmux pane history.
    /// Called before PTY attachment on session restore so the user has
    /// scrollable context from the previous session.
    private func preloadScrollback() async {
        guard let history = await TmuxManager.shared.captureHistory(
            sessionName: session.tmuxSessionName
        ) else { return }

        // Convert LF → CR+LF for proper xterm.js line rendering
        let converted = history.replacingOccurrences(of: "\n", with: "\r\n")
        // Reset attributes after history to prevent color bleed into live content
        let text = converted + "\r\n\u{1b}[0m"
        guard let data = text.data(using: .utf8) else { return }

        bridge.writeToTerminalImmediate(data: data)
        let lineCount = history.components(separatedBy: "\n").count
        logger.info("Preloaded \(lineCount) lines of scrollback history")
    }

    /// Feeds a visible error message into the terminal view.
    func feedError(_ message: String) {
        bridge.feedText("\r\n\u{1b}[1;31m[Error]\u{1b}[0m \(message)\r\n")
    }

    /// Feeds a visible info message into the terminal view.
    func feedInfo(_ message: String) {
        bridge.feedText("\r\n\u{1b}[2m\(message)\u{1b}[0m\r\n")
    }

    // MARK: - TerminalBridgeDelegate

    func bridgeDidBecomeReady(_ bridge: TerminalBridge, cols: Int, rows: Int) {
        logger.info("Terminal bridge ready: \(cols)x\(rows)")
        if pendingTmuxAttach {
            pendingTmuxAttach = false
            performTmuxAttach()
        }
    }

    func bridgeDidReceiveInput(_ bridge: TerminalBridge, data: Data) {
        ptyProcess.send(data: data)
    }

    func bridgeDidReceiveBinaryInput(_ bridge: TerminalBridge, data: Data) {
        ptyProcess.send(data: data)
    }

    func bridgeDidUpdateTitle(_ bridge: TerminalBridge, title: String) {
        delegate?.terminalDidUpdateTitle(self, title: title)
    }

    func bridgeDidResize(_ bridge: TerminalBridge, cols: Int, rows: Int) {
        guard ptyProcess.running else { return }
        let size = winsize(ws_row: UInt16(rows), ws_col: UInt16(cols), ws_xpixel: 0, ws_ypixel: 0)
        ptyProcess.setWindowSize(size)
    }

    func bridgeDidRequestOpenURL(_ bridge: TerminalBridge, url: URL) {
        NSWorkspace.shared.open(url)
    }

    func bridgeDidCopySelection(_ bridge: TerminalBridge, text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: - PTYProcessDelegate

    func ptyProcess(_ process: PTYProcess, didReceiveData data: Data) {
        bridge.writeToTerminal(data: data)
    }

    func ptyProcess(_ process: PTYProcess, didTerminateWithExitCode exitCode: Int32?) {
        logger.info("Terminal process terminated (exit=\(exitCode.map { String($0) } ?? "nil"))")
        delegate?.terminalProcessDidTerminate(self, exitCode: exitCode)
    }
}
