import Foundation
import os.log

private let logger = Logger(subsystem: "sh.saqoo.Sessylph", category: "TmuxManager")

final class TmuxManager: Sendable {
    static let shared = TmuxManager()
    static let sessionPrefix = "sessylph"

    /// The stable identifier suffix used for programmatic lookups.
    static func sessionNameSuffix(for id: UUID) -> String {
        "\(sessionPrefix)-\(id.uuidString.prefix(8).lowercased())"
    }

    /// Generates a tmux session name with folder (and optional task) up front,
    /// sessylph marker at the end for easy scanning in `tmux ls`.
    ///
    /// Format: `{folder} {suffix}` or `{folder} | {task} {suffix}`
    static func sessionName(for id: UUID, directory: URL, task: String = "") -> String {
        let folder = sanitizeForTmux(directory.lastPathComponent, maxLength: 20)
        let suffix = sessionNameSuffix(for: id)
        if task.isEmpty {
            return "\(folder)-\(suffix)"
        }
        let sanitizedTask = sanitizeForTmux(task, maxLength: 40)
        return "\(folder)_\(sanitizedTask)-\(suffix)"
    }

    /// Sanitizes a string for use in tmux session names.
    /// Replaces ` `, `.`, `:` and `/` (reserved in tmux target syntax) with `-`,
    /// then strips leading hyphens (e.g. `.tmux` → `tmux` not `-tmux`)
    /// to avoid tmux interpreting the name as option flags.
    private static func sanitizeForTmux(_ string: String, maxLength: Int) -> String {
        var result = string
            .replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: ".", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "/", with: "-")
        while result.hasPrefix("-") {
            result = String(result.dropFirst())
        }
        if result.isEmpty { result = "session" }
        if result.count > maxLength {
            result = String(result.prefix(maxLength))
        }
        return result
    }

    enum TmuxError: Error, LocalizedError {
        case nonZeroExit(Int32, stderr: String)
        case outputDecodingFailed

        var errorDescription: String? {
            switch self {
            case .nonZeroExit(let code, let stderr):
                return "tmux exited with code \(code): \(stderr)"
            case .outputDecodingFailed:
                return "Failed to decode tmux output"
            }
        }
    }

    private init() {}

    /// Configures tmux server-level options that only need to be set once
    /// per server lifetime (e.g. extended keys for CSI u / kitty protocol).
    /// All commands are batched into a single tmux invocation.
    /// Best-effort: failures are logged but don't block session launch.
    /// Server-level options applied once per server lifetime.
    /// Included in createAndLaunchSession and configureSession batches
    /// (not a separate call, since the tmux server may not exist yet).
    private static let serverOptions: [String] = [
        ";", "set-option", "-s", "extended-keys", "on",
        ";", "set-option", "-s", "extended-keys-format", "csi-u",
        ";", "set-option", "-sa", "terminal-features", "xterm-256color:extkeys",
        // Disable alternate screen so output stays in the main buffer,
        // allowing xterm.js scrollback to accumulate history.
        ";", "set-option", "-sa", "terminal-overrides", ",xterm-256color:smcup@:rmcup@",
        // Use the latest active client's size (not the smallest)
        ";", "set-option", "-g", "window-size", "latest",
        // Mouse off — let xterm.js handle scroll natively via its scrollback buffer.
        ";", "set-option", "-g", "mouse", "off",
        // Remove CLAUDECODE from tmux global environment so new sessions don't
        // inherit it — Claude Code treats its presence as a nested session and
        // refuses to start.
        ";", "set-environment", "-gu", "CLAUDECODE",
    ]

    /// Configures an existing tmux session for title passthrough.
    /// Used when reattaching to orphaned sessions that are already running.
    /// All commands are batched into a single tmux invocation.
    /// Best-effort: failures are logged but don't block reattach.
    func configureSession(name: String) async {
        let t = "=\(name)"
        _ = try? await runTmux(args: [
            "set-option", "-t", t, "set-titles", "on",
            ";", "set-option", "-t", t, "set-titles-string", "#{pane_title}",
            ";", "set-option", "-t", t, "allow-passthrough", "on",
            ";", "set-option", "-t", t, "mouse", "off",
        ] + Self.serverOptions)
    }

    /// Creates a tmux session, configures it for title passthrough, and launches
    /// Claude — all in a single process spawn to minimize startup latency.
    ///
    /// Replaces the previous sequence of `createSession` + `configureSession` +
    /// `launchClaude` which required 6 separate process spawns.
    func createAndLaunchSession(
        name: String,
        directory: URL,
        command: String
    ) async throws {
        // NOTE: Do NOT use "=" prefix for -t targets within the same batch as
        // new-session. tmux's batch parser cannot resolve "=name" for a session
        // that was just created in the same invocation.
        do {
            _ = try await runTmux(args: [
                "new-session", "-d", "-s", name, "-c", directory.path,
                // Title passthrough (best-effort)
                ";", "set-option", "-t", name, "set-titles", "on",
                ";", "set-option", "-t", name, "set-titles-string", "#{pane_title}",
                // Escape sequence passthrough (tmux 3.3+, may fail on older versions)
                ";", "set-option", "-t", name, "allow-passthrough", "on",
                ";", "set-option", "-t", name, "mouse", "off",
            ] + Self.serverOptions + [
                // Launch Claude (must be last — earlier commands may fail best-effort)
                ";", "send-keys", "-t", name, command, "Enter",
            ])
        } catch {
            // Best-effort set-options (e.g. allow-passthrough on older tmux) may
            // cause non-zero exit even though the session was created and Claude
            // was launched successfully. Verify the session actually exists.
            guard await sessionExists(name: name) else {
                throw error
            }
            logger.info("Session \(name) created (some tmux options may not be supported)")
        }
    }

    /// Renames a tmux session. Best-effort: returns false on failure.
    func renameSession(from oldName: String, to newName: String) async -> Bool {
        guard oldName != newName else { return true }
        do {
            _ = try await runTmux(args: [
                "rename-session", "-t", "=\(oldName)", newName,
            ])
            return true
        } catch {
            logger.debug("Failed to rename session \(oldName) → \(newName): \(error.localizedDescription)")
            return false
        }
    }

    /// Kills a session.
    /// `tmux kill-session -t {name}`
    func killSession(name: String) async throws {
        _ = try await runTmux(args: [
            "kill-session", "-t", "=\(name)",
        ])
    }

    /// Checks if session exists.
    /// `tmux has-session -t {name}`
    func sessionExists(name: String) async -> Bool {
        do {
            _ = try await runTmux(args: ["has-session", "-t", "=\(name)"])
            return true
        } catch {
            logger.debug("Session \(name) does not exist (or tmux error): \(error.localizedDescription)")
            return false
        }
    }

    /// Lists all sessylph-* sessions.
    func listSessylphSessions() async -> [String] {
        do {
            let output = try await runTmux(args: [
                "list-sessions", "-F", "#{session_name}",
            ])
            return output
                .components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { $0.contains(Self.sessionPrefix + "-") }
        } catch {
            logger.warning("Failed to list tmux sessions: \(error.localizedDescription)")
            return []
        }
    }

    /// Returns the current pane title for the given session.
    func getPaneTitle(sessionName: String) async -> String? {
        do {
            let output = try await runTmux(args: [
                "display-message", "-t", "=\(sessionName)", "-p", "#{pane_title}",
            ])
            let title = output.trimmingCharacters(in: .whitespacesAndNewlines)
            return title.isEmpty ? nil : title
        } catch {
            logger.debug("Failed to get pane title for \(sessionName): \(error.localizedDescription)")
            return nil
        }
    }

    /// Returns the tmux window dimensions (cols, rows) for the given session.
    func getWindowSize(sessionName: String) async -> (cols: Int, rows: Int)? {
        do {
            let output = try await runTmux(args: [
                "display-message", "-t", "=\(sessionName)", "-p", "#{window_width},#{window_height}",
            ])
            let parts = output.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ",")
            guard parts.count == 2, let w = Int(parts[0]), let h = Int(parts[1]) else { return nil }
            return (w, h)
        } catch {
            logger.debug("Failed to get window size for \(sessionName): \(error.localizedDescription)")
            return nil
        }
    }

    /// Returns the current working directory of the active pane.
    func getPaneCurrentPath(sessionName: String) async -> String? {
        do {
            let output = try await runTmux(args: [
                "display-message", "-t", "=\(sessionName)", "-p", "#{pane_current_path}",
            ])
            let path = output.trimmingCharacters(in: .whitespacesAndNewlines)
            return path.isEmpty ? nil : path
        } catch {
            logger.debug("Failed to get pane path for \(sessionName): \(error.localizedDescription)")
            return nil
        }
    }

    /// Captures pane content (scrollback history + visible viewport) with ANSI color escapes.
    /// Includes the visible viewport so that sessions with no scrollback history still
    /// get their viewport content preloaded into xterm.js scrollback buffer.
    /// Returns nil if capture fails or content is empty.
    func captureHistory(sessionName: String, lines: Int = 1000) async -> String? {
        do {
            let output = try await runTmux(args: [
                "capture-pane", "-t", "\(sessionName)", "-p", "-e", "-J",
                "-S", "-\(lines)",
            ])
            // Strip trailing blank lines from viewport padding
            let trimmed = output.replacingOccurrences(
                of: "\\n+$", with: "", options: .regularExpression
            )
            return trimmed.isEmpty ? nil : trimmed
        } catch {
            logger.debug("Failed to capture history for \(sessionName): \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Private

    private func runTmux(args: [String]) async throws -> String {
        let tmuxPath = try ClaudeCLI.tmuxPath()
        let environment = EnvironmentBuilder.loginEnvironmentDict()

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            DispatchQueue.global().async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: tmuxPath)
                process.arguments = args
                process.environment = environment
                process.currentDirectoryURL = URL(fileURLWithPath: NSTemporaryDirectory())

                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()
                process.standardOutput = stdoutPipe
                process.standardError = stderrPipe

                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }

                // Read pipe data BEFORE waitUntilExit to avoid deadlock:
                // if the process fills the pipe buffer, it blocks waiting for
                // a reader; reading in terminationHandler would never start.
                let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

                process.waitUntilExit()

                if process.terminationStatus != 0 {
                    let stderrString = String(data: stderrData, encoding: .utf8) ?? ""
                    continuation.resume(
                        throwing: TmuxError.nonZeroExit(
                            process.terminationStatus,
                            stderr: stderrString.trimmingCharacters(in: .whitespacesAndNewlines)
                        )
                    )
                    return
                }

                guard let output = String(data: stdoutData, encoding: .utf8) else {
                    continuation.resume(throwing: TmuxError.outputDecodingFailed)
                    return
                }

                continuation.resume(
                    returning: output.trimmingCharacters(in: .whitespacesAndNewlines)
                )
            }
        }
    }
}
