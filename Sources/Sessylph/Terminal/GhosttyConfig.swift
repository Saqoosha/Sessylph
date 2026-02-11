import Foundation
import os.log
@preconcurrency import GhosttyKit

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Sessylph", category: "GhosttyConfig")

@MainActor
enum GhosttyConfig {

    /// Creates a new ghostty config with Sessylph-specific settings applied.
    static func makeConfig() -> ghostty_config_t? {
        guard let config = ghostty_config_new() else {
            logger.error("ghostty_config_new() returned nil")
            return nil
        }

        let fontSize = UserDefaults.standard.double(forKey: Defaults.terminalFontSize)
        let fontName = UserDefaults.standard.string(forKey: Defaults.terminalFontName) ?? "monospace"

        let lines: [String] = [
            "font-family = \(fontName)",
            "font-size = \(fontSize > 0 ? fontSize : 13)",
            // Map CJK codepoints to a Japanese sans-serif font
            // to prevent CoreText falling back to Chinese serif fonts.
            "font-codepoint-map = U+3000-U+30FF,U+4E00-U+9FFF,U+F900-U+FAFF,U+FF00-U+FFEF=Noto Sans Mono CJK JP",
            "theme = GitHub Light",
            "background = #ffffff",
            "foreground = #000000",
            "scrollback-limit = 10000",
            "shell-integration = none",
            "mouse-scroll-multiplier = 1",
            "window-decoration = false",
            "window-padding-x = 8",
            "window-padding-y = 4,0",
            "confirm-close-surface = false",
            "copy-on-select = clipboard",
            "keybind = shift+enter=text:\\x0a",
        ]

        let content = lines.joined(separator: "\n") + "\n"
        let tempFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("sessylph-ghostty.conf")

        do {
            try content.write(to: tempFile, atomically: true, encoding: .utf8)
            tempFile.path.withCString { cPath in
                ghostty_config_load_file(config, cPath)
            }
            try? FileManager.default.removeItem(at: tempFile)
        } catch {
            logger.error("Failed to write ghostty config file: \(error.localizedDescription)")
            ghostty_config_free(config)
            return nil
        }

        ghostty_config_finalize(config)
        return config
    }
}
