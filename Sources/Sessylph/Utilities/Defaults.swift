import Foundation

enum Defaults {
    // MARK: - General
    static let defaultModel = "defaultModel"
    static let defaultPermissionMode = "defaultPermissionMode"
    static let claudePathOverride = "claudePathOverride"
    static let tmuxPathOverride = "tmuxPathOverride"

    // MARK: - Appearance
    static let terminalFontName = "terminalFontName"
    static let terminalFontSize = "terminalFontSize"

    // MARK: - Notifications
    static let notificationsEnabled = "notificationsEnabled"
    static let notifyOnStop = "notifyOnStop"
    static let notifyOnPermission = "notifyOnPermission"

    // MARK: - Sessions
    static let savedSessions = "savedSessions"
    static let recentDirectories = "recentDirectories"

    static func register() {
        UserDefaults.standard.register(defaults: [
            notificationsEnabled: true,
            notifyOnStop: true,
            notifyOnPermission: true,
            terminalFontName: "SF Mono",
            terminalFontSize: 13.0,
        ])
    }
}
