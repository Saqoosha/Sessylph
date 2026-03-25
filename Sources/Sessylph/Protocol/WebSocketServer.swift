// Sources/Sessylph/Protocol/WebSocketServer.swift
import Foundation
import Network
import os.log

private let logger = Logger(subsystem: "sh.saqoo.Sessylph", category: "WebSocketServer")

/// Lightweight local WebSocket server for communicating with claude --sdk-url.
/// Each session gets its own path: /ws/cli/{sessionId}
@MainActor
final class WebSocketServer {
    private var listener: NWListener?
    private var connections: [String: NWConnection] = [:]  // sessionId → connection
    private var parsers: [String: NDJSONParser] = [:]  // per-session parser to avoid buffer mixing

    /// Per-session message handlers.
    private var messageHandlers: [String: (StreamMessage) -> Void] = [:]
    /// Per-session connect handlers.
    private var connectHandlers: [String: () -> Void] = [:]
    /// Per-session disconnect handlers.
    private var disconnectHandlers: [String: () -> Void] = [:]

    /// Register handlers for a specific session.
    func registerSession(_ sessionId: String,
                         onMessage: @escaping (StreamMessage) -> Void,
                         onConnect: @escaping () -> Void,
                         onDisconnect: @escaping () -> Void) {
        messageHandlers[sessionId] = onMessage
        connectHandlers[sessionId] = onConnect
        disconnectHandlers[sessionId] = onDisconnect
    }

    /// Unregister handlers for a session.
    func unregisterSession(_ sessionId: String) {
        messageHandlers.removeValue(forKey: sessionId)
        connectHandlers.removeValue(forKey: sessionId)
        disconnectHandlers.removeValue(forKey: sessionId)
    }

    /// The port the server is listening on.
    private(set) var port: UInt16 = 0

    /// Start listening on a random available port.
    func start() throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        // Bind to loopback only — prevent LAN connections
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)

        let wsOptions = NWProtocolWebSocket.Options()
        wsOptions.autoReplyPing = true
        params.defaultProtocolStack.applicationProtocols.insert(wsOptions, at: 0)

        let listener = try NWListener(using: params, on: .any)
        self.listener = listener

        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                if let port = listener.port {
                    Task { @MainActor in
                        self?.port = port.rawValue
                        logger.info("WebSocket server listening on port \(port.rawValue)")
                    }
                }
            case .failed(let error):
                logger.error("WebSocket server failed: \(error.localizedDescription, privacy: .public)")
            default:
                break
            }
        }

        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in
                self?.handleNewConnection(connection)
            }
        }

        listener.start(queue: .main)
    }

    /// Stop the server and close all connections.
    func stop() {
        for (_, connection) in connections {
            connection.cancel()
        }
        connections.removeAll()
        listener?.cancel()
        listener = nil
        port = 0
    }

    /// Send a message to the CLI for a specific session.
    func send(_ message: Encodable & Sendable, to sessionId: String) {
        guard let connection = connections[sessionId] else {
            logger.warning("No connection for session \(sessionId, privacy: .public)")
            return
        }

        do {
            var data = try JSONEncoder().encode(message)
            data.append(UInt8(ascii: "\n"))

            let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
            let context = NWConnection.ContentContext(identifier: "ws", metadata: [metadata])

            connection.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed { error in
                if let error {
                    logger.error("Send error: \(error.localizedDescription, privacy: .public)")
                }
            })
        } catch {
            logger.error("Encode error: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Check if a session has an active CLI connection.
    func isConnected(_ sessionId: String) -> Bool {
        connections[sessionId] != nil
    }

    // MARK: - Private

    private func handleNewConnection(_ connection: NWConnection) {
        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                switch state {
                case .ready:
                    self?.extractSessionId(from: connection) { sessionId in
                        guard let self, let sessionId else {
                            connection.cancel()
                            return
                        }
                        logger.info("CLI connected for session \(sessionId, privacy: .public)")
                        self.connections[sessionId] = connection
                        self.parsers[sessionId] = NDJSONParser()
                        self.connectHandlers[sessionId]?()
                        self.receiveMessages(on: connection, sessionId: sessionId)
                    }
                case .failed(let error):
                    logger.error("Connection failed: \(error.localizedDescription, privacy: .public)")
                case .cancelled:
                    // Connection cancelled — find and clean up the session
                    if let sessionId = self?.connections.first(where: { $0.value === connection })?.key {
                        self?.handleDisconnect(sessionId: sessionId)
                    }
                default:
                    break
                }
            }
        }

        connection.start(queue: .main)
    }

    private func extractSessionId(from connection: NWConnection, completion: @escaping @MainActor (String?) -> Void) {
        // NWListener WebSocket doesn't directly expose the HTTP upgrade path.
        // Use a pending-session queue: pre-register expected sessionIds and match
        // by connection order. Since we control both sides (spawn + listen),
        // this is reliable.

        if let sessionId = pendingSessions.first {
            pendingSessions.removeFirst()
            completion(sessionId)
        } else {
            logger.warning("No pending session for new connection")
            completion(nil)
        }
    }

    // Sessions waiting for a CLI connection
    private var pendingSessions: [String] = []

    /// Register a session ID that we expect a CLI to connect for.
    func expectConnection(for sessionId: String) {
        pendingSessions.append(sessionId)
    }

    /// Remove a pending session (e.g., when CLI launch fails).
    func removeExpectedConnection(for sessionId: String) {
        pendingSessions.removeAll { $0 == sessionId }
    }

    private func receiveMessages(on connection: NWConnection, sessionId: String) {
        connection.receiveMessage { [weak self] content, contentContext, isComplete, error in
            Task { @MainActor in
                guard let self else { return }

                if let error {
                    logger.error("Receive error: \(error.localizedDescription, privacy: .public)")
                    self.handleDisconnect(sessionId: sessionId)
                    return
                }

                // Clean close by remote end
                if isComplete && content == nil {
                    self.handleDisconnect(sessionId: sessionId)
                    return
                }

                if let data = content, let parser = self.parsers[sessionId] {
                    let messages = await parser.parse(data)
                    for message in messages {
                        self.messageHandlers[sessionId]?(message)
                    }
                }

                // Continue receiving
                self.receiveMessages(on: connection, sessionId: sessionId)
            }
        }
    }

    private func handleDisconnect(sessionId: String) {
        connections.removeValue(forKey: sessionId)
        parsers.removeValue(forKey: sessionId)
        disconnectHandlers[sessionId]?()
        logger.info("CLI disconnected for session \(sessionId, privacy: .public)")
    }
}
