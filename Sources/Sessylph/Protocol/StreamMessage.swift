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
