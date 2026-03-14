import Foundation

enum Defaults {
    // MARK: - General
    static let defaultCLIType = "defaultCLIType"
    static let defaultModel = "defaultModel"
    static let defaultPermissionMode = "defaultPermissionMode"
    static let defaultEffortLevel = "defaultEffortLevel"

    // MARK: - Codex
    static let codexModel = "codexModel"
    static let codexApprovalMode = "codexApprovalMode"
    static let codexFullAuto = "codexFullAuto"
    static let codexDangerouslyBypass = "codexDangerouslyBypass"

    // MARK: - Appearance
    static let terminalFontName = "terminalFontName"
    static let terminalFontSize = "terminalFontSize"

    // MARK: - Notifications
    static let notificationsEnabled = "notificationsEnabled"
    static let notifyOnStop = "notifyOnStop"
    static let notifyOnPermission = "notifyOnPermission"
    static let activateOnStop = "activateOnStop"

    // MARK: - Launcher Options
    static let launcherSkipPermissions = "launcherSkipPermissions"
    static let launcherContinueSession = "launcherContinueSession"
    static let launcherVerbose = "launcherVerbose"

    // MARK: - Confirmations
    static let suppressCloseTabAlert = "suppressCloseTabAlert"
    static let suppressQuitAlert = "suppressQuitAlert"

    // MARK: - Sessions
    static let recentDirectories = "recentDirectories"
    static let activeSessionId = "activeSessionId"

    static func register() {
        UserDefaults.standard.register(defaults: [
            notificationsEnabled: true,
            notifyOnStop: true,
            notifyOnPermission: true,
            terminalFontName: "Comic Code",
            terminalFontSize: 13.0,
            activateOnStop: false,
        ])
    }
}
