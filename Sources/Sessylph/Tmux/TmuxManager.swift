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

    /// Creates a new detached tmux session.
    /// `tmux new-session -d -s {name} -c {directory}`
    func createSession(name: String, directory: URL) async throws {
        _ = try await runTmux(args: [
            "new-session", "-d",
            "-s", name,
            "-c", directory.path,
        ])
    }

    /// Configures tmux server-level options that only need to be set once
    /// per server lifetime (e.g. extended keys for CSI u / kitty protocol).
    /// Best-effort: failures are logged but don't block session launch.
    func configureServerOptions() async {
        try? await runTmux(args: [
            "set-option", "-s", "extended-keys", "on",
        ])
        try? await runTmux(args: [
            "set-option", "-s", "extended-keys-format", "csi-u",
        ])
        try? await runTmux(args: [
            "set-option", "-sa", "terminal-features", "xterm-256color:extkeys",
        ])
        // Use the latest active client's size (not the smallest), so when
        // multiple clients (e.g. Warp + Sessylph) share a session, switching
        // between them resizes the window to match the active terminal.
        try? await runTmux(args: [
            "set-option", "-g", "window-size", "latest",
        ])
        // Scroll 1 line per mouse wheel event (default is 5)
        for table in ["copy-mode", "copy-mode-vi"] {
            try? await runTmux(args: [
                "bind-key", "-T", table, "WheelUpPane", "send-keys", "-X", "scroll-up",
            ])
            try? await runTmux(args: [
                "bind-key", "-T", table, "WheelDownPane", "send-keys", "-X", "scroll-down",
            ])
        }
    }

    /// Configures a tmux session for title passthrough so terminal title
    /// escape sequences from Claude Code reach the outer terminal (SwiftTerm).
    /// Best-effort: failures are logged but don't block session launch.
    func configureSession(name: String) async {
        // Allow the inner process to set the outer terminal's title
        try? await runTmux(args: [
            "set-option", "-t", name, "set-titles", "on",
        ])
        try? await runTmux(args: [
            "set-option", "-t", name, "set-titles-string", "#{pane_title}",
        ])
        // Allow passthrough of escape sequences (tmux 3.3+, ignore if unsupported)
        try? await runTmux(args: [
            "set-option", "-t", name, "allow-passthrough", "on",
        ])
        // Enable mouse support so scroll wheel events are handled by tmux
        try? await runTmux(args: [
            "set-option", "-t", name, "mouse", "on",
        ])
    }

    /// Sends keys to launch claude in the session.
    /// `tmux send-keys -t {name} 'command' Enter`
    func launchClaude(sessionName: String, command: String) async throws {
        _ = try await runTmux(args: [
            "send-keys", "-t", sessionName,
            command, "Enter",
        ])
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
