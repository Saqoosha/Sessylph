import Foundation
import os.log

private let logger = Logger(subsystem: "sh.saqoo.Sessylph", category: "RemoteCLIManager")

/// Manages a remote Claude Code session via SSH reverse tunnel + --sdk-url.
///
/// Architecture:
/// 1. SSH reverse tunnel: local wsPort ← remote tunnelPort
/// 2. Remote claude --sdk-url ws://localhost:tunnelPort/ws/cli/sessionId
/// 3. NDJSON flows back through tunnel to local WebSocketServer
@MainActor
final class RemoteCLIManager {
    nonisolated(unsafe) private var sshProcess: Process?
    private let wsServer: WebSocketServer
    let sessionId: String
    let remoteHost: RemoteHost

    /// Port on the remote host that tunnels back to our local WS server.
    /// Uses a random high port to avoid conflicts when multiple sessions target the same host.
    private let remoteTunnelPort: UInt16 = UInt16.random(in: 10000...60000)

    var onTerminated: (() -> Void)?
    var lastError: String?

    init(wsServer: WebSocketServer, remoteHost: RemoteHost, sessionId: String = UUID().uuidString) {
        self.wsServer = wsServer
        self.remoteHost = remoteHost
        self.sessionId = sessionId
    }

    deinit {
        sshProcess?.terminate()
    }

    /// Launch remote claude via SSH with reverse tunnel.
    func launch(directory: String, options: ClaudeCodeOptions) throws {
        let sdkUrl = "ws://localhost:\(remoteTunnelPort)/ws/cli/\(sessionId)"

        var remoteArgs = ["claude"]
        remoteArgs += ["--sdk-url", sdkUrl]
        remoteArgs += ["--print", "--output-format", "stream-json"]
        remoteArgs += ["--input-format", "stream-json"]
        remoteArgs += ["--include-partial-messages", "--verbose"]
        if let model = options.model { remoteArgs += ["--model", model] }
        if let permMode = options.permissionMode { remoteArgs += ["--permission-mode", permMode] }
        if let effort = options.effortLevel { remoteArgs += ["--effort", effort] }
        if let resume = options.resumeSessionId { remoteArgs += ["-r", resume] }
        if options.continueSession { remoteArgs += ["-c"] }
        remoteArgs += ["-p", ""]

        let remoteCommand = "cd \(shellEscape(directory)) && " + remoteArgs.map { shellQuote($0) }.joined(separator: " ")

        // Register expected connection before spawning
        wsServer.expectConnection(for: sessionId)

        // SSH with reverse tunnel
        var sshArgs = remoteHost.sshArgs
        sshArgs += ["-R", "\(remoteTunnelPort):localhost:\(wsServer.port)"]
        sshArgs += ["-o", "ExitOnForwardFailure=yes"]
        sshArgs.append(remoteCommand)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = sshArgs
        process.currentDirectoryURL = URL(fileURLWithPath: NSTemporaryDirectory())

        let loginEnv = EnvironmentBuilder.loginEnvironmentDict()
        process.environment = loginEnv

        let errorPipe = Pipe()
        process.standardError = errorPipe

        process.terminationHandler = { [weak self] proc in
            let stderrData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let stderrStr = String(data: stderrData, encoding: .utf8) ?? ""

            Task { @MainActor [weak self] in
                guard let self else { return }
                let code = proc.terminationStatus
                if code != 0 {
                    logger.warning("Remote SSH exited with code \(code)")
                    if !stderrStr.isEmpty {
                        logger.error("SSH stderr: \(stderrStr, privacy: .public)")
                    }
                    self.lastError = String(stderrStr.prefix(500))
                }
                self.onTerminated?()
            }
        }

        try process.run()
        self.sshProcess = process
        logger.info("Launched remote claude via SSH (PID \(process.processIdentifier)) tunnel \(self.remoteTunnelPort)→\(self.wsServer.port)")
    }

    func terminate() {
        sshProcess?.terminate()
        sshProcess = nil
    }

    var isRunning: Bool {
        sshProcess?.isRunning ?? false
    }
}
