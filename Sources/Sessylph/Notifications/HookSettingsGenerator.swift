import Foundation

enum HookSettingsGenerator {
    /// Generates a temporary JSON settings file for Claude Code hooks.
    /// The hooks call the bundled sessylph-notifier to relay events to the main app.
    static func generate(sessionId: String, notifierPath: String) throws -> URL {
        let settings: [String: Any] = [
            "hooks": [
                "Stop": [
                    [
                        "matcher": "",
                        "hooks": [
                            [
                                "type": "command",
                                "command": "\(shellQuote(notifierPath)) \(shellQuote(sessionId)) stop",
                                "timeout": 5,
                            ]
                        ],
                    ]
                ],
                "Notification": [
                    [
                        "matcher": "permission_prompt",
                        "hooks": [
                            [
                                "type": "command",
                                "command": "\(shellQuote(notifierPath)) \(shellQuote(sessionId)) permission_prompt",
                                "timeout": 5,
                            ]
                        ],
                    ],
                    [
                        "matcher": "idle_prompt",
                        "hooks": [
                            [
                                "type": "command",
                                "command": "\(shellQuote(notifierPath)) \(shellQuote(sessionId)) idle_prompt",
                                "timeout": 5,
                            ]
                        ],
                    ],
                ],
            ]
        ]

        let data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sh.saqoo.Sessylph", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let fileURL = tempDir.appendingPathComponent("hooks-\(sessionId).json")
        try data.write(to: fileURL, options: .atomic)
        return fileURL
    }

    /// Cleans up the temporary settings file for a session.
    static func cleanup(sessionId: String) {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sh.saqoo.Sessylph", isDirectory: true)
        let fileURL = tempDir.appendingPathComponent("hooks-\(sessionId).json")
        try? FileManager.default.removeItem(at: fileURL)
    }

    /// Resolves the path to the bundled sessylph-notifier tool.
    static func notifierPath() -> String? {
        Bundle.main.path(forAuxiliaryExecutable: "sessylph-notifier")
    }
}
