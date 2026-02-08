import AppKit
import CoreText
import SwiftTerm
import os.log

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Sessylph", category: "Terminal")

private let terminalPadding: CGFloat = 16

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
    nonisolated(unsafe) private var keyEventMonitor: Any?
    nonisolated(unsafe) private var mouseUpMonitor: Any?
    nonisolated(unsafe) private var mouseMovedMonitor: Any?
    nonisolated(unsafe) private var scrollWheelMonitor: Any?
    nonisolated(unsafe) private var mouseDragMonitor: Any?
    private var didDragSelection = false
    private var isOverURL = false
    private var urlUnderlineLayer: CALayer?

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

        // Disable mouse reporting so SwiftTerm handles selection natively
        // instead of forwarding mouse events to tmux.
        // scrollWheel is independent and continues to work.
        terminalView.allowMouseReporting = false

        installKeyEventMonitor()
        installMouseMonitors()
        installScrollWheelMonitor()

        // Start tmux attach
        startTmuxAttach()
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        resetURLHoverState()
    }

    private func resetURLHoverState() {
        if isOverURL {
            isOverURL = false
            hideURLUnderline()
            NSCursor.arrow.set()
        }
    }

    deinit {
        if let keyEventMonitor {
            NSEvent.removeMonitor(keyEventMonitor)
        }
        if let mouseUpMonitor {
            NSEvent.removeMonitor(mouseUpMonitor)
        }
        if let mouseMovedMonitor {
            NSEvent.removeMonitor(mouseMovedMonitor)
        }
        if let scrollWheelMonitor {
            NSEvent.removeMonitor(scrollWheelMonitor)
        }
        if let mouseDragMonitor {
            NSEvent.removeMonitor(mouseDragMonitor)
        }
    }

    // MARK: - Key Event Monitor (Shift+Enter → newline, Cmd+V → image paste)

    private func installKeyEventMonitor() {
        keyEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let keyCode = event.keyCode
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

            // --- Cmd+V: Image paste (intercept before SwiftTerm's text-only paste) ---
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
                // Send LF (0x0A, same as Ctrl+J) which Claude Code treats as newline
                self.terminalView.send(data: ArraySlice<UInt8>([0x0a]))
                return true
            }
            return handled ? nil : event
        }
    }

    /// If the pasteboard contains an image, sends its file path to the terminal.
    /// Returns `true` if an image was handled, `false` to fall through to normal text paste.
    private func handleImagePaste() -> Bool {
        guard let path = ImagePasteHelper.imagePathFromPasteboard() else {
            return false
        }

        // Bracketed paste: ESC [ 200 ~ ... ESC [ 201 ~
        // Using raw bytes instead of EscapeSequences.bracketedPasteStart/End
        // because those are static vars (not concurrency-safe in Swift 6).
        let bracketedPaste = terminalView.terminal.bracketedPasteMode
        if bracketedPaste {
            terminalView.send(data: ArraySlice<UInt8>([0x1b, 0x5b, 0x32, 0x30, 0x30, 0x7e]))
        }
        terminalView.send(txt: path)
        if bracketedPaste {
            terminalView.send(data: ArraySlice<UInt8>([0x1b, 0x5b, 0x32, 0x30, 0x31, 0x7e]))
        }

        return true
    }

    // MARK: - Mouse Handling (Auto-copy & URL Click)

    private func installMouseMonitors() {
        // Track mouse drag to distinguish drag-selection from simple clicks.
        // Without this, clicking the window to activate it would auto-copy
        // the previous selection, overwriting clipboard contents (e.g. images).
        mouseDragMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDragged) { [weak self] event in
            guard let eventWindow = event.window else { return event }
            let windowID = ObjectIdentifier(eventWindow)

            MainActor.assumeIsolated {
                guard let self,
                      let myWindow = self.view.window,
                      ObjectIdentifier(myWindow) == windowID else { return }
                self.didDragSelection = true
            }
            return event
        }

        // Auto-copy selection on mouse release & URL click detection
        mouseUpMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { [weak self] event in
            guard let eventWindow = event.window else { return event }
            let windowID = ObjectIdentifier(eventWindow)

            MainActor.assumeIsolated {
                guard let self,
                      let myWindow = self.view.window,
                      ObjectIdentifier(myWindow) == windowID else { return }

                if self.terminalView.selectionActive, self.didDragSelection {
                    // Auto-copy selection to clipboard (Warp-style),
                    // but only if user actually dragged to create/extend the selection.
                    self.terminalView.copy(self)
                } else if event.clickCount == 1, !self.terminalView.selectionActive {
                    // Single click with no selection → check for URL
                    if let url = self.detectURL(at: event) {
                        NSWorkspace.shared.open(url)
                    }
                }
                self.didDragSelection = false
            }
            return event
        }

        // Tracking area for mouseMoved events on the terminal view
        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        terminalView.addTrackingArea(trackingArea)

        // Cursor change on URL hover
        mouseMovedMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .mouseEntered, .mouseExited]) { [weak self] event in
            guard let eventWindow = event.window else { return event }
            let windowID = ObjectIdentifier(eventWindow)

            MainActor.assumeIsolated {
                guard let self,
                      let myWindow = self.view.window,
                      ObjectIdentifier(myWindow) == windowID else { return }
                self.handleMouseMovedOrExited(event)
            }
            return event
        }
    }

    // MARK: - Scroll Wheel → tmux

    /// Intercepts scroll wheel events and forwards them to tmux via the
    /// terminal's mouse protocol, so tmux can enter copy-mode and scroll
    /// through its scrollback buffer. Without this, scrolling does nothing
    /// because tmux runs in the alternate screen buffer and SwiftTerm's
    /// native scrollback is empty.
    private func installScrollWheelMonitor() {
        scrollWheelMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let eventWindow = event.window, event.deltaY != 0 else { return event }
            let windowID = ObjectIdentifier(eventWindow)

            let handled = MainActor.assumeIsolated { () -> Bool in
                guard let self,
                      let myWindow = self.view.window,
                      ObjectIdentifier(myWindow) == windowID else { return false }

                let terminal = self.terminalView.getTerminal()

                // Only forward when tmux has mouse mode enabled and we're in alternate screen
                guard terminal.mouseMode != .off else { return false }

                let (col, row) = self.gridPosition(from: event)
                // buttonFlags: 64 = wheel up, 65 = wheel down
                let buttonFlags = event.deltaY > 0 ? 64 : 65
                // Each event makes tmux scroll ~3 lines, so dampen the count.
                // Trackpad deltaY can be very large; discrete mouse wheels
                // typically send ±1..3.
                let rawDelta = abs(event.deltaY)
                let lines: Int
                if event.hasPreciseScrollingDeltas {
                    // Trackpad: 1 event per ~2px of delta
                    lines = max(1, Int(rawDelta / 2))
                } else {
                    // Discrete mouse wheel: 5 events per tick
                    lines = max(1, Int(rawDelta) * 5)
                }
                for _ in 0..<lines {
                    terminal.sendEvent(buttonFlags: buttonFlags, x: col, y: row)
                }
                return true
            }
            return handled ? nil : event
        }
    }

    private func handleMouseMovedOrExited(_ event: NSEvent) {
        if event.type == .mouseExited {
            if isOverURL {
                isOverURL = false
                hideURLUnderline()
                NSCursor.iBeam.set()
            }
            return
        }

        // Check if mouse is over our terminal view
        let pointInTerminal = terminalView.convert(event.locationInWindow, from: nil)
        guard terminalView.bounds.contains(pointInTerminal) else {
            if isOverURL {
                isOverURL = false
                hideURLUnderline()
                NSCursor.iBeam.set()
            }
            return
        }

        if let hit = detectURLHit(at: event) {
            if !isOverURL {
                isOverURL = true
                NSCursor.pointingHand.set()
            }
            showURLUnderline(row: hit.row, startCol: hit.range.location, length: hit.range.length)
        } else if isOverURL {
            isOverURL = false
            hideURLUnderline()
            NSCursor.iBeam.set()
        }
    }

    // MARK: - URL Underline

    private func showURLUnderline(row: Int, startCol: Int, length: Int) {
        let (cellWidth, cellHeight) = cellDimensions()
        let x = CGFloat(startCol) * cellWidth
        let y = terminalView.bounds.height - CGFloat(row + 1) * cellHeight
        let width = CGFloat(length) * cellWidth
        let underlineY = y + 1 // 1pt above cell bottom

        let layer: CALayer
        if let existing = urlUnderlineLayer {
            layer = existing
        } else {
            layer = CALayer()
            layer.backgroundColor = NSColor.linkColor.cgColor
            terminalView.layer?.addSublayer(layer)
            urlUnderlineLayer = layer
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.frame = CGRect(x: x, y: underlineY, width: width, height: 1)
        layer.isHidden = false
        CATransaction.commit()
    }

    private func hideURLUnderline() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        urlUnderlineLayer?.isHidden = true
        CATransaction.commit()
    }

    // MARK: - URL Detection

    private struct URLHit {
        let url: URL
        let range: NSRange
        let row: Int
    }

    private func detectURLHit(at event: NSEvent) -> URLHit? {
        let (col, row) = gridPosition(from: event)
        let terminal = terminalView.getTerminal()
        guard row >= 0, row < terminal.rows, col >= 0, col < terminal.cols else {
            return nil
        }

        guard let line = terminal.getLine(row: row) else { return nil }
        let lineText = line.translateToString(trimRight: true)
        guard !lineText.isEmpty else { return nil }

        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return nil
        }

        let nsText = lineText as NSString
        let results = detector.matches(in: lineText, range: NSRange(location: 0, length: nsText.length))

        for result in results {
            guard let url = result.url else { continue }
            let startCol = result.range.location
            let endCol = startCol + result.range.length
            if col >= startCol, col < endCol {
                return URLHit(url: url, range: result.range, row: row)
            }
        }
        return nil
    }

    private func detectURL(at event: NSEvent) -> URL? {
        detectURLHit(at: event)?.url
    }

    /// Converts a mouse event to terminal grid coordinates (col, row).
    private func gridPosition(from event: NSEvent) -> (col: Int, row: Int) {
        let point = terminalView.convert(event.locationInWindow, from: nil)
        let (cellWidth, cellHeight) = cellDimensions()
        let col = Int(point.x / cellWidth)
        let row = Int((terminalView.bounds.height - point.y) / cellHeight)
        return (col, row)
    }

    /// Computes cell dimensions from the terminal font, replicating SwiftTerm's internal logic.
    private func cellDimensions() -> (width: CGFloat, height: CGFloat) {
        let f = terminalView.font
        let cellWidth = f.advancement(forGlyph: f.glyph(withName: "W")).width
        let cellHeight = ceil(CTFontGetAscent(f) + CTFontGetDescent(f) + CTFontGetLeading(f))
        return (max(1, cellWidth), max(1, cellHeight))
    }

    // MARK: - Terminal Size

    /// Returns the current terminal grid dimensions.
    var terminalSize: (cols: Int, rows: Int) {
        let terminal = terminalView.getTerminal()
        return (terminal.cols, terminal.rows)
    }

    /// Re-sends the current terminal size to the pty so tmux picks up
    /// this client's dimensions (e.g. after switching from another terminal).
    /// Sends a bumped size first because macOS may suppress SIGWINCH when
    /// the size hasn't actually changed.
    func refreshPtySize() {
        guard terminalView.process.running else { return }
        let fd = terminalView.process.childfd
        // First: send a 1-row-larger size to guarantee a real change
        var bumped = terminalView.getWindowSize()
        bumped.ws_row += 1
        _ = PseudoTerminalHelpers.setWinSize(masterPtyDescriptor: fd, windowSize: &bumped)
        // Then: restore the real size on the next run-loop cycle
        DispatchQueue.main.async { [weak self] in
            guard let self, self.terminalView.process.running else { return }
            var real = self.terminalView.getWindowSize()
            _ = PseudoTerminalHelpers.setWinSize(masterPtyDescriptor: fd, windowSize: &real)
        }
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

        var environment = EnvironmentBuilder.loginEnvironment()
        // Ensure TERM is set to a value tmux understands; without this
        // tmux may fail with "terminal does not support clear".
        if let idx = environment.firstIndex(where: { $0.hasPrefix("TERM=") }) {
            environment[idx] = "TERM=xterm-256color"
        } else {
            environment.append("TERM=xterm-256color")
        }
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
