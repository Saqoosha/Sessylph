import Foundation

final class TmuxManager: Sendable {
    static let shared = TmuxManager()
    static let sessionPrefix = "sessylph"

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
            return []
        }
    }

    // MARK: - Private

    private func runTmux(args: [String]) async throws -> String {
        let tmuxPath = try ClaudeCLI.tmuxPath()
        let environment = EnvironmentBuilder.loginEnvironmentDict()

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: tmuxPath)
            process.arguments = args
            process.environment = environment

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            process.terminationHandler = { @Sendable _ in
                let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

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

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}
