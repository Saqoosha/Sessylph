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
