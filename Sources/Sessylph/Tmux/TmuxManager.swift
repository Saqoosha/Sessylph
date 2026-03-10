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
    func configureSession(name: String, remoteHost: RemoteHost? = nil) async {
        if remoteHost != nil {
            // Remote: run each set-option separately to avoid shell escaping issues
            let t = "=\(name)"
            let commands: [[String]] = [
                ["set-option", "-t", t, "set-titles", "on"],
                ["set-option", "-t", t, "set-titles-string", "#{pane_title}"],
                ["set-option", "-t", t, "allow-passthrough", "on"],
                ["set-window-option", "-t", t, "allow-rename", "on"],
                ["set-option", "-t", t, "mouse", "off"],
                ["set-option", "-s", "extended-keys", "on"],
                ["set-option", "-g", "window-size", "latest"],
                ["set-option", "-g", "mouse", "off"],
            ]
            for cmd in commands {
                _ = try? await runTmux(args: cmd, remoteHost: remoteHost)
            }
        } else {
            let t = "=\(name)"
            _ = try? await runTmux(args: [
                "set-option", "-t", t, "set-titles", "on",
                ";", "set-option", "-t", t, "set-titles-string", "#{pane_title}",
                ";", "set-option", "-t", t, "allow-passthrough", "on",
                ";", "set-window-option", "-t", t, "allow-rename", "on",
                ";", "set-option", "-t", t, "mouse", "off",
            ] + Self.serverOptions)
        }
    }

    /// Creates a tmux session, configures it for title passthrough, and launches
    /// Claude — all in a single process spawn to minimize startup latency.
    ///
    /// Replaces the previous sequence of `createSession` + `configureSession` +
    /// `launchClaude` which required 6 separate process spawns.
    func createAndLaunchSession(
        name: String,
        directory: URL,
        command: String,
        remoteHost: RemoteHost? = nil
    ) async throws {
        if remoteHost != nil {
            // Remote: avoid tmux batch commands (semicolons get mangled by SSH shell).
            // Use separate SSH invocations instead.
            _ = try await runTmux(args: [
                "new-session", "-d", "-s", name, "-c", directory.path,
            ], remoteHost: remoteHost)

            // Configure session (best-effort)
            await configureSession(name: name, remoteHost: remoteHost)

            // Launch command
            _ = try await runTmux(args: [
                "send-keys", "-t", name, command, "Enter",
            ], remoteHost: remoteHost)
        } else {
            // Local: use batched tmux commands for minimal latency.
            // NOTE: Do NOT use "=" prefix for -t targets within the same batch as
            // new-session. tmux's batch parser cannot resolve "=name" for a session
            // that was just created in the same invocation.
            do {
                _ = try await runTmux(args: [
                    "new-session", "-d", "-s", name, "-c", directory.path,
                    ";", "set-option", "-t", name, "set-titles", "on",
                    ";", "set-option", "-t", name, "set-titles-string", "#{pane_title}",
                    ";", "set-option", "-t", name, "allow-passthrough", "on",
                    ";", "set-option", "-t", name, "mouse", "off",
                ] + Self.serverOptions + [
                    ";", "send-keys", "-t", name, command, "Enter",
                ])
            } catch {
                guard await sessionExists(name: name) else {
                    throw error
                }
                logger.info("Session \(name) created (some tmux options may not be supported)")
            }
        }
    }

    /// Renames a tmux session. Best-effort: returns false on failure.
    func renameSession(from oldName: String, to newName: String, remoteHost: RemoteHost? = nil) async -> Bool {
        guard oldName != newName else { return true }
        do {
            _ = try await runTmux(args: [
                "rename-session", "-t", "=\(oldName)", newName,
            ], remoteHost: remoteHost)
            return true
        } catch {
            logger.debug("Failed to rename session \(oldName) → \(newName): \(error.localizedDescription)")
            return false
        }
    }

    /// Kills a session.
    /// `tmux kill-session -t {name}`
    func killSession(name: String, remoteHost: RemoteHost? = nil) async throws {
        _ = try await runTmux(args: [
            "kill-session", "-t", "=\(name)",
        ], remoteHost: remoteHost)
    }

    /// Checks if session exists.
    /// `tmux has-session -t {name}`
    func sessionExists(name: String, remoteHost: RemoteHost? = nil) async -> Bool {
        do {
            _ = try await runTmux(args: ["has-session", "-t", "=\(name)"], remoteHost: remoteHost)
            return true
        } catch {
            logger.debug("Session \(name) does not exist (or tmux error): \(error.localizedDescription)")
            return false
        }
    }

    /// Lists all sessylph-* sessions.
    func listSessylphSessions(remoteHost: RemoteHost? = nil) async -> [String] {
        do {
            let output = try await runTmux(args: [
                "list-sessions", "-F", "#{session_name}",
            ], remoteHost: remoteHost)
            return output
                .components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { $0.contains(Self.sessionPrefix + "-") }
        } catch {
            logger.warning("Failed to list tmux sessions: \(error.localizedDescription)")
            return []
        }
    }

    /// Lists ALL tmux sessions on the remote host (not just sessylph-prefixed).
    /// Used for attaching to arbitrary remote tmux sessions.
    func listAllSessions(remoteHost: RemoteHost) async -> [(name: String, windows: Int, created: String)] {
        do {
            let output = try await runTmux(args: [
                "list-sessions", "-F", "#{session_name}\t#{session_windows}\t#{session_created_string}",
            ], remoteHost: remoteHost)
            return output
                .components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .compactMap { line -> (name: String, windows: Int, created: String)? in
                    let parts = line.components(separatedBy: "\t")
                    guard let name = parts.first, !name.isEmpty else { return nil }
                    return (
                        name: name,
                        windows: parts.count > 1 ? (Int(parts[1]) ?? 1) : 1,
                        created: parts.count > 2 ? parts[2] : ""
                    )
                }
        } catch {
            logger.warning("Failed to list remote tmux sessions: \(error.localizedDescription)")
            return []
        }
    }

    /// Returns the current pane title for the given session.
    func getPaneTitle(sessionName: String, remoteHost: RemoteHost? = nil) async -> String? {
        do {
            // Remote tmux may not support `=` prefix for exact-match targets
            let target = remoteHost != nil ? sessionName : "=\(sessionName)"
            let output = try await runTmux(args: [
                "display-message", "-t", target, "-p", "#{pane_title}",
            ], remoteHost: remoteHost)
            let title = output.trimmingCharacters(in: .whitespacesAndNewlines)
            return title.isEmpty ? nil : title
        } catch {
            logger.debug("Failed to get pane title for \(sessionName): \(error.localizedDescription)")
            return nil
        }
    }

    /// Returns the current working directory of the active pane.
    func getPaneCurrentPath(sessionName: String, remoteHost: RemoteHost? = nil) async -> String? {
        do {
            let target = remoteHost != nil ? sessionName : "=\(sessionName)"
            let output = try await runTmux(args: [
                "display-message", "-t", target, "-p", "#{pane_current_path}",
            ], remoteHost: remoteHost)
            let path = output.trimmingCharacters(in: .whitespacesAndNewlines)
            return path.isEmpty ? nil : path
        } catch {
            logger.debug("Failed to get pane path for \(sessionName): \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - SSH Connection Testing

    /// Tests SSH connectivity to a remote host. Returns true if successful.
    func testSSHConnection(remoteHost: RemoteHost) async -> Bool {
        let sshPath = "/usr/bin/ssh"
        var args = remoteHost.sshArgs
        args.append("echo")
        args.append("ok")

        let finalArgs = args
        return await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: sshPath)
                process.arguments = finalArgs
                process.currentDirectoryURL = URL(fileURLWithPath: NSTemporaryDirectory())
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice

                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: false)
                    return
                }
                process.waitUntilExit()
                continuation.resume(returning: process.terminationStatus == 0)
            }
        }
    }

    // MARK: - Private

    private func runTmux(args: [String], remoteHost: RemoteHost? = nil) async throws -> String {
        if let remoteHost {
            return try await runRemoteTmux(remoteHost: remoteHost, args: args)
        }

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

    private func runRemoteTmux(remoteHost: RemoteHost, args: [String]) async throws -> String {
        let sshPath = "/usr/bin/ssh"
        // SSH concatenates remote command args with spaces and passes to remote shell.
        // tmux batch separators (";") would be interpreted by the remote shell,
        // so we must shell-quote each arg and join into a single command string.
        let remoteCommand = (["tmux"] + args).map { arg in
            // Don't quote simple args, but always quote ";" and args with spaces/special chars
            if arg == ";" {
                return "\\;"
            }
            if arg.rangeOfCharacter(from: .init(charactersIn: " \t'\"\\$`!#&|(){}[]<>?*~")) != nil {
                return "'" + arg.replacingOccurrences(of: "'", with: "'\\''") + "'"
            }
            return arg
        }.joined(separator: " ")
        let sshFullArgs = remoteHost.sshArgs + [remoteCommand]

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            DispatchQueue.global().async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: sshPath)
                process.arguments = sshFullArgs
                process.currentDirectoryURL = URL(fileURLWithPath: NSTemporaryDirectory())
                // Don't set environment for SSH — use system default

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
