# Sessylph v2: Native UI Rendering Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace GhosttyKit terminal rendering with native SwiftUI chat UI that communicates with Claude Code CLI via `--sdk-url` WebSocket protocol (NDJSON), matching the UX quality of Claude Desktop / VS Code extension.

**Architecture:** Sessylph spawns a local WebSocket server, launches `claude --sdk-url ws://localhost:PORT/ws/cli/SESSION_ID --print --output-format stream-json --input-format stream-json`, and renders the structured JSON messages as native SwiftUI views (chat bubbles, tool cards, permission dialogs). Terminal mode (GhosttyKit + tmux) is preserved as fallback for Codex/Cursor Agent which lack `--sdk-url` support.

**Tech Stack:** Swift 6, macOS 15+, AppKit + SwiftUI, Network.framework (NWListener WebSocket server), swift-markdown (Markdown → AttributedString), existing Sessylph infrastructure (tabs, launcher, settings, notifications)

**Reference Implementations:**
- [The Companion](https://github.com/The-Vibe-Company/companion) — `--sdk-url` WebSocket protocol, message types, session state machine
- [ClaudeCodeSDK](https://github.com/jamesrochabrun/ClaudeCodeSDK) — Swift stream-json parsing patterns, message models
- [opcode](https://github.com/winfunc/opcode) — UI design reference (chat, tool cards, diff view)

**Key Constraint:** `--sdk-url` is a hidden flag in Claude Code CLI v2.1.83+. It is NOT available in Codex or Cursor Agent CLIs. Terminal mode MUST be preserved for non-Claude Code sessions.

---

## Scope & Phasing

This plan covers **Phase 1: Minimum Viable Native UI** — enough to replace terminal mode for Claude Code local sessions with a working chat interface, tool cards, and permission handling.

**Phase 1 (this plan):**
- WebSocket server + NDJSON protocol
- Message models
- CLI process manager
- Chat view with streaming Markdown
- Tool call cards (collapsible, with IN/OUT grid — matching VS Code extension pattern)
- Permission banner (inline, not modal — matching VS Code extension UX)
- Session create/resume
- Integration with existing tabs, launcher, notifications
- Image paste / drag-drop into chat (base64 in UserMessage content blocks)
- Remote SSH via reverse tunnel (`ssh -R`)
- Slash command suggestions (from `system/init` `slash_commands[]` + existing CommandStrip)
- Read coalescing (group sequential Read tool calls into one card)

**Phase 2 (separate plan, later):**
- Diff viewer (inline, side-by-side)
- Cost/usage dashboard
- Sub-agent nesting (parent_tool_use_id tree rendering)
- Multiple rendering modes (compact, detailed)
- Context compaction indicator

---

## File Structure

### New Files (Phase 1)

```
Sources/Sessylph/
├── Protocol/                          # WebSocket + NDJSON protocol layer
│   ├── WebSocketServer.swift          # NWListener-based WS server
│   ├── NDJSONParser.swift             # Line-based JSON stream parser
│   └── StreamMessage.swift            # All NDJSON message type models
│
├── ChatUI/                            # Native SwiftUI chat rendering
│   ├── ChatViewController.swift       # NSHostingController wrapper (replaces TerminalViewController for native mode)
│   ├── ChatView.swift                 # Main chat layout (message feed + input)
│   ├── MessageBubble.swift            # Single message (assistant/user/system)
│   ├── MarkdownText.swift             # Markdown → AttributedString renderer
│   ├── ToolCallCard.swift             # Collapsible tool invocation card
│   ├── ToolResultView.swift           # Tool result rendering (code blocks, diffs)
│   ├── StreamingTextView.swift        # Real-time text accumulation during streaming
│   ├── PermissionBanner.swift         # Tool permission allow/deny UI
│   └── ChatInputView.swift            # User prompt input + send button
│
├── Session/                           # Claude Code process lifecycle
│   ├── CLIProcessManager.swift        # Spawn, monitor, restart claude process
│   ├── SessionStateMachine.swift      # State transitions (starting → ready → streaming → ...)
│   └── NativeSession.swift            # Session model for native UI mode (parallel to terminal Session)
```

### Modified Files

```
Sources/Sessylph/
├── Models/
│   ├── Session.swift                  # Add renderingMode: .terminal | .nativeUI
│   ├── LaunchConfig.swift             # Add .claudeCodeNative case
│   └── ClaudeCodeOptions.swift        # Add buildSDKCommand() method
│
├── Tabs/
│   ├── TabWindowController.swift      # Switch between TerminalVC / ChatVC based on renderingMode
│   └── ClaudeStateTracker.swift       # Add protocol-driven state (from StreamMessage events)
│
├── Launcher/
│   └── LauncherView.swift             # Add "Native UI" toggle for Claude Code launches
│
├── Settings/
│   └── GeneralSettingsView.swift      # Add default rendering mode preference
│
├── App/
│   └── AppDelegate.swift              # Initialize WebSocketServer singleton
│
└── project.yml                        # Add swift-markdown dependency
```

### Untouched Files (all reusable as-is)

All Terminal/ files (GhosttyTerminalView, GhosttyApp, GhosttyConfig, GhosttyInputHandler) remain for fallback terminal mode. All Utilities/, Notifications/, Models/ (except noted above), Settings/ (except noted) stay unchanged.

---

## Task 1: NDJSON Message Models

**Goal:** Define all Swift types for the `--sdk-url` WebSocket protocol messages.

**Files:**
- Create: `Sources/Sessylph/Protocol/StreamMessage.swift`

- [ ] **Step 1: Create the StreamMessage enum and supporting types**

```swift
// Sources/Sessylph/Protocol/StreamMessage.swift
import Foundation

// MARK: - Top-level message envelope

enum StreamMessage: Sendable {
    case system(SystemMessage)
    case assistant(AssistantMessage)
    case user(UserMessage)
    case streamEvent(StreamEventMessage)
    case result(ResultMessage)
    case controlRequest(ControlRequestMessage)
    case controlCancelRequest(ControlCancelRequestMessage)
    case toolProgress(ToolProgressMessage)
    case keepAlive
    case unknown(type: String, raw: Data)
}

// MARK: - System Messages

struct SystemMessage: Codable, Sendable {
    let type: String  // "system"
    let subtype: String  // "init", "status", "compact_boundary", etc.
    let sessionId: String?

    // init-specific fields
    let model: String?
    let cwd: String?
    let tools: [ToolInfo]?
    let permissionMode: String?
    let claudeCodeVersion: String?
    let mcpServers: [MCPServerInfo]?
    let slashCommands: [SlashCommandInfo]?

    // status-specific
    let status: String?  // "compacting", null

    enum CodingKeys: String, CodingKey {
        case type, subtype
        case sessionId = "session_id"
        case model, cwd, tools
        case permissionMode = "permissionMode"
        case claudeCodeVersion = "claude_code_version"
        case mcpServers = "mcp_servers"
        case slashCommands = "slash_commands"
        case status
    }
}

struct ToolInfo: Codable, Sendable {
    let name: String
    let description: String?
}

struct MCPServerInfo: Codable, Sendable {
    let name: String
    let status: String?
}

struct SlashCommandInfo: Codable, Sendable {
    let name: String
    let description: String?
}

// MARK: - Assistant Message

struct AssistantMessage: Codable, Sendable {
    let type: String
    let sessionId: String?
    let message: AssistantContent
    let parentToolUseId: String?

    enum CodingKeys: String, CodingKey {
        case type
        case sessionId = "session_id"
        case message
        case parentToolUseId = "parent_tool_use_id"
    }
}

struct AssistantContent: Codable, Sendable {
    let role: String  // "assistant"
    let content: [ContentBlock]
}

// MARK: - Content Blocks

enum ContentBlock: Codable, Sendable {
    case text(TextBlock)
    case thinking(ThinkingBlock)
    case toolUse(ToolUseBlock)
    case toolResult(ToolResultBlock)

    enum CodingKeys: String, CodingKey {
        case type
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        let singleContainer = try decoder.singleValueContainer()
        switch type {
        case "text":
            self = .text(try singleContainer.decode(TextBlock.self))
        case "thinking":
            self = .thinking(try singleContainer.decode(ThinkingBlock.self))
        case "tool_use":
            self = .toolUse(try singleContainer.decode(ToolUseBlock.self))
        case "tool_result":
            self = .toolResult(try singleContainer.decode(ToolResultBlock.self))
        default:
            // Treat unknown types as text with raw JSON
            self = .text(TextBlock(type: "text", text: "[unknown block: \(type)]"))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .text(let block): try container.encode(block)
        case .thinking(let block): try container.encode(block)
        case .toolUse(let block): try container.encode(block)
        case .toolResult(let block): try container.encode(block)
        }
    }
}

struct TextBlock: Codable, Sendable {
    let type: String  // "text"
    let text: String
}

struct ThinkingBlock: Codable, Sendable {
    let type: String  // "thinking"
    let thinking: String
}

struct ToolUseBlock: Codable, Sendable {
    let type: String  // "tool_use"
    let id: String
    let name: String
    let input: JSONValue  // flexible JSON

    enum CodingKeys: String, CodingKey {
        case type, id, name, input
    }
}

struct ToolResultBlock: Codable, Sendable {
    let type: String  // "tool_result"
    let toolUseId: String
    let content: String?  // may be string or array
    let isError: Bool?

    enum CodingKeys: String, CodingKey {
        case type
        case toolUseId = "tool_use_id"
        case content
        case isError = "is_error"
    }
}

// MARK: - User Message (outbound)

struct UserMessage: Codable, Sendable {
    let type: String  // "user"
    let message: UserContent
    let parentToolUseId: String?
    let sessionId: String

    enum CodingKeys: String, CodingKey {
        case type, message
        case parentToolUseId = "parent_tool_use_id"
        case sessionId = "session_id"
    }
}

struct UserContent: Codable, Sendable {
    let role: String  // "user"
    let content: UserContentValue
}

enum UserContentValue: Codable, Sendable {
    case text(String)
    case blocks([UserContentBlock])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let text = try? container.decode(String.self) {
            self = .text(text)
        } else {
            self = .blocks(try container.decode([UserContentBlock].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .text(let text): try container.encode(text)
        case .blocks(let blocks): try container.encode(blocks)
        }
    }
}

struct UserContentBlock: Codable, Sendable {
    let type: String
    let text: String?
    let source: ImageSource?
}

struct ImageSource: Codable, Sendable {
    let type: String  // "base64"
    let mediaType: String
    let data: String

    enum CodingKeys: String, CodingKey {
        case type
        case mediaType = "media_type"
        case data
    }
}

// MARK: - Stream Event (partial deltas)

struct StreamEventMessage: Codable, Sendable {
    let type: String  // "stream_event"
    let event: StreamEvent
    let parentToolUseId: String?
    let sessionId: String?

    enum CodingKeys: String, CodingKey {
        case type, event
        case parentToolUseId = "parent_tool_use_id"
        case sessionId = "session_id"
    }
}

struct StreamEvent: Codable, Sendable {
    let type: String  // "content_block_delta", "content_block_start", etc.
    let index: Int?
    let delta: StreamDelta?
    let contentBlock: ContentBlockStart?

    enum CodingKeys: String, CodingKey {
        case type, index, delta
        case contentBlock = "content_block"
    }
}

struct StreamDelta: Codable, Sendable {
    let type: String  // "text_delta", "thinking_delta"
    let text: String?
    let thinking: String?
}

struct ContentBlockStart: Codable, Sendable {
    let type: String  // "text", "thinking", "tool_use"
    let id: String?
    let name: String?
}

// MARK: - Result

struct ResultMessage: Codable, Sendable {
    let type: String  // "result"
    let subtype: String?  // "success", "error"
    let result: String?
    let sessionId: String?
    let totalCostUsd: Double?
    let durationMs: Int?
    let numTurns: Int?
    let isError: Bool?
    let usage: UsageInfo?

    enum CodingKeys: String, CodingKey {
        case type, subtype, result
        case sessionId = "session_id"
        case totalCostUsd = "total_cost_usd"
        case durationMs = "duration_ms"
        case numTurns = "num_turns"
        case isError = "is_error"
        case usage
    }
}

struct UsageInfo: Codable, Sendable {
    let inputTokens: Int?
    let outputTokens: Int?
    let cacheCreationInputTokens: Int?
    let cacheReadInputTokens: Int?

    enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case cacheCreationInputTokens = "cache_creation_input_tokens"
        case cacheReadInputTokens = "cache_read_input_tokens"
    }
}

// MARK: - Control Request (permission)

struct ControlRequestMessage: Codable, Sendable {
    let type: String  // "control_request"
    let requestId: String
    let request: ControlRequest

    enum CodingKeys: String, CodingKey {
        case type
        case requestId = "request_id"
        case request
    }
}

struct ControlRequest: Codable, Sendable {
    let subtype: String  // "can_use_tool"
    let toolName: String?
    let input: JSONValue?
    let toolUseId: String?
    let permissionSuggestions: [PermissionSuggestion]?
    let description: String?
    let title: String?
    let displayName: String?
    let decisionReason: String?

    enum CodingKeys: String, CodingKey {
        case subtype
        case toolName = "tool_name"
        case input
        case toolUseId = "tool_use_id"
        case permissionSuggestions = "permission_suggestions"
        case description, title
        case displayName = "display_name"
        case decisionReason = "decision_reason"
    }
}

struct PermissionSuggestion: Codable, Sendable {
    let destination: String?  // "session"
    let mode: String?  // "allowTool"
    let toolName: String?
}

struct ControlCancelRequestMessage: Codable, Sendable {
    let type: String
    let requestId: String

    enum CodingKeys: String, CodingKey {
        case type
        case requestId = "request_id"
    }
}

// MARK: - Control Response (outbound)

struct ControlResponse: Codable, Sendable {
    let type: String  // "control_response"
    let response: ControlResponseBody
}

struct ControlResponseBody: Codable, Sendable {
    let subtype: String  // "success" | "error"
    let requestId: String
    let response: ControlResponsePayload

    enum CodingKeys: String, CodingKey {
        case subtype
        case requestId = "request_id"
        case response
    }
}

struct ControlResponsePayload: Codable, Sendable {
    let behavior: String  // "allow" | "deny"
    let updatedInput: JSONValue?
    let updatedPermissions: [PermissionSuggestion]?
    let message: String?  // deny reason
}

// MARK: - Tool Progress

struct ToolProgressMessage: Codable, Sendable {
    let type: String  // "tool_progress"
    let toolUseId: String
    let toolName: String?
    let elapsedTimeSeconds: Double?

    enum CodingKeys: String, CodingKey {
        case type
        case toolUseId = "tool_use_id"
        case toolName = "tool_name"
        case elapsedTimeSeconds = "elapsed_time_seconds"
    }
}

// MARK: - Interrupt (outbound)

struct InterruptRequest: Codable, Sendable {
    let type: String  // "control_request"
    let requestId: String
    let request: InterruptBody

    enum CodingKeys: String, CodingKey {
        case type
        case requestId = "request_id"
        case request
    }

    struct InterruptBody: Codable, Sendable {
        let subtype: String  // "interrupt"
    }

    init() {
        type = "control_request"
        requestId = UUID().uuidString
        request = InterruptBody(subtype: "interrupt")
    }
}

// MARK: - JSONValue (flexible JSON)

enum JSONValue: Codable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
        } else if let number = try? container.decode(Double.self) {
            self = .number(number)
        } else if let string = try? container.decode(String.self) {
            self = .string(string)
        } else if let array = try? container.decode([JSONValue].self) {
            self = .array(array)
        } else if let object = try? container.decode([String: JSONValue].self) {
            self = .object(object)
        } else {
            self = .null
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let s): try container.encode(s)
        case .number(let n): try container.encode(n)
        case .bool(let b): try container.encode(b)
        case .object(let o): try container.encode(o)
        case .array(let a): try container.encode(a)
        case .null: try container.encodeNil()
        }
    }
}

extension JSONValue {
    /// Extract a readable summary for display (e.g., tool_use input).
    var displaySummary: String {
        switch self {
        case .string(let s): return s
        case .number(let n): return String(n)
        case .bool(let b): return String(b)
        case .null: return "null"
        case .object(let dict):
            // For tool inputs, extract key fields
            if let command = dict["command"] {
                return command.displaySummary
            }
            if let content = dict["content"] {
                return content.displaySummary
            }
            return "{\(dict.count) fields}"
        case .array(let arr):
            return "[\(arr.count) items]"
        }
    }

    /// Get the string value for a key in a JSON object.
    subscript(key: String) -> JSONValue? {
        guard case .object(let dict) = self else { return nil }
        return dict[key]
    }
}
```

- [ ] **Step 2: Verify it compiles**

Run: `cd /Users/hiko/Documents/repos/Personal/Sessylph && xcodegen generate && xcodebuild -scheme Sessylph -configuration Debug -derivedDataPath build build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
jj describe -m "feat: add NDJSON message models for --sdk-url WebSocket protocol

- Define StreamMessage enum with all message types (system, assistant, stream_event, control_request, result, etc.)
- Add ContentBlock types (text, thinking, tool_use, tool_result)
- Add outbound message types (UserMessage, ControlResponse, InterruptRequest)
- Add JSONValue type for flexible JSON handling
- Reference: The Companion protocol + ClaudeCodeSDK patterns

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>"
```

---

## Task 2: NDJSON Parser

**Goal:** Parse newline-delimited JSON from WebSocket frames into `StreamMessage` values.

**Files:**
- Create: `Sources/Sessylph/Protocol/NDJSONParser.swift`

- [ ] **Step 1: Write NDJSONParser**

```swift
// Sources/Sessylph/Protocol/NDJSONParser.swift
import Foundation
import os.log

private let logger = Logger(subsystem: "sh.saqoo.Sessylph", category: "NDJSONParser")

/// Parses newline-delimited JSON (NDJSON) into StreamMessage values.
/// Handles partial lines across WebSocket frames via internal buffer.
actor NDJSONParser {
    private var buffer = Data()
    private let decoder = JSONDecoder()

    /// Feed raw data (potentially multiple JSON lines or partial lines).
    /// Returns all complete messages parsed from the data.
    func parse(_ data: Data) -> [StreamMessage] {
        buffer.append(data)

        var messages: [StreamMessage] = []
        while let newlineIndex = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            let lineData = buffer[buffer.startIndex..<newlineIndex]
            buffer = Data(buffer[buffer.index(after: newlineIndex)...])

            guard !lineData.isEmpty else { continue }

            if let message = parseLine(Data(lineData)) {
                messages.append(message)
            }
        }
        return messages
    }

    /// Parse a single complete JSON line into a StreamMessage.
    private func parseLine(_ data: Data) -> StreamMessage? {
        // Peek at the type field first
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String
        else {
            logger.warning("Failed to parse JSON line: \(String(data: data, encoding: .utf8) ?? "<binary>", privacy: .public)")
            return nil
        }

        do {
            switch type {
            case "system":
                return .system(try decoder.decode(SystemMessage.self, from: data))
            case "assistant":
                return .assistant(try decoder.decode(AssistantMessage.self, from: data))
            case "user":
                // User message echo-back — usually ignored
                return nil
            case "stream_event":
                return .streamEvent(try decoder.decode(StreamEventMessage.self, from: data))
            case "result":
                return .result(try decoder.decode(ResultMessage.self, from: data))
            case "control_request":
                return .controlRequest(try decoder.decode(ControlRequestMessage.self, from: data))
            case "control_cancel_request":
                return .controlCancelRequest(try decoder.decode(ControlCancelRequestMessage.self, from: data))
            case "tool_progress":
                return .toolProgress(try decoder.decode(ToolProgressMessage.self, from: data))
            case "keep_alive":
                return .keepAlive
            default:
                logger.debug("Unknown message type: \(type, privacy: .public)")
                return .unknown(type: type, raw: data)
            }
        } catch {
            logger.error("Decode error for type '\(type, privacy: .public)': \(error.localizedDescription, privacy: .public)")
            return .unknown(type: type, raw: data)
        }
    }

    /// Flush any remaining buffered data (call when connection closes).
    func flush() -> [StreamMessage] {
        guard !buffer.isEmpty else { return [] }
        let remaining = buffer
        buffer = Data()
        if let message = parseLine(remaining) {
            return [message]
        }
        return []
    }
}
```

- [ ] **Step 2: Verify it compiles**

Run: `cd /Users/hiko/Documents/repos/Personal/Sessylph && xcodegen generate && xcodebuild -scheme Sessylph -configuration Debug -derivedDataPath build build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
jj describe -m "feat: add NDJSON parser for WebSocket stream

- Actor-based parser with internal buffer for partial lines
- Type-peeking via JSONSerialization before full Codable decode
- Handles buffer flush on connection close

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>"
```

---

## Task 3: WebSocket Server

**Goal:** Local WebSocket server using Network.framework that accepts connections from `claude --sdk-url`.

**Files:**
- Create: `Sources/Sessylph/Protocol/WebSocketServer.swift`

- [ ] **Step 1: Write WebSocketServer**

```swift
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
    private let parser = NDJSONParser()

    /// Callback when a message is received for a session.
    var onMessage: ((String, StreamMessage) -> Void)?  // (sessionId, message)

    /// Callback when a CLI connects for a session.
    var onConnect: ((String) -> Void)?  // sessionId

    /// Callback when a CLI disconnects.
    var onDisconnect: ((String) -> Void)?  // sessionId

    /// The port the server is listening on.
    private(set) var port: UInt16 = 0

    /// Start listening on a random available port.
    func start() throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true

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
        // Extract session ID from the HTTP upgrade path
        // The path format is /ws/cli/{sessionId}
        // We'll extract it from the WebSocket metadata after handshake

        // For now, we accept and match by the first metadata we get
        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                switch state {
                case .ready:
                    // Parse session ID from connection path
                    self?.extractSessionId(from: connection) { sessionId in
                        guard let self, let sessionId else {
                            connection.cancel()
                            return
                        }
                        logger.info("CLI connected for session \(sessionId, privacy: .public)")
                        self.connections[sessionId] = connection
                        self.onConnect?(sessionId)
                        self.receiveMessages(on: connection, sessionId: sessionId)
                    }
                case .failed(let error):
                    logger.error("Connection failed: \(error.localizedDescription, privacy: .public)")
                case .cancelled:
                    break
                default:
                    break
                }
            }
        }

        connection.start(queue: .main)
    }

    private func extractSessionId(from connection: NWConnection, completion: @escaping @MainActor (String?) -> Void) {
        // Read the first WebSocket frame to extract the session path
        // The NWListener WebSocket doesn't directly expose the HTTP upgrade path.
        // Workaround: use a mapping of port → sessionId, or encode sessionId
        // in the first message.
        //
        // Simpler approach: pre-register expected sessionIds and match by
        // connection order. Since we control both sides (spawn + listen),
        // we can use a pending-session queue.
        //
        // For v1: use the pendingSessions queue approach.

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

    private func receiveMessages(on connection: NWConnection, sessionId: String) {
        connection.receiveMessage { [weak self] content, contentContext, _, error in
            Task { @MainActor in
                guard let self else { return }

                if let error {
                    logger.error("Receive error: \(error.localizedDescription, privacy: .public)")
                    self.handleDisconnect(sessionId: sessionId)
                    return
                }

                if let data = content {
                    let messages = await self.parser.parse(data)
                    for message in messages {
                        self.onMessage?(sessionId, message)
                    }
                }

                // Continue receiving
                self.receiveMessages(on: connection, sessionId: sessionId)
            }
        }
    }

    private func handleDisconnect(sessionId: String) {
        connections.removeValue(forKey: sessionId)
        onDisconnect?(sessionId)
        logger.info("CLI disconnected for session \(sessionId, privacy: .public)")
    }
}
```

- [ ] **Step 2: Verify it compiles**

Run: `cd /Users/hiko/Documents/repos/Personal/Sessylph && xcodegen generate && xcodebuild -scheme Sessylph -configuration Debug -derivedDataPath build build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
jj describe -m "feat: add WebSocket server for claude --sdk-url protocol

- NWListener-based local WebSocket server (Network.framework)
- Session-keyed connection management
- NDJSON send/receive with parser integration
- Pending session queue for connection matching

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>"
```

---

## Task 4: CLI Process Manager

**Goal:** Spawn, monitor, and manage the `claude` CLI process with `--sdk-url`.

**Files:**
- Create: `Sources/Sessylph/Session/CLIProcessManager.swift`
- Create: `Sources/Sessylph/Session/SessionStateMachine.swift`
- Modify: `Sources/Sessylph/Models/ClaudeCodeOptions.swift` — add `buildSDKArgs()`

- [ ] **Step 1: Add buildSDKArgs to ClaudeCodeOptions**

Add after the existing `buildCommand()` method in `Sources/Sessylph/Models/ClaudeCodeOptions.swift`:

```swift
/// Builds CLI arguments for --sdk-url mode (headless/native UI).
/// Returns an array of arguments (not a shell command string).
func buildSDKArgs(claudePath: String, sdkUrl: String, sessionId: String) -> [String] {
    var args: [String] = [
        claudePath,
        "--print",
        "--sdk-url", sdkUrl,
        "--session-id", sessionId,
        "--output-format", "stream-json",
        "--input-format", "stream-json",
        "--include-partial-messages",
        "--verbose",
    ]

    if let model {
        args += ["--model", model]
    }
    if let permissionMode {
        args += ["--permission-mode", permissionMode]
    }
    if let allowedTools, !allowedTools.isEmpty {
        for tool in allowedTools {
            args += ["--allowedTools", tool]
        }
    }
    if let disallowedTools, !disallowedTools.isEmpty {
        for tool in disallowedTools {
            args += ["--disallowedTools", tool]
        }
    }
    if dangerouslySkipPermissions {
        args.append("--dangerously-skip-permissions")
    }
    if continueSession {
        args.append("-c")
    }
    if let resumeSessionId {
        args += ["-r", resumeSessionId]
    }
    if let maxBudgetUSD {
        args += ["--max-budget-usd", String(format: "%.2f", maxBudgetUSD)]
    }
    if let effortLevel {
        args += ["--effort", effortLevel]
    }
    if let systemPrompt {
        args += ["--system-prompt", systemPrompt]
    }
    if let appendSystemPrompt {
        args += ["--append-system-prompt", appendSystemPrompt]
    }
    if let additionalDirs, !additionalDirs.isEmpty {
        for dir in additionalDirs {
            args += ["--add-dir", dir]
        }
    }
    if let mcpConfigs, !mcpConfigs.isEmpty {
        for config in mcpConfigs {
            args += ["--mcp-config", config]
        }
    }
    if let channels, !channels.isEmpty {
        for channel in channels {
            args += ["--channels", channel]
        }
    }
    if bare {
        args.append("--bare")
    }

    // Empty prompt — sdk-url mode ignores it but flag is required
    args += ["-p", ""]

    return args
}
```

- [ ] **Step 2: Write SessionStateMachine**

```swift
// Sources/Sessylph/Session/SessionStateMachine.swift
import Foundation

enum SessionState: String, Sendable {
    case idle            // Not started
    case starting        // CLI process spawning
    case initializing    // Waiting for system/init message
    case ready           // Waiting for user input
    case streaming       // Claude is responding
    case awaitingPermission  // Waiting for user to approve tool use
    case compacting      // Context compaction in progress
    case terminated      // CLI exited (can restart)
    case error           // Unrecoverable error
}

@MainActor
@Observable
final class SessionStateMachine {
    private(set) var state: SessionState = .idle
    private(set) var lastError: String?
    private(set) var sessionId: String?
    private(set) var model: String?
    private(set) var totalCostUsd: Double = 0
    private(set) var pendingPermissionRequestId: String?

    func transition(to newState: SessionState) {
        state = newState
    }

    func handleInit(sessionId: String, model: String?) {
        self.sessionId = sessionId
        self.model = model
        transition(to: .ready)
    }

    func handleResult(cost: Double?) {
        if let cost { totalCostUsd += cost }
        pendingPermissionRequestId = nil
        transition(to: .ready)
    }

    func handlePermissionRequest(requestId: String) {
        pendingPermissionRequestId = requestId
        transition(to: .awaitingPermission)
    }

    func handlePermissionResolved() {
        pendingPermissionRequestId = nil
        transition(to: .streaming)
    }

    func handleError(_ message: String) {
        lastError = message
        transition(to: .error)
    }

    func handleTerminated() {
        transition(to: .terminated)
    }

    func reset() {
        state = .idle
        lastError = nil
        sessionId = nil
        model = nil
        totalCostUsd = 0
        pendingPermissionRequestId = nil
    }
}
```

- [ ] **Step 3: Write CLIProcessManager**

```swift
// Sources/Sessylph/Session/CLIProcessManager.swift
import Foundation
import os.log

private let logger = Logger(subsystem: "sh.saqoo.Sessylph", category: "CLIProcessManager")

/// Manages a single claude CLI process for native UI mode.
@MainActor
final class CLIProcessManager {
    private var process: Process?
    private let wsServer: WebSocketServer
    let stateMachine = SessionStateMachine()

    /// Unique session ID for this CLI instance.
    let sessionId: String

    var onTerminated: (() -> Void)?

    init(wsServer: WebSocketServer, sessionId: String = UUID().uuidString) {
        self.wsServer = wsServer
        self.sessionId = sessionId
    }

    deinit {
        process?.terminate()
    }

    /// Launch the claude CLI process pointing at our WebSocket server.
    func launch(directory: URL, options: ClaudeCodeOptions) async throws {
        guard stateMachine.state == .idle || stateMachine.state == .terminated else {
            logger.warning("Cannot launch: state is \(self.stateMachine.state.rawValue, privacy: .public)")
            return
        }

        stateMachine.transition(to: .starting)

        let claudePath = try await ClaudeCLI.resolvedPath()
        let sdkUrl = "ws://localhost:\(wsServer.port)/ws/cli/\(sessionId)"
        let args = options.buildSDKArgs(claudePath: claudePath, sdkUrl: sdkUrl, sessionId: sessionId)

        // Register expected connection before spawning
        wsServer.expectConnection(for: sessionId)

        let loginEnv = await EnvironmentBuilder.capturedEnvironment()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-l", "-c", args.map { shellQuote($0) }.joined(separator: " ")]
        process.currentDirectoryURL = directory
        process.environment = loginEnv

        // Redirect stderr for debugging
        let errorPipe = Pipe()
        process.standardError = errorPipe

        process.terminationHandler = { [weak self] proc in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let code = proc.terminationStatus
                if code != 0 {
                    logger.warning("Claude CLI exited with code \(code)")
                }
                self.stateMachine.handleTerminated()
                self.onTerminated?()
            }
        }

        try process.run()
        self.process = process
        stateMachine.transition(to: .initializing)
        logger.info("Launched claude CLI (PID \(process.processIdentifier)) with --sdk-url \(sdkUrl, privacy: .public)")
    }

    /// Send a user message to the CLI.
    func sendUserMessage(_ text: String) {
        let message = UserMessage(
            type: "user",
            message: UserContent(role: "user", content: .text(text)),
            parentToolUseId: nil,
            sessionId: sessionId
        )
        wsServer.send(message, to: sessionId)
        stateMachine.transition(to: .streaming)
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
```

- [ ] **Step 4: Verify it compiles**

Run: `cd /Users/hiko/Documents/repos/Personal/Sessylph && xcodegen generate && xcodebuild -scheme Sessylph -configuration Debug -derivedDataPath build build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 5: Commit**

```bash
jj describe -m "feat: add CLI process manager and session state machine

- CLIProcessManager spawns claude with --sdk-url pointed at local WS server
- SessionStateMachine tracks lifecycle (idle → starting → ready → streaming → ...)
- Add buildSDKArgs() to ClaudeCodeOptions for native UI mode
- Handles user message send, tool allow/deny, interrupt, terminate

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>"
```

---

## Task 5: Markdown Rendering

**Goal:** Render Markdown text as styled AttributedString for chat messages.

**Files:**
- Create: `Sources/Sessylph/ChatUI/MarkdownText.swift`
- Modify: `project.yml` — add swift-markdown SPM dependency

- [ ] **Step 1: Add swift-markdown to project.yml**

Add to the `packages` section of `project.yml`:

```yaml
  SwiftMarkdown:
    url: https://github.com/apple/swift-markdown
    from: "0.5.0"
```

And add to the Sessylph target's dependencies:

```yaml
      - package: SwiftMarkdown
        product: Markdown
```

- [ ] **Step 2: Write MarkdownText view**

```swift
// Sources/Sessylph/ChatUI/MarkdownText.swift
import SwiftUI
import Markdown

/// Renders Markdown content as a styled SwiftUI Text view.
struct MarkdownText: View {
    let source: String

    var body: some View {
        Text(parseMarkdown(source))
            .textSelection(.enabled)
    }

    private func parseMarkdown(_ text: String) -> AttributedString {
        do {
            // Use Apple's AttributedString Markdown parser for basic formatting
            var result = try AttributedString(markdown: text, options: .init(
                allowsExtendedAttributes: true,
                interpretedSyntax: .inlineOnlyPreservingWhitespace
            ))
            return result
        } catch {
            return AttributedString(text)
        }
    }
}

/// A code block with syntax highlighting placeholder and copy button.
struct CodeBlockView: View {
    let language: String?
    let code: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let language {
                HStack {
                    Text(language)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(code, forType: .string)
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .background(.quaternary)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(12)
            }
        }
        .background(Color(nsColor: .textBackgroundColor).opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
```

- [ ] **Step 3: Verify it compiles**

Run: `cd /Users/hiko/Documents/repos/Personal/Sessylph && xcodegen generate && xcodebuild -scheme Sessylph -configuration Debug -derivedDataPath build build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 4: Commit**

```bash
jj describe -m "feat: add Markdown renderer for chat messages

- MarkdownText view using AttributedString Markdown parser
- CodeBlockView with language label and copy button
- Add swift-markdown SPM dependency

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>"
```

---

## Task 6: Chat View & Message Rendering

**Goal:** Main SwiftUI chat interface with message feed, streaming text, and user input.

**Files:**
- Create: `Sources/Sessylph/ChatUI/ChatView.swift`
- Create: `Sources/Sessylph/ChatUI/MessageBubble.swift`
- Create: `Sources/Sessylph/ChatUI/StreamingTextView.swift`
- Create: `Sources/Sessylph/ChatUI/ChatInputView.swift`

- [ ] **Step 1: Create the ChatMessage model**

Add to `ChatView.swift` or a separate file — this is the display model for the message feed:

```swift
// Sources/Sessylph/ChatUI/ChatView.swift
import SwiftUI
import os.log

private let logger = Logger(subsystem: "sh.saqoo.Sessylph", category: "ChatView")

// MARK: - Chat Display Model

@MainActor
@Observable
final class ChatViewModel {
    var messages: [ChatMessage] = []
    var streamingText: String = ""
    var streamingThinking: String = ""
    var isStreaming: Bool = false
    var pendingPermission: PendingPermission?
    var sessionInfo: SessionInfo?

    struct SessionInfo {
        let model: String?
        let cwd: String?
        let tools: [ToolInfo]
        let slashCommands: [SlashCommandInfo]
    }

    struct PendingPermission {
        let requestId: String
        let toolName: String
        let input: JSONValue?
        let description: String?
        let displayName: String?
        let suggestions: [PermissionSuggestion]
    }

    // Accumulate streaming deltas
    func appendStreamDelta(text: String) {
        streamingText += text
        isStreaming = true
    }

    func appendThinkingDelta(text: String) {
        streamingThinking += text
        isStreaming = true
    }

    // Finalize an assistant message from accumulated stream + content blocks
    func finalizeAssistantMessage(_ msg: AssistantMessage) {
        let chatMsg = ChatMessage(
            id: UUID().uuidString,
            role: .assistant,
            contentBlocks: msg.message.content,
            parentToolUseId: msg.parentToolUseId,
            timestamp: Date()
        )
        messages.append(chatMsg)
        streamingText = ""
        streamingThinking = ""
        isStreaming = false
    }

    func addUserMessage(_ text: String) {
        let chatMsg = ChatMessage(
            id: UUID().uuidString,
            role: .user,
            contentBlocks: [.text(TextBlock(type: "text", text: text))],
            parentToolUseId: nil,
            timestamp: Date()
        )
        messages.append(chatMsg)
    }

    func addSystemEvent(_ text: String) {
        let chatMsg = ChatMessage(
            id: UUID().uuidString,
            role: .system,
            contentBlocks: [.text(TextBlock(type: "text", text: text))],
            parentToolUseId: nil,
            timestamp: Date()
        )
        messages.append(chatMsg)
    }
}

struct ChatMessage: Identifiable {
    let id: String
    let role: Role
    let contentBlocks: [ContentBlock]
    let parentToolUseId: String?
    let timestamp: Date

    enum Role {
        case user
        case assistant
        case system
    }
}

// MARK: - Chat View

struct ChatView: View {
    let viewModel: ChatViewModel
    let onSend: (String) -> Void
    let onAllow: (String, [PermissionSuggestion]?) -> Void
    let onDeny: (String, String?) -> Void
    let onInterrupt: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Message feed
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(viewModel.messages) { message in
                            MessageBubble(message: message)
                                .id(message.id)
                        }

                        // Streaming text (in-progress)
                        if viewModel.isStreaming {
                            StreamingTextView(
                                text: viewModel.streamingText,
                                thinking: viewModel.streamingThinking
                            )
                            .id("streaming")
                        }

                        // Permission banner
                        if let perm = viewModel.pendingPermission {
                            PermissionBanner(
                                permission: perm,
                                onAllow: { onAllow(perm.requestId, perm.suggestions) },
                                onDeny: { onDeny(perm.requestId, nil) }
                            )
                            .id("permission")
                        }
                    }
                    .padding()
                }
                .onChange(of: viewModel.messages.count) {
                    withAnimation {
                        proxy.scrollTo(viewModel.messages.last?.id, anchor: .bottom)
                    }
                }
                .onChange(of: viewModel.streamingText) {
                    proxy.scrollTo("streaming", anchor: .bottom)
                }
            }

            Divider()

            // Input area
            ChatInputView(
                onSend: onSend,
                onInterrupt: onInterrupt,
                isStreaming: viewModel.isStreaming
            )
        }
    }
}
```

- [ ] **Step 2: Create MessageBubble**

```swift
// Sources/Sessylph/ChatUI/MessageBubble.swift
import SwiftUI

struct MessageBubble: View {
    let message: ChatMessage

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Role header
            HStack {
                switch message.role {
                case .user:
                    Image(systemName: "person.fill")
                    Text("You")
                        .fontWeight(.semibold)
                case .assistant:
                    Image(systemName: "sparkle")
                    Text("Claude")
                        .fontWeight(.semibold)
                case .system:
                    Image(systemName: "info.circle")
                    Text("System")
                        .fontWeight(.semibold)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(message.timestamp, style: .time)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            // Content blocks
            ForEach(Array(message.contentBlocks.enumerated()), id: \.offset) { _, block in
                contentView(for: block)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func contentView(for block: ContentBlock) -> some View {
        switch block {
        case .text(let textBlock):
            MarkdownText(source: textBlock.text)

        case .thinking(let thinkingBlock):
            DisclosureGroup("Thinking") {
                Text(thinkingBlock.thinking)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .padding(8)
            .background(.quaternary)
            .clipShape(RoundedRectangle(cornerRadius: 8))

        case .toolUse(let toolUse):
            ToolCallCard(toolUse: toolUse)

        case .toolResult(let toolResult):
            ToolResultView(result: toolResult)
        }
    }
}
```

- [ ] **Step 3: Create StreamingTextView**

```swift
// Sources/Sessylph/ChatUI/StreamingTextView.swift
import SwiftUI

struct StreamingTextView: View {
    let text: String
    let thinking: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "sparkle")
                Text("Claude")
                    .fontWeight(.semibold)
                ProgressView()
                    .controlSize(.small)
                Spacer()
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if !thinking.isEmpty {
                DisclosureGroup("Thinking...") {
                    Text(thinking)
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                .padding(8)
                .background(.quaternary)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            if !text.isEmpty {
                MarkdownText(source: text)
            }
        }
        .padding(.vertical, 4)
    }
}
```

- [ ] **Step 4: Create ChatInputView**

```swift
// Sources/Sessylph/ChatUI/ChatInputView.swift
import SwiftUI

struct ChatInputView: View {
    let onSend: (String) -> Void
    let onInterrupt: () -> Void
    let isStreaming: Bool

    @State private var inputText = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextEditor(text: $inputText)
                .font(.body)
                .frame(minHeight: 36, maxHeight: 120)
                .fixedSize(horizontal: false, vertical: true)
                .focused($isFocused)
                .onSubmit {
                    if !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        sendMessage()
                    }
                }
                .onKeyPress(.return) {
                    if NSEvent.modifierFlags.contains(.shift) {
                        return .ignored  // Allow newline
                    }
                    sendMessage()
                    return .handled
                }

            if isStreaming {
                Button(action: onInterrupt) {
                    Image(systemName: "stop.fill")
                        .foregroundStyle(.red)
                }
                .buttonStyle(.bordered)
                .help("Stop (Escape)")
            } else {
                Button(action: sendMessage) {
                    Image(systemName: "arrow.up.circle.fill")
                }
                .buttonStyle(.bordered)
                .disabled(inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .keyboardShortcut(.return, modifiers: [])
            }
        }
        .padding(12)
        .onAppear { isFocused = true }
    }

    private func sendMessage() {
        let trimmed = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onSend(trimmed)
        inputText = ""
    }
}
```

- [ ] **Step 5: Verify it compiles**

Run: `cd /Users/hiko/Documents/repos/Personal/Sessylph && xcodegen generate && xcodebuild -scheme Sessylph -configuration Debug -derivedDataPath build build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 6: Commit**

```bash
jj describe -m "feat: add chat view with message feed, streaming, and input

- ChatViewModel as @Observable model for message feed state
- ChatView with ScrollView + LazyVStack message feed
- MessageBubble renders content blocks (text, thinking, tool_use, tool_result)
- StreamingTextView for in-progress responses with thinking disclosure
- ChatInputView with Enter-to-send, Shift+Enter for newline, stop button

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>"
```

---

## Task 7: Tool Call Card & Permission Banner

**Goal:** Collapsible tool invocation cards and permission allow/deny banners.

**Files:**
- Create: `Sources/Sessylph/ChatUI/ToolCallCard.swift`
- Create: `Sources/Sessylph/ChatUI/ToolResultView.swift`
- Create: `Sources/Sessylph/ChatUI/PermissionBanner.swift`

- [ ] **Step 1: Write ToolCallCard**

```swift
// Sources/Sessylph/ChatUI/ToolCallCard.swift
import SwiftUI

struct ToolCallCard: View {
    let toolUse: ToolUseBlock
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack {
                    Image(systemName: iconName(for: toolUse.name))
                        .foregroundStyle(.orange)
                    Text(toolUse.name)
                        .fontWeight(.medium)
                    Text(toolUse.input.displaySummary)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer()
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .foregroundStyle(.tertiary)
                }
                .font(.callout)
                .padding(8)
            }
            .buttonStyle(.plain)

            // Expanded content
            if isExpanded {
                Divider()
                toolInputView(toolUse.name, input: toolUse.input)
                    .padding(8)
            }
        }
        .background(.quaternary.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(.quaternary, lineWidth: 1)
        )
    }

    private func iconName(for tool: String) -> String {
        switch tool {
        case "Bash": return "terminal"
        case "Edit": return "pencil"
        case "Read": return "doc.text"
        case "Write": return "doc.badge.plus"
        case "Glob": return "magnifyingglass"
        case "Grep": return "text.magnifyingglass"
        case "Agent": return "person.2"
        default: return "wrench"
        }
    }

    @ViewBuilder
    private func toolInputView(_ name: String, input: JSONValue) -> some View {
        switch name {
        case "Bash":
            if let command = input["command"]?.displaySummary {
                CodeBlockView(language: "bash", code: command)
            }
        case "Edit":
            VStack(alignment: .leading, spacing: 4) {
                if let path = input["file_path"]?.displaySummary {
                    Text(path).font(.caption).foregroundStyle(.secondary)
                }
                if let oldStr = input["old_string"]?.displaySummary,
                   let newStr = input["new_string"]?.displaySummary {
                    HStack(alignment: .top) {
                        CodeBlockView(language: "diff", code: "- \(oldStr)")
                        CodeBlockView(language: "diff", code: "+ \(newStr)")
                    }
                }
            }
        case "Read":
            if let path = input["file_path"]?.displaySummary {
                Text(path)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        case "Write":
            VStack(alignment: .leading, spacing: 4) {
                if let path = input["file_path"]?.displaySummary {
                    Text(path).font(.caption).foregroundStyle(.secondary)
                }
                if let content = input["content"]?.displaySummary {
                    CodeBlockView(language: nil, code: String(content.prefix(500)))
                }
            }
        default:
            // Generic JSON display
            Text(input.displaySummary)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }
}
```

- [ ] **Step 2: Write ToolResultView**

```swift
// Sources/Sessylph/ChatUI/ToolResultView.swift
import SwiftUI

struct ToolResultView: View {
    let result: ToolResultBlock

    var body: some View {
        if let content = result.content {
            VStack(alignment: .leading, spacing: 4) {
                if result.isError == true {
                    Label("Error", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                        .font(.caption)
                }

                if content.count > 500 {
                    DisclosureGroup("Output (\(content.count) chars)") {
                        ScrollView {
                            Text(content)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxHeight: 300)
                        }
                    }
                    .padding(8)
                    .background(.quaternary.opacity(0.3))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                } else {
                    Text(content)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .padding(8)
                        .background(.quaternary.opacity(0.3))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
            }
        }
    }
}
```

- [ ] **Step 3: Write PermissionBanner**

```swift
// Sources/Sessylph/ChatUI/PermissionBanner.swift
import SwiftUI

struct PermissionBanner: View {
    let permission: ChatViewModel.PendingPermission
    let onAllow: () -> Void
    let onDeny: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "lock.shield")
                    .foregroundStyle(.yellow)
                Text("Permission Required")
                    .fontWeight(.semibold)
            }
            .font(.callout)

            HStack(spacing: 4) {
                Text(permission.displayName ?? permission.toolName)
                    .fontWeight(.medium)
                if let desc = permission.description {
                    Text("— \(desc)")
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .font(.callout)

            // Show tool input preview
            if let input = permission.input {
                Text(input.displaySummary)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .padding(6)
                    .background(.quaternary)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }

            HStack {
                Button("Allow") { onAllow() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: [])

                Button("Deny") { onDeny() }
                    .buttonStyle(.bordered)
                    .keyboardShortcut(.escape, modifiers: [])

                Spacer()
            }
        }
        .padding(12)
        .background(.yellow.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(.yellow.opacity(0.3), lineWidth: 1)
        )
    }
}
```

- [ ] **Step 4: Verify it compiles**

Run: `cd /Users/hiko/Documents/repos/Personal/Sessylph && xcodegen generate && xcodebuild -scheme Sessylph -configuration Debug -derivedDataPath build build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 5: Commit**

```bash
jj describe -m "feat: add tool call cards and permission banner

- ToolCallCard with tool-specific rendering (Bash, Edit, Read, Write)
- Collapsible expand/collapse with chevron
- ToolResultView with error indicator and large output folding
- PermissionBanner with allow/deny buttons and keyboard shortcuts

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>"
```

---

## Task 8: ChatViewController (Integration Controller)

**Goal:** NSHostingController wrapper that wires ChatView ↔ CLIProcessManager ↔ WebSocket, replacing TerminalViewController for native UI mode.

**Files:**
- Create: `Sources/Sessylph/ChatUI/ChatViewController.swift`

- [ ] **Step 1: Write ChatViewController**

```swift
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
            onAllow: { [weak self] reqId, perms in self?.processManager.allowTool(requestId: reqId, permissions: perms) },
            onDeny: { [weak self] reqId, reason in self?.processManager.denyTool(requestId: reqId, reason: reason) },
            onInterrupt: { [weak self] in self?.processManager.interrupt() }
        )

        setupMessageHandling()
        setupProcessCallbacks(session: session)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Launch the CLI process for this session.
    func launch(directory: URL, options: ClaudeCodeOptions) {
        Task {
            do {
                try await processManager.launch(directory: directory, options: options)
            } catch {
                logger.error("Failed to launch CLI: \(error.localizedDescription, privacy: .public)")
                viewModel.addSystemEvent("Failed to launch: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Private

    private func setupMessageHandling() {
        wsServer.onMessage = { [weak self] sessionId, message in
            guard let self, sessionId == self.processManager.sessionId else { return }
            self.handleMessage(message)
        }
    }

    private func setupProcessCallbacks(session: Session) {
        processManager.onTerminated = { [weak self] in
            self?.viewModel.addSystemEvent("Session ended.")
            self?.delegate?.chatDidTerminate()
        }
    }

    private func handleMessage(_ message: StreamMessage) {
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
            // Could update a tool card's elapsed time indicator
            logger.debug("Tool progress: \(progress.toolName ?? "?", privacy: .public) \(progress.elapsedTimeSeconds ?? 0)s")

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
}
```

- [ ] **Step 2: Verify it compiles**

Run: `cd /Users/hiko/Documents/repos/Personal/Sessylph && xcodegen generate && xcodebuild -scheme Sessylph -configuration Debug -derivedDataPath build build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
jj describe -m "feat: add ChatViewController as integration controller

- Wires ChatView ↔ CLIProcessManager ↔ WebSocket server
- Handles all StreamMessage types and routes to ChatViewModel
- Delegates for state changes, completion, termination
- Launch method for starting CLI process

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>"
```

---

## Task 9: Integrate with TabWindowController & Session Model

**Goal:** Wire the new native UI mode into the existing tab management, launcher, and session infrastructure.

**Files:**
- Modify: `Sources/Sessylph/Models/Session.swift` — add `renderingMode`
- Modify: `Sources/Sessylph/Models/LaunchConfig.swift` — add `claudeCodeNative` case
- Modify: `Sources/Sessylph/Tabs/TabWindowController.swift` — support ChatViewController
- Modify: `Sources/Sessylph/App/AppDelegate.swift` — initialize WebSocketServer
- Modify: `Sources/Sessylph/Settings/GeneralSettingsView.swift` — add rendering mode toggle

- [ ] **Step 1: Add RenderingMode to Session**

In `Sources/Sessylph/Models/Session.swift`, add:

```swift
enum RenderingMode: String, Codable, Sendable {
    case terminal   // GhosttyKit + tmux (existing)
    case nativeUI   // SwiftUI chat via --sdk-url
}
```

Add field to Session struct:
```swift
var renderingMode: RenderingMode = .terminal
```

Add to `CodingKeys` and `init(from decoder:)`.

- [ ] **Step 2: Add claudeCodeNative to LaunchConfig**

In `Sources/Sessylph/Models/LaunchConfig.swift`, add case:

```swift
case claudeCodeNative(ClaudeCodeOptions)
```

- [ ] **Step 3: Modify TabWindowController to support both modes**

In `Sources/Sessylph/Tabs/TabWindowController.swift`:

Add a `chatVC` property alongside `terminalVC`:
```swift
private var chatVC: ChatViewController?
```

Add a `showNativeChat()` method parallel to `showTerminal()`:
```swift
private func showNativeChat() {
    let wsServer = (NSApp.delegate as! AppDelegate).wsServer
    let chatVC = ChatViewController(wsServer: wsServer, session: session)
    chatVC.delegate = self  // implement ChatViewControllerDelegate
    self.chatVC = chatVC
    window?.contentViewController = chatVC
}
```

Modify `launchSession()` to branch on `renderingMode`:
```swift
func launchSession(directory: URL, config: LaunchConfig) {
    switch config {
    case .claudeCodeNative(let options):
        session.renderingMode = .nativeUI
        session.cliType = .claudeCode
        session.options = options
        session.directory = directory
        showNativeChat()
        chatVC?.launch(directory: directory, options: options)

    case .claudeCode(let options):
        // ... existing terminal flow ...
    // ... other cases ...
    }
}
```

Make TabWindowController conform to `ChatViewControllerDelegate`.

- [ ] **Step 4: Initialize WebSocketServer in AppDelegate**

In `Sources/Sessylph/App/AppDelegate.swift`:

```swift
let wsServer = WebSocketServer()

func applicationDidFinishLaunching(_ notification: Notification) {
    // ... existing code ...
    do {
        try wsServer.start()
    } catch {
        logger.error("Failed to start WebSocket server: \(error.localizedDescription, privacy: .public)")
    }
}

func applicationWillTerminate(_ notification: Notification) {
    wsServer.stop()
    // ... existing cleanup ...
}
```

- [ ] **Step 5: Add rendering mode toggle to GeneralSettingsView**

Add a picker to `Sources/Sessylph/Settings/GeneralSettingsView.swift`:

```swift
Picker("Claude Code Rendering", selection: $renderingMode) {
    Text("Terminal").tag("terminal")
    Text("Native UI (Beta)").tag("nativeUI")
}
.pickerStyle(.segmented)
```

Store in UserDefaults as `Defaults.defaultRenderingMode`.

- [ ] **Step 6: Modify LauncherView to use rendering mode**

When launching a Claude Code session, check the rendering mode preference:

```swift
if renderingMode == "nativeUI" {
    config = .claudeCodeNative(options)
} else {
    config = .claudeCode(options)
}
```

- [ ] **Step 7: Verify it compiles and runs**

Run: `cd /Users/hiko/Documents/repos/Personal/Sessylph && xcodegen generate && xcodebuild -scheme Sessylph -configuration Debug -derivedDataPath build build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

Manual test: Launch app → select a directory → choose "Native UI" mode → launch Claude Code → verify chat UI appears and can send messages.

- [ ] **Step 8: Commit**

```bash
jj describe -m "feat: integrate native UI mode into tab system and launcher

- Add RenderingMode enum (.terminal, .nativeUI) to Session
- Add .claudeCodeNative LaunchConfig case
- TabWindowController switches between TerminalVC and ChatVC based on mode
- AppDelegate initializes WebSocketServer singleton
- GeneralSettingsView adds rendering mode toggle
- LauncherView branches on rendering mode preference

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>"
```

---

## Task 10: Notifications & State Integration

**Goal:** Wire native UI session state to existing notification system and window title.

**Files:**
- Modify: `Sources/Sessylph/Tabs/TabWindowController.swift` — implement ChatViewControllerDelegate
- Modify: `Sources/Sessylph/Tabs/ClaudeStateTracker.swift` — add protocol-driven state input

- [ ] **Step 1: Implement ChatViewControllerDelegate in TabWindowController**

```swift
extension TabWindowController: ChatViewControllerDelegate {
    func chatDidComplete(sessionId: String) {
        // Trigger notification (same as terminal working→idle)
        NotificationManager.shared.postTaskComplete(
            sessionName: session.title,
            taskDescription: stateTracker.lastWorkingTaskDescription
        )
    }

    func chatDidTerminate() {
        // Show launcher again (same as terminal process exit)
        showLauncher()
        session.isRunning = false
        SessionStore.shared.remove(session)
    }

    func chatTitleDidChange(_ title: String) {
        window?.title = title
        window?.tab.title = title
    }

    func chatStateDidChange(isWorking: Bool) {
        // Update window title/tab badge
        if isWorking {
            window?.tab.accessoryView = workingIndicator()
        } else {
            window?.tab.accessoryView = nil
        }
    }
}
```

- [ ] **Step 2: Verify and commit**

Run: `cd /Users/hiko/Documents/repos/Personal/Sessylph && xcodegen generate && xcodebuild -scheme Sessylph -configuration Debug -derivedDataPath build build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

```bash
jj describe -m "feat: wire native UI state to notifications and window title

- Implement ChatViewControllerDelegate on TabWindowController
- Task completion triggers notification (same UX as terminal mode)
- Working state updates tab badge indicator
- Termination returns to launcher view

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>"
```

---

## Task 11: Session Resume Support

**Goal:** Enable resuming previous Claude Code sessions in native UI mode.

**Files:**
- Modify: `Sources/Sessylph/ChatUI/ChatViewController.swift` — add resume support
- Modify: `Sources/Sessylph/Session/CLIProcessManager.swift` — add resume launch
- Modify: `Sources/Sessylph/Tabs/TabWindowController.swift` — handle resume from launcher

- [ ] **Step 1: Add resume support to CLIProcessManager**

Add a `resume()` method:

```swift
func resume(directory: URL, options: ClaudeCodeOptions, resumeSessionId: String) async throws {
    var resumeOptions = options
    resumeOptions.resumeSessionId = resumeSessionId
    try await launch(directory: directory, options: resumeOptions)
}
```

- [ ] **Step 2: Wire resume in TabWindowController and LauncherView**

When the launcher's session history shows a previous session, launch in native UI mode with `--resume`:

```swift
case .claudeCodeNative(var options):
    if let resumeId = options.resumeSessionId {
        // Resume existing session
        chatVC?.launch(directory: directory, options: options)  // buildSDKArgs includes -r flag
    } else {
        chatVC?.launch(directory: directory, options: options)
    }
```

- [ ] **Step 3: Verify and commit**

```bash
jj describe -m "feat: add session resume support for native UI mode

- CLIProcessManager resume() passes --resume flag to CLI
- LauncherView resume button works with native UI mode
- Session history interop with terminal mode sessions

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>"
```

---

## Task 12: End-to-End Testing & Polish

**Goal:** Manual integration test, fix issues, polish the UX.

- [ ] **Step 1: Full build**

```bash
cd /Users/hiko/Documents/repos/Personal/Sessylph
pgrep -x Sessylph | xargs kill 2>/dev/null; true
xcodegen generate
xcodebuild -scheme Sessylph -configuration Debug -derivedDataPath build build
open build/Build/Products/Debug/Sessylph.app
```

- [ ] **Step 2: Test matrix**

| Test | Steps | Expected |
|------|-------|----------|
| Local native launch | Settings → Native UI → New Tab → select dir → launch | Chat UI appears, system/init message, input field focused |
| Send message | Type "hello" → Enter | User bubble appears, streaming response, assistant bubble finalizes |
| Tool permission | Ask Claude to edit a file | PermissionBanner appears with allow/deny |
| Allow tool | Click "Allow" | Tool executes, result appears |
| Deny tool | Click "Deny" | Claude acknowledges denial |
| Interrupt | Click stop or press Escape during streaming | Streaming stops |
| Terminal fallback | Settings → Terminal → New Tab → launch | Existing GhosttyKit terminal works unchanged |
| Codex/Cursor | Select Codex → launch | Terminal mode (no native UI option) |
| Tab switching | Open 2+ tabs (mix of terminal + native) | Both modes work in same window |
| Session resume | Quit → relaunch → click recent session | Native UI resumes with history |
| Notification | Ask Claude a long task → switch to another app | Notification fires when task completes |

- [ ] **Step 3: Fix any issues found during testing**

Address each failure individually, re-test after fix.

- [ ] **Step 4: Final commit**

```bash
jj describe -m "fix: polish native UI mode after integration testing

- [list specific fixes here]

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>"
```

---

## Architecture Summary: What Changed vs What Stayed

### New (12 files)
```
Protocol/WebSocketServer.swift      — NWListener WebSocket server
Protocol/NDJSONParser.swift         — NDJSON stream parser
Protocol/StreamMessage.swift        — All message type models
ChatUI/ChatViewController.swift     — Integration controller
ChatUI/ChatView.swift               — Main chat layout + ChatViewModel
ChatUI/MessageBubble.swift          — Message rendering
ChatUI/MarkdownText.swift           — Markdown renderer
ChatUI/StreamingTextView.swift      — In-progress response
ChatUI/ChatInputView.swift          — User input field
ChatUI/ToolCallCard.swift           — Tool invocation card
ChatUI/ToolResultView.swift         — Tool result display
ChatUI/PermissionBanner.swift       — Allow/deny banner
Session/CLIProcessManager.swift     — CLI process lifecycle
Session/SessionStateMachine.swift   — State transitions
```

### Modified (6 files)
```
Models/Session.swift                — +RenderingMode enum
Models/LaunchConfig.swift           — +claudeCodeNative case
Models/ClaudeCodeOptions.swift      — +buildSDKArgs() method
Tabs/TabWindowController.swift      — +ChatVC support, +ChatViewControllerDelegate
App/AppDelegate.swift               — +WebSocketServer init
Settings/GeneralSettingsView.swift  — +rendering mode toggle
project.yml                         — +swift-markdown dependency
```

### Untouched (42 files)
All Terminal/ files (GhosttyKit), all Utilities/, all other Models/, Launcher/ (minimal changes), Notifications/, TmuxManager, etc. Terminal mode works exactly as before.

---

## Task 13: Image Paste & Drag-Drop

**Goal:** Support pasting/dropping images into chat input, sent as base64 content blocks.

**Files:**
- Modify: `Sources/Sessylph/ChatUI/ChatInputView.swift` — add paste/drop handlers
- Modify: `Sources/Sessylph/Session/CLIProcessManager.swift` — send image content blocks

- [ ] **Step 1: Add image paste handling to ChatInputView**

Support Cmd+V for images from clipboard and drag-drop from Finder:

```swift
// In ChatInputView, add:
.onDrop(of: [.image, .fileURL], isTargeted: nil) { providers in
    for provider in providers {
        if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
            provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                if let data {
                    Task { @MainActor in
                        onImageDrop(data, mediaType: "image/png")
                    }
                }
            }
        }
    }
    return true
}
```

Override paste to detect images:
```swift
// Detect image on pasteboard
if let imageData = NSPasteboard.general.data(forType: .png) {
    onImageDrop(imageData, mediaType: "image/png")
} else if let imageData = NSPasteboard.general.data(forType: .tiff) {
    // Convert TIFF to PNG
    if let rep = NSBitmapImageRep(data: imageData),
       let pngData = rep.representation(using: .png, properties: [:]) {
        onImageDrop(pngData, mediaType: "image/png")
    }
}
```

- [ ] **Step 2: Send image as content block in UserMessage**

In `CLIProcessManager`, add method to send image + optional text:

```swift
func sendUserMessageWithImage(_ text: String?, imageData: Data, mediaType: String) {
    var blocks: [UserContentBlock] = []
    blocks.append(UserContentBlock(
        type: "image",
        text: nil,
        source: ImageSource(type: "base64", mediaType: mediaType, data: imageData.base64EncodedString())
    ))
    if let text, !text.isEmpty {
        blocks.append(UserContentBlock(type: "text", text: text, source: nil))
    }
    let message = UserMessage(
        type: "user",
        message: UserContent(role: "user", content: .blocks(blocks)),
        parentToolUseId: nil,
        sessionId: sessionId
    )
    wsServer.send(message, to: sessionId)
    stateMachine.transition(to: .streaming)
}
```

- [ ] **Step 3: Show image thumbnail in chat feed**

Add image rendering to `MessageBubble` for user messages with image content blocks.

- [ ] **Step 4: Verify and commit**

```bash
jj describe -m "feat: add image paste and drag-drop support in native UI chat

- Cmd+V pastes images from clipboard (PNG, TIFF)
- Drag-drop images from Finder
- Images sent as base64 content blocks in UserMessage
- Thumbnail preview in chat feed

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>"
```

---

## Task 14: Slash Command Suggestions

**Goal:** Show slash commands from `system/init` message in chat input, integrated with existing CommandStrip.

**Files:**
- Modify: `Sources/Sessylph/ChatUI/ChatInputView.swift` — add command suggestion popover
- Modify: `Sources/Sessylph/ChatUI/ChatView.swift` — pass slash commands from session info
- Reuse: `Sources/Sessylph/Utilities/SlashCommandStore.swift` — existing command tracking

- [ ] **Step 1: Add slash command autocomplete to ChatInputView**

When user types `/`, show a filtered list of available commands:

```swift
// In ChatInputView
@State private var showCommandSuggestions = false
@State private var commandFilter = ""

// Watch for "/" prefix
.onChange(of: inputText) { _, newValue in
    if newValue.hasPrefix("/") {
        commandFilter = String(newValue.dropFirst())
        showCommandSuggestions = true
    } else {
        showCommandSuggestions = false
    }
}

// Suggestion popover
.popover(isPresented: $showCommandSuggestions, arrowEdge: .top) {
    VStack(alignment: .leading, spacing: 2) {
        ForEach(filteredCommands, id: \.name) { cmd in
            Button {
                inputText = "/\(cmd.name) "
                showCommandSuggestions = false
            } label: {
                HStack {
                    Text("/\(cmd.name)").fontWeight(.medium)
                    Text(cmd.description ?? "").foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
        }
    }
    .frame(maxHeight: 200)
}
```

- [ ] **Step 2: Populate commands from system/init**

In `ChatViewController.handleSystemMessage()`, store slash commands:
```swift
case "init":
    // ... existing init handling ...
    // Store slash commands for autocomplete
    if let commands = sys.slashCommands {
        self.availableCommands = commands
    }
```

- [ ] **Step 3: Integrate with existing SlashCommandStore for MRU sorting**

Use `SlashCommandStore` to sort suggestions by recent usage, same as terminal mode's CommandStrip.

- [ ] **Step 4: Verify and commit**

```bash
jj describe -m "feat: add slash command suggestions in native UI chat input

- Type '/' to see available commands from system/init
- Filtered autocomplete as you type
- MRU-sorted via existing SlashCommandStore
- Commands from CLI's slash_commands[] metadata

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>"
```

---

## Task 15: Remote SSH via Reverse Tunnel

**Goal:** Native UI mode for remote Claude Code sessions using SSH reverse port forwarding.

**Files:**
- Create: `Sources/Sessylph/Session/RemoteCLIManager.swift` — SSH tunnel + remote CLI spawn
- Modify: `Sources/Sessylph/Models/LaunchConfig.swift` — add `remoteNativeSession` case
- Modify: `Sources/Sessylph/Tabs/TabWindowController.swift` — wire remote native launch

- [ ] **Step 1: Write RemoteCLIManager**

```swift
// Sources/Sessylph/Session/RemoteCLIManager.swift
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
    private var sshProcess: Process?
    private let wsServer: WebSocketServer
    let sessionId: String
    let remoteHost: RemoteHost

    /// Port on the remote host that tunnels back to our local WS server.
    private let remoteTunnelPort: UInt16 = 13579  // Fixed port, could be dynamic

    var onTerminated: (() -> Void)?

    init(wsServer: WebSocketServer, remoteHost: RemoteHost, sessionId: String = UUID().uuidString) {
        self.wsServer = wsServer
        self.remoteHost = remoteHost
        self.sessionId = sessionId
    }

    /// Launch remote claude via SSH with reverse tunnel.
    func launch(directory: String, options: ClaudeCodeOptions) async throws {
        let sdkUrl = "ws://localhost:\(remoteTunnelPort)/ws/cli/\(sessionId)"

        // Build remote claude command
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
        var sshArgs = remoteHost.sshArgs()
        sshArgs += ["-R", "\(remoteTunnelPort):localhost:\(wsServer.port)"]  // Reverse tunnel
        sshArgs += ["-o", "ExitOnForwardFailure=yes"]  // Fail if tunnel can't bind
        sshArgs += [remoteCommand]

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = sshArgs
        process.currentDirectoryURL = URL(fileURLWithPath: NSTemporaryDirectory())

        let loginEnv = await EnvironmentBuilder.capturedEnvironment()
        process.environment = loginEnv

        process.terminationHandler = { [weak self] proc in
            Task { @MainActor [weak self] in
                logger.info("Remote SSH process exited with code \(proc.terminationStatus)")
                self?.onTerminated?()
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
```

- [ ] **Step 2: Add remoteNativeSession to LaunchConfig**

```swift
case remoteNativeSession(RemoteHost, directory: String, ClaudeCodeOptions)
```

- [ ] **Step 3: Wire into TabWindowController**

In `launchSession()`:
```swift
case .remoteNativeSession(let host, let dir, let options):
    session.renderingMode = .nativeUI
    session.remoteHost = host
    showNativeChat()
    // ChatViewController uses RemoteCLIManager instead of CLIProcessManager
    chatVC?.launchRemote(host: host, directory: dir, options: options)
```

- [ ] **Step 4: Update LauncherView remote session flow**

When rendering mode is "Native UI" and user selects a remote host, use `remoteNativeSession` instead of `remoteNewSession`.

- [ ] **Step 5: Verify and commit**

Test: Launch remote session → verify SSH tunnel establishes → verify chat UI works over tunnel.

```bash
jj describe -m "feat: add remote SSH support for native UI via reverse tunnel

- RemoteCLIManager: SSH -R tunnel + remote claude --sdk-url
- Reverse port forwarding: remote:tunnelPort → local:wsPort
- Same native UI as local sessions, running on remote host
- ExitOnForwardFailure for clean error handling

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>"
```

---

## Phase 2 Preview (Not in This Plan)

After Phase 1 is stable:
- **Diff viewer**: Inline diff rendering for Edit tool results
- **Cost dashboard**: Running total from ResultMessage.totalCostUsd
- **Sub-agent nesting**: `parent_tool_use_id` tree rendering (matching VS Code extension)
- **Read coalescing**: Group sequential Read tool calls into one card
- **Multiple rendering modes**: Compact (one-line tool cards) vs detailed
- **Context compaction indicator**: Visual feedback during compacting state
