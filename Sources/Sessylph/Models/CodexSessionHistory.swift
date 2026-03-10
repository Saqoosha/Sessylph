import Foundation

// MARK: - Codex Session Entry

struct CodexSessionEntry: Identifiable, Sendable {
    let id: String
    let title: String
    let timestamp: Date
    let projectPath: String
    let projectName: String
}

// MARK: - Codex Session History

actor CodexSessionHistory {
    static let shared = CodexSessionHistory()

    private var cachedSessions: [CodexSessionEntry] = []
    private var lastLoadTime: Date = .distantPast
    private static let cacheInterval: TimeInterval = 30
    private static let maxSessionsToParse = 50
    private static let previewReadSize = 8192

    func loadSessions(forceRefresh: Bool = false) async -> [CodexSessionEntry] {
        if !forceRefresh, Date().timeIntervalSince(lastLoadTime) < Self.cacheInterval {
            return cachedSessions
        }
        let sessions = Self.parseSessions()
        cachedSessions = sessions
        lastLoadTime = Date()
        return sessions
    }

    private static func parseSessions() -> [CodexSessionEntry] {
        let index = parseSessionIndex()
        guard !index.isEmpty else { return [] }

        let fileURLsBySessionId = sessionFileURLsBySessionId()
        var entries: [CodexSessionEntry] = []
        entries.reserveCapacity(maxSessionsToParse)

        for indexed in index.prefix(maxSessionsToParse * 2) {
            guard let fileURL = fileURLsBySessionId[indexed.id] else { continue }
            guard let entry = parseSessionFile(fileURL, indexed: indexed) else { continue }
            entries.append(entry)
            if entries.count >= maxSessionsToParse {
                break
            }
        }

        return entries
    }

    private static func parseSessionIndex() -> [IndexedSession] {
        let indexURL = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".codex/session_index.jsonl")

        guard let text = try? String(contentsOf: indexURL, encoding: .utf8) else {
            return []
        }

        let formatters = makeISO8601Formatters()
        var sessions: [IndexedSession] = []
        sessions.reserveCapacity(maxSessionsToParse)

        for line in text.split(separator: "\n") {
            guard let data = String(line).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = object["id"] as? String,
                  let threadName = object["thread_name"] as? String
            else { continue }

            let updatedAt = parseISO8601(object["updated_at"] as? String, fractional: formatters.fractional, standard: formatters.standard) ?? .distantPast
            sessions.append(
                IndexedSession(
                    id: id,
                    threadName: truncateTitle(threadName),
                    updatedAt: updatedAt
                )
            )
        }

        sessions.sort { $0.updatedAt > $1.updatedAt }
        return sessions
    }

    private static func sessionFileURLsBySessionId() -> [String: URL] {
        let sessionsRoot = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".codex/sessions", isDirectory: true)

        guard let enumerator = FileManager.default.enumerator(
            at: sessionsRoot,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return [:]
        }

        var urlsBySessionId: [String: URL] = [:]

        for case let fileURL as URL in enumerator where fileURL.pathExtension == "jsonl" {
            let baseName = fileURL.deletingPathExtension().lastPathComponent
            let sessionId = String(baseName.suffix(36))
            guard UUID(uuidString: sessionId) != nil else { continue }
            urlsBySessionId[sessionId] = fileURL
        }

        return urlsBySessionId
    }

    private static func parseSessionFile(_ fileURL: URL, indexed: IndexedSession) -> CodexSessionEntry? {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return nil }
        defer { try? handle.close() }

        let data = handle.readData(ofLength: previewReadSize)
        guard let text = String(data: data, encoding: .utf8) else { return nil }

        let cwd = extractValue(for: "cwd", in: text).flatMap(decodeJSONString) ?? NSHomeDirectory()
        let title = indexed.threadName.isEmpty
            ? truncateTitle(extractFirstUserMessage(in: text) ?? "Codex Session")
            : indexed.threadName

        let projectName = URL(fileURLWithPath: cwd).lastPathComponent.isEmpty
            ? cwd
            : URL(fileURLWithPath: cwd).lastPathComponent

        return CodexSessionEntry(
            id: indexed.id,
            title: title,
            timestamp: indexed.updatedAt,
            projectPath: cwd,
            projectName: projectName
        )
    }

    private static func extractValue(for key: String, in text: String) -> String? {
        let pattern = "\"\(NSRegularExpression.escapedPattern(for: key))\":\"((?:\\\\.|[^\"])*)\""
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let valueRange = Range(match.range(at: 1), in: text)
        else { return nil }
        return String(text[valueRange])
    }

    private static func decodeJSONString(_ value: String) -> String? {
        guard let data = "\"\(value)\"".data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(String.self, from: data)
    }

    private static func extractFirstUserMessage(in text: String) -> String? {
        let pattern = "\"role\":\"user\".*?\"text\":\"((?:\\\\.|[^\"])*)\""
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let textRange = Range(match.range(at: 1), in: text)
        else { return nil }
        return decodeJSONString(String(text[textRange]))
    }

    private static func truncateTitle(_ text: String) -> String {
        let firstLine = text.components(separatedBy: .newlines).first ?? text
        return firstLine.count > 100 ? String(firstLine.prefix(100)) + "..." : firstLine
    }

    private static func makeISO8601Formatters() -> (fractional: ISO8601DateFormatter, standard: ISO8601DateFormatter) {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return (fractional, ISO8601DateFormatter())
    }

    private static func parseISO8601(_ value: String?, fractional: ISO8601DateFormatter, standard: ISO8601DateFormatter) -> Date? {
        guard let value else { return nil }
        return fractional.date(from: value) ?? standard.date(from: value)
    }
}

private struct IndexedSession {
    let id: String
    let threadName: String
    let updatedAt: Date
}
