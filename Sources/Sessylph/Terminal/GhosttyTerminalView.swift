import AppKit
import os.log
@preconcurrency import GhosttyKit

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Sessylph", category: "GhosttyTerminalView")

@MainActor
final class GhosttyTerminalView: NSView, @preconcurrency NSTextInputClient {

    // MARK: - Callbacks

    var onTitleChange: ((String) -> Void)?
    var onProcessExit: (() -> Void)?

    // MARK: - State

    nonisolated(unsafe) private(set) var surface: ghostty_surface_t?
    private var markedText = NSMutableAttributedString()
    private var trackingArea: NSTrackingArea?
    /// Text accumulated from insertText() during interpretKeyEvents, consumed by keyDown
    private var keyTextAccumulator: [String] = []

    // Scrollbar
    private let scrollThumb = NSView()
    private var scrollHideTimer: Timer?
    private static let scrollbarWidth: CGFloat = 8
    private static let scrollbarInset: CGFloat = 2
    private static let scrollbarHideDelay: TimeInterval = 0.8

    override var acceptsFirstResponder: Bool { true }

    // MARK: - Init

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        setupScrollbar()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Surface Lifecycle

    private var backingScaleFactor: CGFloat {
        window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
    }

    @discardableResult
    func createSurface(command: String, workingDirectory: String?, envVars: [(String, String)] = []) -> Bool {
        guard let app = GhosttyApp.shared.app else {
            logger.error("GhosttyApp not initialized")
            return false
        }

        let scale = backingScaleFactor
        var config = ghostty_surface_config_new()
        config.userdata = Unmanaged.passUnretained(self).toOpaque()
        config.platform_tag = GHOSTTY_PLATFORM_MACOS
        config.platform = ghostty_platform_u(macos: ghostty_platform_macos_s(
            nsview: Unmanaged.passUnretained(self).toOpaque()
        ))
        config.scale_factor = Double(scale)
        config.context = GHOSTTY_SURFACE_CONTEXT_TAB

        // Set command and working directory using withCString closures
        // to ensure pointer lifetime matches ghostty_surface_new call
        command.withCString { cmdPtr in
            config.command = cmdPtr

            let createWithWorkDir = { (wdPtr: UnsafePointer<CChar>?) in
                config.working_directory = wdPtr

                if envVars.isEmpty {
                    config.env_vars = nil
                    config.env_var_count = 0
                    self.surface = ghostty_surface_new(app, &config)
                } else {
                    self.createSurfaceWithEnvVars(app: app, config: &config, envVars: envVars)
                }
            }

            if let wd = workingDirectory {
                wd.withCString { wdPtr in
                    createWithWorkDir(wdPtr)
                }
            } else {
                createWithWorkDir(nil)
            }
        }

        guard surface != nil else {
            logger.error("ghostty_surface_new returned nil")
            return false
        }

        // Set content scale explicitly (viewDidMoveToWindow fires before surface exists)
        ghostty_surface_set_content_scale(surface, Double(scale), Double(scale))

        // Set initial size using explicit scale multiplication
        // (convertToBacking may return 1:1 if window backing store isn't ready)
        let backingWidth = UInt32(bounds.width * scale)
        let backingHeight = UInt32(bounds.height * scale)
        ghostty_surface_set_size(surface, backingWidth, backingHeight)

        updateTrackingAreas()
        logger.info("Surface created: \(self.bounds.width)x\(self.bounds.height) pts, \(backingWidth)x\(backingHeight) px, scale=\(scale)")
        return true
    }

    private func createSurfaceWithEnvVars(app: ghostty_app_t, config: inout ghostty_surface_config_s, envVars: [(String, String)]) {
        // Create C strings that persist for the duration of this method
        var cKeys = envVars.map { strdup($0.0) }
        var cValues = envVars.map { strdup($0.1) }
        defer {
            cKeys.forEach { free($0) }
            cValues.forEach { free($0) }
        }

        var cEnvVars = (0..<envVars.count).map { i in
            ghostty_env_var_s(key: cKeys[i], value: cValues[i])
        }

        cEnvVars.withUnsafeMutableBufferPointer { envBuf in
            config.env_vars = envBuf.baseAddress
            config.env_var_count = envVars.count
            self.surface = ghostty_surface_new(app, &config)
        }
    }

    deinit {
        if let surface {
            ghostty_surface_free(surface)
        }
    }

    func teardown() {
        if let surface {
            ghostty_surface_free(surface)
            self.surface = nil
        }
    }

    // MARK: - Layout

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let surface else { return }
        let scale = backingScaleFactor
        ghostty_surface_set_content_scale(surface, Double(scale), Double(scale))
        ghostty_surface_set_size(surface, UInt32(bounds.width * scale), UInt32(bounds.height * scale))
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        guard let surface else { return }
        let scale = backingScaleFactor
        ghostty_surface_set_size(surface, UInt32(newSize.width * scale), UInt32(newSize.height * scale))
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        guard let surface else { return }
        let scale = backingScaleFactor
        ghostty_surface_set_content_scale(surface, Double(scale), Double(scale))
        ghostty_surface_set_size(surface, UInt32(bounds.width * scale), UInt32(bounds.height * scale))
    }

    // MARK: - Focus

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result, let surface {
            ghostty_surface_set_focus(surface, true)
        }
        return result
    }

    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if result, let surface {
            ghostty_surface_set_focus(surface, false)
        }
        return result
    }

    // MARK: - Edit Actions (from Edit menu / responder chain)

    @objc func paste(_ sender: Any?) {
        guard let surface else { return }
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else { return }
        text.withCString { cStr in
            ghostty_surface_text(surface, cStr, UInt(text.utf8.count))
        }
    }

    @objc func copy(_ sender: Any?) {
        guard let surface else { return }
        guard ghostty_surface_has_selection(surface) else { return }
        var textStruct = ghostty_text_s()
        guard ghostty_surface_read_selection(surface, &textStruct) else { return }
        defer { ghostty_surface_free_text(surface, &textStruct) }
        if let ptr = textStruct.text, textStruct.text_len > 0 {
            let data = Data(bytes: ptr, count: Int(textStruct.text_len))
            let str = String(data: data, encoding: .utf8) ?? String(cString: ptr)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(str, forType: .string)
        }
    }

    override func selectAll(_ sender: Any?) {
        // Not meaningful in a terminal — ignore
    }

    // MARK: - Keyboard Input

    /// Prevent NSView from beeping on unhandled selectors (e.g. deleteBackward: from backspace).
    /// Key events are handled by ghostty_surface_key() in keyDown, not by selector dispatch.
    override func doCommand(by selector: Selector) {
        // Intentionally empty — do not call super which would NSBeep()
    }

    override func keyDown(with event: NSEvent) {
        guard let surface else {
            interpretKeyEvents([event])
            return
        }

        // Accumulate text from insertText() calls during interpretKeyEvents
        let hadMarkedText = hasMarkedText()
        keyTextAccumulator = []
        interpretKeyEvents([event])

        // IME just committed text (was marked → now unmarked): send committed text directly
        if hadMarkedText && !hasMarkedText() {
            let committed = keyTextAccumulator.joined()
            if !committed.isEmpty {
                committed.withCString { cStr in
                    ghostty_surface_text(surface, cStr, UInt(committed.utf8.count))
                }
            }
            return
        }

        // IME is still composing — don't send key event
        if hasMarkedText() {
            return
        }

        // Build key event with accumulated text from insertText()
        let mods = GhosttyInputHandler.ghosttyMods(event.modifierFlags)

        var keyEvent = ghostty_input_key_s()
        keyEvent.action = event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS
        keyEvent.keycode = UInt32(event.keyCode)
        keyEvent.mods = mods
        keyEvent.consumed_mods = ghostty_input_mods_e(GHOSTTY_MODS_NONE.rawValue)

        let accumulatedText = keyTextAccumulator.joined()
        if !accumulatedText.isEmpty {
            accumulatedText.withCString { cStr in
                keyEvent.text = cStr
                ghostty_surface_key(surface, keyEvent)
            }
        } else {
            keyEvent.text = nil
            ghostty_surface_key(surface, keyEvent)
        }
    }

    override func keyUp(with event: NSEvent) {
        guard let surface else { return }
        let mods = GhosttyInputHandler.ghosttyMods(event.modifierFlags)

        var keyEvent = ghostty_input_key_s()
        keyEvent.action = GHOSTTY_ACTION_RELEASE
        keyEvent.keycode = UInt32(event.keyCode)
        keyEvent.mods = mods
        keyEvent.consumed_mods = ghostty_input_mods_e(GHOSTTY_MODS_NONE.rawValue)
        keyEvent.text = nil

        ghostty_surface_key(surface, keyEvent)
    }

    override func flagsChanged(with event: NSEvent) {
        guard let surface else { return }

        let mod: UInt32
        switch event.keyCode {
        case 0x39: mod = GHOSTTY_MODS_CAPS.rawValue
        case 0x38, 0x3C: mod = GHOSTTY_MODS_SHIFT.rawValue
        case 0x3B, 0x3E: mod = GHOSTTY_MODS_CTRL.rawValue
        case 0x3A, 0x3D: mod = GHOSTTY_MODS_ALT.rawValue
        case 0x37, 0x36: mod = GHOSTTY_MODS_SUPER.rawValue
        default: return
        }

        let mods = GhosttyInputHandler.ghosttyMods(event.modifierFlags)
        let pressed = mods.rawValue & mod != 0
        let action: ghostty_input_action_e = pressed ? GHOSTTY_ACTION_PRESS : GHOSTTY_ACTION_RELEASE

        var keyEvent = ghostty_input_key_s()
        keyEvent.action = action
        keyEvent.keycode = UInt32(event.keyCode)
        keyEvent.mods = mods
        keyEvent.consumed_mods = ghostty_input_mods_e(GHOSTTY_MODS_NONE.rawValue)
        keyEvent.text = nil

        ghostty_surface_key(surface, keyEvent)
    }

    // MARK: - Mouse Input

    override func mouseDown(with event: NSEvent) {
        guard let surface else { return }
        let mods = GhosttyInputHandler.ghosttyMods(event.modifierFlags)
        ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, mods)
    }

    override func mouseUp(with event: NSEvent) {
        guard let surface else { return }
        let mods = GhosttyInputHandler.ghosttyMods(event.modifierFlags)
        ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, mods)
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let surface else { return }
        let mods = GhosttyInputHandler.ghosttyMods(event.modifierFlags)
        ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_RIGHT, mods)
    }

    override func rightMouseUp(with event: NSEvent) {
        guard let surface else { return }
        let mods = GhosttyInputHandler.ghosttyMods(event.modifierFlags)
        ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_RIGHT, mods)
    }

    override func otherMouseDown(with event: NSEvent) {
        guard let surface else { return }
        let mods = GhosttyInputHandler.ghosttyMods(event.modifierFlags)
        let button = GhosttyInputHandler.ghosttyMouseButton(from: event.buttonNumber)
        ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, button, mods)
    }

    override func otherMouseUp(with event: NSEvent) {
        guard let surface else { return }
        let mods = GhosttyInputHandler.ghosttyMods(event.modifierFlags)
        let button = GhosttyInputHandler.ghosttyMouseButton(from: event.buttonNumber)
        ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, button, mods)
    }

    override func mouseMoved(with event: NSEvent) {
        guard let surface else { return }
        let pos = convert(event.locationInWindow, from: nil)
        let mods = GhosttyInputHandler.ghosttyMods(event.modifierFlags)
        ghostty_surface_mouse_pos(surface, pos.x, frame.height - pos.y, mods)
    }

    override func mouseDragged(with event: NSEvent) { mouseMoved(with: event) }
    override func rightMouseDragged(with event: NSEvent) { mouseMoved(with: event) }
    override func otherMouseDragged(with event: NSEvent) { mouseMoved(with: event) }

    override func scrollWheel(with event: NSEvent) {
        guard let surface else { return }
        var x = event.scrollingDeltaX
        var y = event.scrollingDeltaY
        if event.hasPreciseScrollingDeltas {
            x *= 2
            y *= 2
        }
        let mods = GhosttyInputHandler.scrollMods(
            precision: event.hasPreciseScrollingDeltas,
            momentumPhase: event.momentumPhase
        )
        ghostty_surface_mouse_scroll(surface, x, y, mods)
    }

    // MARK: - Tracking Area

    override func updateTrackingAreas() {
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        self.trackingArea = area
    }

    // MARK: - NSTextInputClient (IME support)

    func insertText(_ string: Any, replacementRange: NSRange) {
        guard let surface else { return }
        // Clear marked text and preedit display
        markedText.mutableString.setString("")
        ghostty_surface_preedit(surface, nil, 0)

        let text: String
        if let attrStr = string as? NSAttributedString {
            text = attrStr.string
        } else if let str = string as? String {
            text = str
        } else {
            return
        }

        // Accumulate for keyDown to pass via ghostty_surface_key()
        keyTextAccumulator.append(text)
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        guard let surface else { return }
        if let attrStr = string as? NSAttributedString {
            markedText = NSMutableAttributedString(attributedString: attrStr)
        } else if let str = string as? String {
            markedText = NSMutableAttributedString(string: str)
        }

        let text = markedText.string
        ghostty_surface_preedit(surface, text, UInt(text.utf8.count))
    }

    func unmarkText() {
        markedText.mutableString.setString("")
        guard let surface else { return }
        ghostty_surface_preedit(surface, nil, 0)
    }

    func hasMarkedText() -> Bool {
        markedText.length > 0
    }

    func markedRange() -> NSRange {
        guard markedText.length > 0 else { return NSRange() }
        return NSRange(location: 0, length: markedText.length)
    }

    func selectedRange() -> NSRange {
        NSRange()
    }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        nil
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] {
        []
    }

    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let surface else { return .zero }
        var x: Double = 0, y: Double = 0, w: Double = 0, h: Double = 0
        ghostty_surface_ime_point(surface, &x, &y, &w, &h)
        let viewPoint = NSPoint(x: x, y: frame.height - y)
        guard let window else { return NSRect(origin: viewPoint, size: NSSize(width: w, height: h)) }
        let windowPoint = convert(viewPoint, to: nil)
        let screenPoint = window.convertPoint(toScreen: windowPoint)
        return NSRect(origin: screenPoint, size: NSSize(width: w, height: h))
    }

    func characterIndex(for point: NSPoint) -> Int {
        0
    }

    // MARK: - Scrollbar

    private func setupScrollbar() {
        scrollThumb.wantsLayer = true
        scrollThumb.layer?.backgroundColor = NSColor(white: 0.5, alpha: 0.5).cgColor
        scrollThumb.layer?.cornerRadius = Self.scrollbarWidth / 2
        scrollThumb.alphaValue = 0
        addSubview(scrollThumb)
    }

    func updateScrollbar(total: UInt64, offset: UInt64, len: UInt64) {
        guard total > 0, len > 0, len < total else {
            // All content visible — hide scrollbar
            hideScrollbar(animated: false)
            return
        }

        let viewHeight = bounds.height
        let inset = Self.scrollbarInset
        let trackHeight = viewHeight - inset * 2

        let thumbHeight = max(CGFloat(len) / CGFloat(total) * trackHeight, 24)
        let maxOffset = CGFloat(total - len)
        let scrollFraction = maxOffset > 0 ? CGFloat(offset) / maxOffset : 0
        let thumbY = inset + (trackHeight - thumbHeight) * (1 - scrollFraction)

        scrollThumb.frame = NSRect(
            x: bounds.width - Self.scrollbarWidth - inset,
            y: thumbY,
            width: Self.scrollbarWidth,
            height: thumbHeight
        )

        showScrollbar()
    }

    private func showScrollbar() {
        scrollHideTimer?.invalidate()
        if scrollThumb.alphaValue < 1 {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.15
                scrollThumb.animator().alphaValue = 1
            }
        }
        scrollHideTimer = Timer.scheduledTimer(withTimeInterval: Self.scrollbarHideDelay, repeats: false) { [weak self] _ in
            self?.hideScrollbar(animated: true)
        }
    }

    private func hideScrollbar(animated: Bool) {
        scrollHideTimer?.invalidate()
        scrollHideTimer = nil
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.3
                scrollThumb.animator().alphaValue = 0
            }
        } else {
            scrollThumb.alphaValue = 0
        }
    }

    // MARK: - Text Feed (for error/info messages)

    func feedText(_ text: String) {
        guard let surface else { return }
        ghostty_surface_text(surface, text, UInt(text.utf8.count))
    }
}
