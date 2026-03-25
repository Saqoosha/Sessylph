// Sources/Sessylph/Session/CLIProcessManager.swift
import Foundation
import os.log

private let logger = Logger(subsystem: "sh.saqoo.Sessylph", category: "CLIProcessManager")

/// Manages a single claude CLI process for native UI mode.
@MainActor
final class CLIProcessManager {
    nonisolated(unsafe) private var process: Process?
    private let wsServer: WebSocketServer
    let stateMachine = SessionStateMachine()

    /// Unique session ID for this CLI instance.
    let sessionId: String

    var onTerminated: (() -> Void)?
    var onConnected: (() -> Void)?
    var lastError: String?
    private var pendingMessages: [any Encodable & Sendable] = []
    private(set) var isConnected: Bool = false

    init(wsServer: WebSocketServer, sessionId: String = UUID().uuidString) {
        self.wsServer = wsServer
        self.sessionId = sessionId
    }

    deinit {
        process?.terminate()
    }

    /// Launch the claude CLI process pointing at our WebSocket server.
    func launch(directory: URL, options: ClaudeCodeOptions) throws {
        guard stateMachine.state == .idle || stateMachine.state == .terminated else {
            logger.warning("Cannot launch: state is \(self.stateMachine.state.rawValue, privacy: .public)")
            return
        }

        stateMachine.transition(to: .starting)

        let claudePath = try ClaudeCLI.claudePath()
        let sdkUrl = "ws://localhost:\(wsServer.port)/ws/cli/\(sessionId)"
        let args = options.buildSDKArgs(claudePath: claudePath, sdkUrl: sdkUrl, sessionId: sessionId)

        // Register expected connection before spawning
        wsServer.expectConnection(for: sessionId)

        let loginEnv = EnvironmentBuilder.loginEnvironmentDict()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        // Pass working directory via cd in the command, not via currentDirectoryURL (TCC mitigation)
        let cdPrefix = "cd \(shellQuote(directory.path)) && "
        process.arguments = ["-l", "-c", cdPrefix + args.map { shellQuote($0) }.joined(separator: " ")]
        process.currentDirectoryURL = URL(fileURLWithPath: NSTemporaryDirectory())
        process.environment = loginEnv

        // Capture stderr for error diagnosis
        let errorPipe = Pipe()
        process.standardError = errorPipe

        process.terminationHandler = { [weak self] proc in
            // Read stderr on termination
            let stderrData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let stderrStr = String(data: stderrData, encoding: .utf8) ?? ""

            Task { @MainActor [weak self] in
                guard let self else { return }
                let code = proc.terminationStatus
                if code != 0 {
                    logger.warning("Claude CLI exited with code \(code)")
                    if !stderrStr.isEmpty {
                        logger.error("CLI stderr: \(stderrStr, privacy: .public)")
                    }
                    self.lastError = String(stderrStr.prefix(500))
                }
                self.stateMachine.handleTerminated()
                self.onTerminated?()
            }
        }

        do {
            try process.run()
        } catch {
            wsServer.removeExpectedConnection(for: sessionId)
            stateMachine.handleError(error.localizedDescription)
            throw error
        }
        self.process = process
        stateMachine.transition(to: .initializing)
        logger.info("Launched claude CLI (PID \(process.processIdentifier)) with --sdk-url \(sdkUrl, privacy: .public)")
        logger.info("Command: \(cdPrefix + args.map { shellQuote($0) }.joined(separator: " "), privacy: .public)")
    }

    /// Called when the WebSocket connection is established.
    func markConnected() {
        isConnected = true
        onConnected?()
        // Flush any messages queued before connection
        for msg in pendingMessages {
            wsServer.send(msg, to: sessionId)
        }
        if !pendingMessages.isEmpty {
            logger.info("Flushed \(self.pendingMessages.count) queued messages")
            stateMachine.transition(to: .streaming)
        }
        pendingMessages.removeAll()
    }

    /// Send a user message to the CLI. Queues if not yet connected.
    func sendUserMessage(_ text: String) {
        let message = UserMessage(
            type: "user",
            message: UserContent(role: "user", content: .text(text)),
            parentToolUseId: nil,
            sessionId: sessionId
        )
        if isConnected {
            wsServer.send(message, to: sessionId)
            stateMachine.transition(to: .streaming)
        } else {
            pendingMessages.append(message)
            logger.info("Queued message (not connected yet)")
        }
    }

    /// Send a user message with an image attachment to the CLI.
    func sendUserMessageWithImage(_ text: String?, imageData: Data, mediaType: String) {
        var blocks: [UserContentBlock] = []
        if let text, !text.isEmpty {
            blocks.append(UserContentBlock(type: "text", text: text, source: nil))
        }
        blocks.append(UserContentBlock(
            type: "image",
            text: nil,
            source: ImageSource(
                type: "base64",
                mediaType: mediaType,
                data: imageData.base64EncodedString()
            )
        ))
        let message = UserMessage(
            type: "user",
            message: UserContent(role: "user", content: .blocks(blocks)),
            parentToolUseId: nil,
            sessionId: sessionId
        )
        if isConnected {
            wsServer.send(message, to: sessionId)
            stateMachine.transition(to: .streaming)
        } else {
            pendingMessages.append(message)
            logger.info("Queued image message (not connected yet)")
        }
    }

    /// Allow a pending tool use.
    func allowTool(requestId: String, permissions: [PermissionSuggestion]? = nil) {
        let response = ControlResponse(
            type: "control_response",
            response: ControlResponseBody(
                subtype: "success",
                requestId: requestId,
                response: ControlResponsePayload(
                    behavior: "allow",
                    updatedInput: nil,
                    updatedPermissions: permissions,
                    message: nil
                )
            )
        )
        wsServer.send(response, to: sessionId)
        stateMachine.handlePermissionResolved()
    }

    /// Deny a pending tool use.
    func denyTool(requestId: String, reason: String? = nil) {
        let response = ControlResponse(
            type: "control_response",
            response: ControlResponseBody(
                subtype: "success",
                requestId: requestId,
                response: ControlResponsePayload(
                    behavior: "deny",
                    updatedInput: nil,
                    updatedPermissions: nil,
                    message: reason ?? "Denied by user"
                )
            )
        )
        wsServer.send(response, to: sessionId)
        stateMachine.handlePermissionResolved()
    }

    /// Interrupt the current operation (Escape).
    func interrupt() {
        let req = InterruptRequest()
        wsServer.send(req, to: sessionId)
    }

    /// Terminate the CLI process.
    func terminate() {
        process?.terminate()
        process = nil
    }

    /// Check if the CLI process is running.
    var isRunning: Bool {
        process?.isRunning ?? false
    }
}
