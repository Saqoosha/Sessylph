// Sources/Sessylph/ChatUI/ChatViewController.swift
import AppKit
import SwiftUI
import os.log

private let logger = Logger(subsystem: "sh.saqoo.Sessylph", category: "ChatViewController")

protocol ChatViewControllerDelegate: AnyObject {
    @MainActor func chatDidComplete(sessionId: String)
    @MainActor func chatDidTerminate()
    @MainActor func chatTitleDidChange(_ title: String)
    @MainActor func chatStateDidChange(isWorking: Bool)
}

@MainActor
final class ChatViewController: NSHostingController<ChatView> {

    weak var delegate: ChatViewControllerDelegate?
    let processManager: CLIProcessManager
    private let viewModel = ChatViewModel()
    private let wsServer: WebSocketServer

    init(wsServer: WebSocketServer, session: Session) {
        let sessionId = UUID().uuidString
        self.wsServer = wsServer
        self.processManager = CLIProcessManager(wsServer: wsServer, sessionId: sessionId)

        let placeholder = ChatView(
            viewModel: ChatViewModel(),
            onSend: { _ in },
            onAllow: { _, _ in },
            onDeny: { _, _ in },
            onInterrupt: {}
        )
        super.init(rootView: placeholder)

        // Re-create with actual bindings
        self.rootView = ChatView(
            viewModel: viewModel,
            onSend: { [weak self] text in self?.handleSend(text) },
            onImageDrop: { [weak self] data, mediaType in self?.handleImageDrop(data, mediaType: mediaType) },
            onAllow: { [weak self] reqId, perms in self?.processManager.allowTool(requestId: reqId, permissions: perms) },
            onDeny: { [weak self] reqId, reason in self?.processManager.denyTool(requestId: reqId, reason: reason) },
            onInterrupt: { [weak self] in self?.processManager.interrupt() }
        )

        setupMessageHandling()
        setupProcessCallbacks(session: session)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Launch the CLI process for a local session.
    func launch(directory: URL, options: ClaudeCodeOptions) {
        do {
            try processManager.launch(directory: directory, options: options)
        } catch {
            logger.error("Failed to launch CLI: \(error.localizedDescription, privacy: .public)")
            viewModel.addSystemEvent("Failed to launch: \(error.localizedDescription)")
        }
    }

    /// Launch the CLI process on a remote host via SSH reverse tunnel.
    func launchRemote(host: RemoteHost, directory: String, options: ClaudeCodeOptions) {
        let remote = RemoteCLIManager(wsServer: wsServer, remoteHost: host, sessionId: processManager.sessionId)
        remote.onTerminated = { [weak self] in
            self?.viewModel.addSystemEvent("Remote session ended.")
            self?.delegate?.chatDidTerminate()
        }
        self.remoteCLIManager = remote
        do {
            try remote.launch(directory: directory, options: options)
        } catch {
            wsServer.removeExpectedConnection(for: processManager.sessionId)
            logger.error("Failed to launch remote CLI: \(error.localizedDescription, privacy: .public)")
            viewModel.addSystemEvent("Failed to launch remote: \(error.localizedDescription)")
        }
    }

    private var remoteCLIManager: RemoteCLIManager?

    // MARK: - Private

    private func setupMessageHandling() {
        let sessionId = processManager.sessionId
        wsServer.registerSession(
            sessionId,
            onMessage: { [weak self] message in
                self?.handleMessage(message)
            },
            onConnect: { [weak self] in
                guard let self else { return }
                let isFirstConnect = !self.processManager.isConnected && self.viewModel.messages.isEmpty
                self.processManager.markConnected()  // Also flushes queued messages
                self.viewModel.isConnected = true
                if isFirstConnect {
                    self.viewModel.addSystemEvent("Connected to Claude Code")
                }
            },
            onDisconnect: { [weak self] in
                guard let self else { return }
                self.processManager.isConnected = false
                self.viewModel.isConnected = false
                logger.info("WebSocket disconnected, messages will be queued until reconnect")
            }
        )
    }

    private func setupProcessCallbacks(session: Session) {
        processManager.onTerminated = { [weak self] in
            guard let self else { return }
            if let error = self.processManager.lastError, !error.isEmpty {
                self.viewModel.addSystemEvent("CLI error: \(error)")
                // Don't auto-close — let user see the error
                logger.error("CLI terminated with error, keeping chat open for diagnosis")
            } else {
                self.viewModel.addSystemEvent("Session ended.")
                self.delegate?.chatDidTerminate()
            }
        }
    }

    private func handleMessage(_ message: StreamMessage) {
        logger.debug("Received message: \(String(describing: message).prefix(100), privacy: .public)")
        switch message {
        case .system(let sys):
            handleSystemMessage(sys)

        case .assistant(let msg):
            viewModel.finalizeAssistantMessage(msg)
            delegate?.chatStateDidChange(isWorking: false)

        case .streamEvent(let evt):
            handleStreamEvent(evt)

        case .controlRequest(let req):
            handleControlRequest(req)

        case .controlCancelRequest:
            viewModel.pendingPermission = nil

        case .result(let result):
            processManager.stateMachine.handleResult(cost: result.totalCostUsd)
            delegate?.chatStateDidChange(isWorking: false)
            if let sessionId = result.sessionId {
                delegate?.chatDidComplete(sessionId: sessionId)
            }

        case .toolProgress(let progress):
            logger.debug("Tool progress: \(progress.toolName ?? "?", privacy: .public) \(progress.elapsedTimeSeconds ?? 0)s")

        case .user:
            break  // Echo-back of our own message, ignore

        case .keepAlive:
            break

        case .unknown:
            break
        }
    }

    private func handleSystemMessage(_ sys: SystemMessage) {
        switch sys.subtype {
        case "init":
            processManager.stateMachine.handleInit(
                sessionId: sys.sessionId ?? processManager.sessionId,
                model: sys.model
            )
            viewModel.sessionInfo = .init(
                model: sys.model,
                cwd: sys.cwd,
                tools: sys.tools ?? [],
                slashCommands: sys.slashCommands ?? []
            )
            logger.info("Session initialized: model=\(sys.model ?? "default", privacy: .public)")

        case "status":
            if sys.status == "compacting" {
                viewModel.addSystemEvent("Compacting context...")
                processManager.stateMachine.transition(to: .compacting)
            }

        default:
            logger.debug("System event: \(sys.subtype, privacy: .public)")
        }
    }

    private func handleStreamEvent(_ evt: StreamEventMessage) {
        delegate?.chatStateDidChange(isWorking: true)

        guard let delta = evt.event.delta else { return }

        switch delta.type {
        case "text_delta":
            if let text = delta.text {
                viewModel.appendStreamDelta(text: text)
            }
        case "thinking_delta":
            if let thinking = delta.thinking {
                viewModel.appendThinkingDelta(text: thinking)
            }
        default:
            break
        }
    }

    private func handleControlRequest(_ req: ControlRequestMessage) {
        guard req.request.subtype == "can_use_tool" else { return }

        processManager.stateMachine.handlePermissionRequest(requestId: req.requestId)
        viewModel.pendingPermission = .init(
            requestId: req.requestId,
            toolName: req.request.toolName ?? "Unknown",
            input: req.request.input,
            description: req.request.description,
            displayName: req.request.displayName,
            suggestions: req.request.permissionSuggestions ?? []
        )
    }

    private func handleSend(_ text: String) {
        viewModel.addUserMessage(text)
        processManager.sendUserMessage(text)
        delegate?.chatStateDidChange(isWorking: true)
    }

    private func handleImageDrop(_ data: Data, mediaType: String) {
        viewModel.addUserImageMessage(thumbnailData: data)
        processManager.sendUserMessageWithImage(nil, imageData: data, mediaType: mediaType)
        delegate?.chatStateDidChange(isWorking: true)
    }
}
