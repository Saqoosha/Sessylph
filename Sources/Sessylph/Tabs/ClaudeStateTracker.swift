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
}

// MARK: - ClaudeStateTracker

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
    private var isRunning: () -> Bool

    private var titlePollTimer: Timer?
    private var lastPolledTitle: String?
    private var spinnerTimer: Timer?
    private var spinnerIndex: Int = 0
    private static let spinnerFrames: [String] = ["·", "✻", "✽", "✶", "✳", "✢"]

    // MARK: - Initialization

    init(sessionName: String, isRunning: @escaping () -> Bool) {
        self.sessionName = sessionName
        self.isRunning = isRunning
    }

    /// Update the tmux session name (e.g. after a rename).
    func updateSessionName(_ name: String) {
        self.sessionName = name
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

    // MARK: - Title Update

    /// Called when a new title is received (from polling or terminal callback).
    func updateTitle(from rawTitle: String) {
        lastPolledTitle = rawTitle
        let (state, taskDesc) = Self.parseClaudeTitle(rawTitle)
        claudeState = state

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
        guard let title = await TmuxManager.shared.getPaneTitle(sessionName: sessionName) else { return }
        guard title != lastPolledTitle else { return }
        updateTitle(from: title)
    }
}
