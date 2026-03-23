import AppKit
import os.log

private let logger = Logger(subsystem: "sh.saqoo.Sessylph", category: "ClaudeStateTracker")

// MARK: - ClaudeState

enum ClaudeState {
    case idle
    case working
    case unknown

    var icon: String {
        switch self {
        case .idle: "✳"
        case .working: "✻"
        case .unknown: "·"
        }
    }
}

// MARK: - ClaudeStateTrackerDelegate

@MainActor
protocol ClaudeStateTrackerDelegate: AnyObject {
    func stateTracker(_ tracker: ClaudeStateTracker, didUpdateState state: ClaudeState, icon: String)
    func stateTracker(_ tracker: ClaudeStateTracker, wantsRename newName: String)
    func stateTrackerDidCompleteTask(_ tracker: ClaudeStateTracker)
}

// MARK: - ClaudeStateTracker

/// Tracks terminal title state for all supported CLI types (Claude Code, Codex, Cursor Agent).
/// Parses CLI-specific title formats to determine idle/working status and fires completion notifications.
/// Named `ClaudeStateTracker` for historical reasons — originally Claude Code only.
@MainActor
final class ClaudeStateTracker {

    weak var delegate: ClaudeStateTrackerDelegate?

    private(set) var claudeState: ClaudeState = .unknown
    private(set) var lastTaskDescription: String = ""
    /// The last task description observed while Claude was actively working.
    /// Retained across idle transitions so notifications can reference the completed task.
    private(set) var lastWorkingTaskDescription: String = ""
    var needsAttention: Bool = false

    private var sessionName: String
    private var remoteHost: RemoteHost?
    private var isRunning: () -> Bool
    private let cliType: CLIType

    private var titlePollTimer: Timer?
    private var lastPolledTitle: String?
    private var spinnerTimer: Timer?
    private var spinnerIndex: Int = 0
    private static let spinnerFrames: [String] = ["·", "✻", "✽", "✶", "✳", "✢"]

    // MARK: - Initialization

    init(
        sessionName: String,
        remoteHost: RemoteHost? = nil,
        isRunning: @escaping () -> Bool,
        cliType: CLIType = .claudeCode
    ) {
        self.sessionName = sessionName
        self.remoteHost = remoteHost
        self.isRunning = isRunning
        self.cliType = cliType
    }

    /// Update the tmux session name (e.g. after a rename).
    func updateSessionName(_ name: String) {
        self.sessionName = name
    }

    func updateRemoteHost(_ host: RemoteHost?) {
        self.remoteHost = host
    }

    // MARK: - Title Parsing

    /// Parses Claude Code's terminal title and maps prefixes to state.
    ///
    /// Known formats:
    /// - `✳ Claude Code` — idle/ready
    /// - `⠂ Task description` / `⠐ Task description` — working (braille spinner)
    static func parseClaudeTitle(_ rawTitle: String) -> (state: ClaudeState, taskDescription: String) {
        guard let first = rawTitle.unicodeScalars.first else {
            return (.unknown, "")
        }

        // Braille spinner (U+2800–U+28FF) → working
        if first.value >= 0x2800, first.value <= 0x28FF {
            let rest = String(rawTitle.dropFirst()).trimmingCharacters(in: .whitespaces)
            return (.working, rest)
        }

        // ✳ (U+2733 Eight Spoked Asterisk) → idle/ready
        if first == Unicode.Scalar(0x2733) {
            let rest = String(rawTitle.dropFirst()).trimmingCharacters(in: .whitespaces)
            return (.idle, rest)
        }

        return (.unknown, rawTitle)
    }

    /// Parses Cursor Agent terminal titles. Falls back through:
    /// (1) Claude Code title format (prefix-based), (2) braille spinner anywhere in string,
    /// (3) status keywords ("thinking", "generating"). Returns `.unknown` if no working indicator found.
    static func parseCursorAgentTitle(_ rawTitle: String) -> (state: ClaudeState, taskDescription: String) {
        let claude = parseClaudeTitle(rawTitle)
        if claude.state != .unknown {
            return claude
        }
        if rawTitle.unicodeScalars.contains(where: { $0.value >= 0x2800 && $0.value <= 0x28FF }) {
            let rest = stripBrailleScalars(rawTitle).trimmingCharacters(in: .whitespaces)
            return (.working, rest)
        }
        let lower = rawTitle.lowercased()
        if lower.contains("thinking") || lower.contains("generating") {
            return (.working, stripBrailleScalars(rawTitle).trimmingCharacters(in: .whitespaces))
        }
        return (.unknown, rawTitle)
    }

    private static func stripBrailleScalars(_ s: String) -> String {
        String(s.unicodeScalars.filter { $0.value < 0x2800 || $0.value > 0x28FF })
    }

    /// Dispatches to the appropriate CLI-specific title parser based on `cliType`.
    static func parseTitle(_ rawTitle: String, cliType: CLIType) -> (state: ClaudeState, taskDescription: String) {
        switch cliType {
        case .claudeCode:
            return parseClaudeTitle(rawTitle)
        case .codex:
            return parseClaudeTitle(rawTitle)
        case .cursorAgent:
            return parseCursorAgentTitle(rawTitle)
        }
    }

    // MARK: - Title Update

    /// Called when a new title is received (from polling or terminal callback).
    func updateTitle(from rawTitle: String) {
        lastPolledTitle = rawTitle
        let (state, taskDesc) = Self.parseTitle(rawTitle, cliType: cliType)
        let previousState = claudeState
        claudeState = state

        // Detect task completion: working → idle
        if previousState == .working, state == .idle {
            delegate?.stateTrackerDidCompleteTask(self)
        }

        if state == .working {
            needsAttention = false
            lastWorkingTaskDescription = taskDesc
            // Only rename tmux session for actual working tasks (keep last task when idle)
            if taskDesc != lastTaskDescription {
                delegate?.stateTracker(self, wantsRename: taskDesc)
            }
        }
        lastTaskDescription = taskDesc

        if needsAttention {
            stopSpinner()
            delegate?.stateTracker(self, didUpdateState: state, icon: "❓")
        } else if state == .working {
            startSpinner()
        } else {
            stopSpinner()
            delegate?.stateTracker(self, didUpdateState: state, icon: state.icon)
        }
    }

    /// Called by the window controller when a hook "notification" event is received.
    func markNeedsAttention() {
        needsAttention = true
        delegate?.stateTracker(self, didUpdateState: claudeState, icon: "❓")
    }

    // MARK: - Working Spinner

    var isSpinning: Bool { spinnerTimer != nil }

    private func startSpinner() {
        guard spinnerTimer == nil else {
            // Already spinning — just apply the current frame
            delegate?.stateTracker(self, didUpdateState: .working, icon: Self.spinnerFrames[spinnerIndex])
            return
        }
        spinnerIndex = 0
        delegate?.stateTracker(self, didUpdateState: .working, icon: Self.spinnerFrames[spinnerIndex])
        spinnerTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.spinnerIndex = (self.spinnerIndex + 1) % Self.spinnerFrames.count
                self.delegate?.stateTracker(self, didUpdateState: .working, icon: Self.spinnerFrames[self.spinnerIndex])
            }
        }
    }

    func stopSpinner() {
        spinnerTimer?.invalidate()
        spinnerTimer = nil
    }

    // MARK: - Title Polling

    func startTitlePolling() {
        Task { await pollPaneTitle() }
        titlePollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.pollPaneTitle()
            }
        }
    }

    func stopTitlePolling() {
        titlePollTimer?.invalidate()
        titlePollTimer = nil
    }

    private func pollPaneTitle() async {
        guard isRunning() else { return }
        guard let title = await TmuxManager.shared.getPaneTitle(sessionName: sessionName, remoteHost: remoteHost) else { return }
        guard title != lastPolledTitle else { return }
        updateTitle(from: title)
    }
}
