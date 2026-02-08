import Foundation
import os.log

private let logger = Logger(subsystem: "sh.saqoo.Sessylph", category: "TmuxManager")

final class TmuxManager: Sendable {
    static let shared = TmuxManager()
    static let sessionPrefix = "sessylph"

    /// Generates a tmux session name from a session UUID.
    static func sessionName(for id: UUID) -> String {
        "\(sessionPrefix)-\(id.uuidString.prefix(8).lowercased())"
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
    func configureServerOptions() async {
        // Batch all server-level options into one process spawn using ";" separators.
        // Individual command failures don't prevent subsequent commands from running.
        _ = try? await runTmux(args: [
            "set-option", "-s", "extended-keys", "on",
            ";", "set-option", "-s", "extended-keys-format", "csi-u",
            ";", "set-option", "-sa", "terminal-features", "xterm-256color:extkeys",
            // Use the latest active client's size (not the smallest), so when
            // multiple clients (e.g. Warp + Sessylph) share a session, switching
            // between them resizes the window to match the active terminal.
            ";", "set-option", "-g", "window-size", "latest",
            // Scroll 1 line per mouse wheel event (default is 5)
            ";", "bind-key", "-T", "copy-mode", "WheelUpPane", "send-keys", "-X", "scroll-up",
            ";", "bind-key", "-T", "copy-mode", "WheelDownPane", "send-keys", "-X", "scroll-down",
            ";", "bind-key", "-T", "copy-mode-vi", "WheelUpPane", "send-keys", "-X", "scroll-up",
            ";", "bind-key", "-T", "copy-mode-vi", "WheelDownPane", "send-keys", "-X", "scroll-down",
        ])
    }

    /// Configures an existing tmux session for title passthrough.
    /// Used when reattaching to orphaned sessions that are already running.
    /// All commands are batched into a single tmux invocation.
    /// Best-effort: failures are logged but don't block reattach.
    func configureSession(name: String) async {
        _ = try? await runTmux(args: [
            "set-option", "-t", name, "set-titles", "on",
            ";", "set-option", "-t", name, "set-titles-string", "#{pane_title}",
            ";", "set-option", "-t", name, "allow-passthrough", "on",
            ";", "set-option", "-t", name, "mouse", "on",
        ])
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
        do {
            _ = try await runTmux(args: [
                "new-session", "-d", "-s", name, "-c", directory.path,
                // Title passthrough (best-effort)
                ";", "set-option", "-t", name, "set-titles", "on",
                ";", "set-option", "-t", name, "set-titles-string", "#{pane_title}",
                // Escape sequence passthrough (tmux 3.3+, may fail on older versions)
                ";", "set-option", "-t", name, "allow-passthrough", "on",
                // Mouse support for scroll wheel
                ";", "set-option", "-t", name, "mouse", "on",
                // Launch Claude
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

    /// Kills a session.
    /// `tmux kill-session -t {name}`
    func killSession(name: String) async throws {
        _ = try await runTmux(args: [
            "kill-session", "-t", name,
        ])
    }

    /// Checks if session exists.
    /// `tmux has-session -t {name}`
    func sessionExists(name: String) async -> Bool {
        do {
            _ = try await runTmux(args: ["has-session", "-t", name])
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
                .filter { $0.hasPrefix(Self.sessionPrefix + "-") }
        } catch {
            logger.warning("Failed to list tmux sessions: \(error.localizedDescription)")
            return []
        }
    }

    /// Returns the current pane title for the given session.
    func getPaneTitle(sessionName: String) async -> String? {
        do {
            let output = try await runTmux(args: [
                "display-message", "-t", sessionName, "-p", "#{pane_title}",
            ])
            let title = output.trimmingCharacters(in: .whitespacesAndNewlines)
            return title.isEmpty ? nil : title
        } catch {
            logger.debug("Failed to get pane title for \(sessionName): \(error.localizedDescription)")
            return nil
        }
    }

    /// Returns the current working directory of the active pane.
    func getPaneCurrentPath(sessionName: String) async -> String? {
        do {
            let output = try await runTmux(args: [
                "display-message", "-t", sessionName, "-p", "#{pane_current_path}",
            ])
            let path = output.trimmingCharacters(in: .whitespacesAndNewlines)
            return path.isEmpty ? nil : path
        } catch {
            logger.debug("Failed to get pane path for \(sessionName): \(error.localizedDescription)")
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
