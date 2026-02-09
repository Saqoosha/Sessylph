import WebKit
import os.log

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Sessylph", category: "TerminalBridge")

@MainActor
protocol TerminalBridgeDelegate: AnyObject {
    func bridgeDidBecomeReady(_ bridge: TerminalBridge, cols: Int, rows: Int)
    func bridgeDidReceiveInput(_ bridge: TerminalBridge, data: Data)
    func bridgeDidReceiveBinaryInput(_ bridge: TerminalBridge, data: Data)
    func bridgeDidUpdateTitle(_ bridge: TerminalBridge, title: String)
    func bridgeDidResize(_ bridge: TerminalBridge, cols: Int, rows: Int)
    func bridgeDidRequestOpenURL(_ bridge: TerminalBridge, url: URL)
    func bridgeDidCopySelection(_ bridge: TerminalBridge, text: String)
}

struct TerminalConfig {
    var fontFamily: String = "Comic Code"
    var fontSize: CGFloat = 13
    var background: String = "#ffffff"
    var foreground: String = "#000000"
}

/// Bridges Swift and xterm.js running inside a WKWebView.
@MainActor
final class TerminalBridge: NSObject {
    weak var delegate: (any TerminalBridgeDelegate)?
    private(set) var webView: WKWebView!

    /// Current terminal dimensions (updated by JS resize events).
    private(set) var cols: Int = 80
    private(set) var rows: Int = 24

    /// Tracked from JS to allow synchronous access in Swift.
    private(set) var bracketedPasteMode: Bool = false

    /// Whether the JS side has reported ready.
    private(set) var isReady: Bool = false

    private var pendingData = Data()
    private var flushScheduled = false

    /// Buffered text to feed once bridge becomes ready.
    private var pendingFeedText: [String] = []

    private static let messageNames = [
        "ptyInput", "ptyBinary", "titleChange",
        "resize", "openURL", "selectionCopy", "ready", "modeChange",
    ]

    private var terminalConfig: TerminalConfig = TerminalConfig()

    // MARK: - Setup

    func createWebView(frame: CGRect) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")

        let userContent = config.userContentController
        for name in Self.messageNames {
            userContent.add(LeakAvoider(bridge: self), name: name)
        }

        let wv = WKWebView(frame: frame, configuration: config)
        wv.setValue(false, forKey: "drawsBackground")
        wv.pageZoom = 1.0
        wv.allowsMagnification = false
        wv.navigationDelegate = self
        self.webView = wv
        return wv
    }

    func loadTerminal(config: TerminalConfig) {
        self.terminalConfig = config
        guard let htmlURL = Bundle.main.url(
            forResource: "terminal",
            withExtension: "html",
            subdirectory: "WebResources"
        ) else {
            logger.error("terminal.html not found in bundle")
            return
        }
        let resourceDir = htmlURL.deletingLastPathComponent()
        webView.loadFileURL(htmlURL, allowingReadAccessTo: resourceDir)
    }

    // MARK: - Write PTY data to terminal

    func writeToTerminal(data: Data) {
        pendingData.append(data)
        guard !flushScheduled else { return }
        flushScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.flushPendingData()
        }
    }

    private func flushPendingData() {
        flushScheduled = false
        guard !pendingData.isEmpty, isReady else { return }
        let base64 = pendingData.base64EncodedString()
        pendingData.removeAll(keepingCapacity: true)
        webView.evaluateJavaScript("writePtyData('\(base64)')")
    }

    /// Writes data directly to xterm.js without buffering.
    /// Used for preloading scrollback history before PTY attachment.
    func writeToTerminalImmediate(data: Data) {
        guard isReady else { return }
        let base64 = data.base64EncodedString()
        webView.evaluateJavaScript("writePtyData('\(base64)')")
    }

    // MARK: - Convenience JS calls

    func updateFont(family: String, size: CGFloat) {
        let escaped = family.replacingOccurrences(of: "'", with: "\\'")
        webView.evaluateJavaScript("updateFont('\(escaped)', \(size))")
    }

    func scrollToBottom() {
        webView.evaluateJavaScript("scrollToBottom()")
    }

    func focus() {
        webView.evaluateJavaScript("focusTerminal()")
    }

    func feedText(_ text: String) {
        guard isReady else {
            pendingFeedText.append(text)
            return
        }
        let escaped = text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
        webView.evaluateJavaScript("feedText('\(escaped)')")
    }

    // MARK: - Handle messages from JS

    fileprivate func handleMessage(name: String, body: Any) {
        switch name {
        case "ready":
            guard let dict = body as? [String: Int] else { return }
            cols = dict["cols"] ?? 80
            rows = dict["rows"] ?? 24
            isReady = true
            logger.info("Bridge ready: \(self.cols)x\(self.rows)")

            // Flush pending feed text
            for text in pendingFeedText {
                feedText(text)
            }
            pendingFeedText.removeAll()

            // Flush pending data
            flushPendingData()

            delegate?.bridgeDidBecomeReady(self, cols: cols, rows: rows)

        case "ptyInput":
            guard let str = body as? String else { return }
            delegate?.bridgeDidReceiveInput(self, data: Data(str.utf8))

        case "ptyBinary":
            guard let base64 = body as? String, let data = Data(base64Encoded: base64) else { return }
            delegate?.bridgeDidReceiveBinaryInput(self, data: data)

        case "titleChange":
            guard let title = body as? String else { return }
            delegate?.bridgeDidUpdateTitle(self, title: title)

        case "resize":
            guard let dict = body as? [String: Int],
                  let c = dict["cols"], let r = dict["rows"] else { return }
            cols = c
            rows = r
            delegate?.bridgeDidResize(self, cols: c, rows: r)

        case "openURL":
            guard let urlStr = body as? String, let url = URL(string: urlStr) else { return }
            delegate?.bridgeDidRequestOpenURL(self, url: url)

        case "selectionCopy":
            guard let text = body as? String else { return }
            delegate?.bridgeDidCopySelection(self, text: text)

        case "modeChange":
            guard let dict = body as? [String: Bool] else { return }
            if let bp = dict["bracketedPaste"] {
                bracketedPasteMode = bp
            }

        default:
            break
        }
    }
}

// MARK: - WKNavigationDelegate

extension TerminalBridge: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let config = self.terminalConfig
        let js = """
        initTerminal({
            fontFamily: '\(config.fontFamily.replacingOccurrences(of: "'", with: "\\'"))',
            fontSize: \(config.fontSize),
            background: '\(config.background)',
            foreground: '\(config.foreground)'
        });
        """
        webView.evaluateJavaScript(js)
    }
}

// MARK: - Leak Avoider (prevent WKWebView -> bridge retain cycle)

/// WKUserContentController retains its message handlers.
/// This weak wrapper prevents a retain cycle.
@MainActor
private final class LeakAvoider: NSObject, WKScriptMessageHandler {
    weak var bridge: TerminalBridge?

    init(bridge: TerminalBridge) {
        self.bridge = bridge
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        bridge?.handleMessage(name: message.name, body: message.body)
    }
}
