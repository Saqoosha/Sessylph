import Foundation

// MARK: - Claude Session Entry

struct ClaudeSessionEntry: Identifiable, Sendable {
    let id: String // sessionId (UUID string from filename)
    let title: String // first user message or saved task title
    let timestamp: Date
    let projectPath: String // decoded project directory path
    var projectName: String { (projectPath as NSString).lastPathComponent }
}

// MARK: - Claude Session History

actor ClaudeSessionHistory {
    static let shared = ClaudeSessionHistory()

    private var cachedSessions: [ClaudeSessionEntry] = []
    private var lastLoadTime: Date = .distantPast
    private static let cacheInterval: TimeInterval = 30
    private static let maxSessionsToParse = 50

    func loadSessions(forceRefresh: Bool = false) async -> [ClaudeSessionEntry] {
        if !forceRefresh, Date().timeIntervalSince(lastLoadTime) < Self.cacheInterval {
            return cachedSessions
        }
        let sessions = await Self.parseSessions()
        cachedSessions = sessions
        lastLoadTime = Date()
        return sessions
    }

    // MARK: - Parsing (runs on caller's executor, but called from actor)

    private static func parseSessions() async -> [ClaudeSessionEntry] {
        let dateFormatter = ISO8601DateFormatter()
        let fm = FileManager.default
        let projectsDir = NSHomeDirectory() + "/.claude/projects"

        guard let projectDirs = try? fm.contentsOfDirectory(atPath: projectsDir) else {
            return []
        }

        // Collect all .jsonl files with modification dates across all projects
        var candidates: [(path: String, modDate: Date, sessionId: String, projectEncoded: String)] = []

        for projectEncoded in projectDirs {
            // Skip sessions with CWD "/" (typically automated/scripted runs)
            guard projectEncoded != "-" else { continue }

            let projectPath = projectsDir + "/" + projectEncoded
            guard let files = try? fm.contentsOfDirectory(atPath: projectPath) else { continue }

            for file in files where file.hasSuffix(".jsonl") {
                let filePath = projectPath + "/" + file
                let sessionId = String(file.dropLast(6)) // remove .jsonl

                // Validate UUID format (skip non-session files)
                guard UUID(uuidString: sessionId) != nil else { continue }

                // Get modification date from filesystem metadata (no file read)
                guard let attrs = try? fm.attributesOfItem(atPath: filePath),
                      let modDate = attrs[.modificationDate] as? Date
                else { continue }

                candidates.append((filePath, modDate, sessionId, projectEncoded))
            }
        }

        // Sort by modification date descending, take top N
        candidates.sort { $0.modDate > $1.modDate }
        let topCandidates = candidates.prefix(maxSessionsToParse)

        // Parse each file's first few lines to extract metadata
        var entries: [ClaudeSessionEntry] = []
        entries.reserveCapacity(topCandidates.count)

        for candidate in topCandidates {
            guard let entry = parseSessionFile(
                path: candidate.path,
                sessionId: candidate.sessionId,
                projectEncoded: candidate.projectEncoded,
                fallbackDate: candidate.modDate,
                dateFormatter: dateFormatter
            ) else { continue }
            entries.append(entry)
        }

        entries.sort { $0.timestamp > $1.timestamp }
        return entries
    }

    private static func parseSessionFile(
        path: String,
        sessionId: String,
        projectEncoded: String,
        fallbackDate: Date,
        dateFormatter: ISO8601DateFormatter
    ) -> ClaudeSessionEntry? {
        // Read only the first ~8KB to find the first user message
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { handle.closeFile() }

        let data = handle.readData(ofLength: 8192)
        guard let text = String(data: data, encoding: .utf8) else { return nil }

        let lines = text.components(separatedBy: "\n")

        for line in lines.prefix(30) {
            guard !line.isEmpty else { continue }

            // Quick pre-check before JSON parsing
            guard line.contains("\"type\":\"user\"") || line.contains("\"type\": \"user\"") else {
                continue
            }

            guard let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let type = json["type"] as? String,
                  type == "user",
                  json["isMeta"] as? Bool != true
            else { continue }

            // Extract message content
            var title = ""
            if let message = json["message"] as? [String: Any] {
                if let content = message["content"] as? String {
                    title = content
                } else if let contentArray = message["content"] as? [[String: Any]],
                          let firstText = contentArray.first(where: { $0["type"] as? String == "text" }),
                          let text = firstText["text"] as? String
                {
                    title = text
                }
            }

            guard !title.isEmpty else { continue }

            // Truncate and clean up title
            let cleanTitle = title
                .replacingOccurrences(
                    of: "</?command-(?:name|message|args)>",
                    with: "",
                    options: .regularExpression
                )
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .components(separatedBy: .newlines)
                .first ?? title
            let truncated = cleanTitle.count > 100
                ? String(cleanTitle.prefix(100)) + "..."
                : cleanTitle

            // Use saved task title if available, otherwise use first user message
            let displayTitle = SessionTitleStore.title(forSessionId: sessionId) ?? truncated

            // Parse timestamp
            let timestamp: Date
            if let ts = json["timestamp"] as? String {
                timestamp = dateFormatter.date(from: ts) ?? fallbackDate
            } else {
                timestamp = fallbackDate
            }

            let projectPath = decodeProjectPath(projectEncoded)

            return ClaudeSessionEntry(
                id: sessionId,
                title: displayTitle,
                timestamp: timestamp,
                projectPath: projectPath
            )
        }

        return nil
    }

    /// Decode encoded project directory name back to path.
    ///
    /// Claude Code encoding: path components joined by `-`, leading `.` in
    /// component names becomes extra `-` (so `/.config` → `--config`).
    /// Since `-` is ambiguous (separator vs literal), we greedily walk the
    /// filesystem to find real directories.
    private static func decodeProjectPath(_ encoded: String) -> String {
        guard encoded.count > 1 else { return "/" }

        // Split preserving empty strings: "--" produces empty token before dot-component
        // "-Users-hiko--config-claude" → ["", "Users", "hiko", "", "config", "claude"]
        let parts = encoded.split(separator: "-", omittingEmptySubsequences: false)
            .map(String.init)
        let tokens = Array(parts.dropFirst()) // drop leading ""

        // Build tokens with dot-prefix merged:
        // ["Users", "hiko", "", "config", "claude"] → ["Users", "hiko", ".config", "claude"]
        var segments: [String] = []
        var i = 0
        while i < tokens.count {
            if tokens[i].isEmpty {
                // Next token is dot-prefixed
                i += 1
                if i < tokens.count {
                    segments.append("." + tokens[i])
                }
            } else {
                segments.append(tokens[i])
            }
            i += 1
        }

        // Greedy filesystem walk: at each position, try joining multiple
        // segments with "-" to find the longest match
        let fm = FileManager.default
        var resolved = ""
        i = 0

        while i < segments.count {
            var bestLen = 1
            // Try longest first (up to 6 segments joined by `-`)
            let maxJ = min(segments.count, i + 6)
            for j in stride(from: maxJ, through: i + 1, by: -1) {
                let component = segments[i..<j].joined(separator: "-")
                let candidate = resolved + "/" + component
                if fm.fileExists(atPath: candidate) {
                    bestLen = j - i
                    break
                }
            }

            // When single-segment fallback doesn't exist either, the remaining
            // segments likely form one hyphenated directory name whose encoding
            // lost information (e.g. dots). Try fuzzy-matching in the parent.
            if bestLen == 1, !fm.fileExists(atPath: resolved + "/" + segments[i]) {
                let remaining = segments[i...].joined(separator: "-")
                // Check parent dir for an entry that matches with dots restored
                // e.g. "whatever-co-2021" → "whatever.co-2021"
                if let entries = try? fm.contentsOfDirectory(atPath: resolved) {
                    let normalized = remaining.replacingOccurrences(of: ".", with: "-")
                    if let match = entries.first(where: {
                        $0.replacingOccurrences(of: ".", with: "-") == normalized
                    }) {
                        resolved += "/" + match
                        break
                    }
                    // Parent is a valid directory but this segment doesn't exist
                    // (e.g. deleted dir). Add single segment and keep resolving
                    // so deeper components remain separate path parts.
                    resolved += "/" + segments[i]
                    i += 1
                    continue
                }
                // Parent doesn't exist — join all remaining as one component
                resolved += "/" + remaining
                break
            }

            let component = segments[i..<(i + bestLen)].joined(separator: "-")
            resolved += "/" + component
            i += bestLen
        }

        return resolved.isEmpty ? "/" : resolved
    }

    /// Find the most recent Claude Code session ID for a project directory.
    /// - Parameter earliestDate: Only consider files modified at or after this date.
    static func findSessionId(forDirectory directory: URL, after earliestDate: Date? = nil) -> String? {
        let fm = FileManager.default
        let projectsDir = NSHomeDirectory() + "/.claude/projects"

        let encoded = encodeProjectPath(directory.path)
        let projectPath = projectsDir + "/" + encoded
        guard let files = try? fm.contentsOfDirectory(atPath: projectPath) else { return nil }

        var newest: (id: String, date: Date)?
        for file in files where file.hasSuffix(".jsonl") {
            let sessionId = String(file.dropLast(6))
            guard UUID(uuidString: sessionId) != nil else { continue }
            let filePath = projectPath + "/" + file
            guard let attrs = try? fm.attributesOfItem(atPath: filePath),
                  let modDate = attrs[.modificationDate] as? Date
            else { continue }
            if let earliest = earliestDate, modDate < earliest { continue }
            if newest == nil || modDate > newest!.date {
                newest = (sessionId, modDate)
            }
        }
        return newest?.id
    }

    /// Encode a filesystem path to Claude Code's project directory name.
    ///
    /// Inverse of `decodeProjectPath`: `/Users/hiko/.config/claude` →
    /// `-Users-hiko--config-claude` (leading dots get an extra `-`).
    private static func encodeProjectPath(_ path: String) -> String {
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        var parts = ["-"] // leading "-" prefix
        for component in components {
            let s = String(component)
            if s.hasPrefix(".") {
                // Leading dot → extra "-" (empty segment before the dot-stripped name)
                parts.append("")
                parts.append(String(s.dropFirst()))
            } else {
                parts.append(s)
            }
        }
        return parts.joined(separator: "-")
    }
}
