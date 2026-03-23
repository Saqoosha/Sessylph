import CryptoKit
import Foundation
import os.log

private let logger = Logger(subsystem: "sh.saqoo.Sessylph", category: "CursorSessionHistory")

// MARK: - Cursor Session Entry

struct CursorSessionEntry: Identifiable, Sendable {
    let id: String
    let title: String
    let timestamp: Date
    let projectPath: String
    let projectName: String
}

// MARK: - Cursor Session History

/// Provides access to recent Cursor Agent chat sessions.
/// Parses session metadata from `~/.cursor/chats/`, where workspace directories are named by MD5 hash of the absolute project path.
actor CursorSessionHistory {
    static let shared = CursorSessionHistory()

    private var cachedSessions: [CursorSessionEntry] = []
    private var lastLoadTime: Date = .distantPast
    private static let cacheInterval: TimeInterval = 30
    private static let maxSessionsToParse = 50
    /// Cursor encodes `/` as `-` in `~/.cursor/projects` folder names. Naive reverse breaks when a path segment contains `-`.
    /// We enumerate contiguous token groupings (2^(n-1) variants for n tokens).
    /// Cap of 15 tokens yields up to 2^14 (~16K) candidates; beyond this, falls back to naive slash replacement.
    private static let maxHyphenTokensForPartition = 15

    func loadSessions(forceRefresh: Bool = false) async -> [CursorSessionEntry] {
        if !forceRefresh, Date().timeIntervalSince(lastLoadTime) < Self.cacheInterval {
            return cachedSessions
        }
        let sessions = Self.parseSessions()
        cachedSessions = sessions
        lastLoadTime = Date()
        return sessions
    }

    private static func parseSessions() -> [CursorSessionEntry] {
        let pathByHash = workspaceHashToProjectPath()
        let chatsRoot = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".cursor/chats", isDirectory: true)
        guard let workspaceDirs = try? FileManager.default.contentsOfDirectory(atPath: chatsRoot.path) else {
            return []
        }

        var candidates: [(entry: CursorSessionEntry, sortDate: Date)] = []
        candidates.reserveCapacity(maxSessionsToParse * 2)

        for workspaceHash in workspaceDirs {
            let wsURL = chatsRoot.appendingPathComponent(workspaceHash, isDirectory: true)
            guard let chatDirs = try? FileManager.default.contentsOfDirectory(atPath: wsURL.path) else { continue }

            for chatId in chatDirs {
                let dbURL = wsURL.appendingPathComponent(chatId).appendingPathComponent("store.db")
                guard FileManager.default.fileExists(atPath: dbURL.path) else { continue }
                guard let metaJSON = readMetaZero(from: dbURL),
                      let meta = parseMetaJSON(metaJSON)
                else { continue }

                let createdAt = meta.createdAt.map { Date(timeIntervalSince1970: TimeInterval($0) / 1000.0) } ?? .distantPast
                let attrs = try? FileManager.default.attributesOfItem(atPath: dbURL.path)
                let modDate = attrs?[.modificationDate] as? Date ?? createdAt
                let sortDate = max(createdAt, modDate)

                let projectPath = pathByHash[workspaceHash] ?? ""
                let projectName: String
                if projectPath.isEmpty {
                    projectName = "Unknown project"
                } else {
                    let url = URL(fileURLWithPath: projectPath)
                    projectName = url.lastPathComponent.isEmpty ? projectPath : url.lastPathComponent
                }

                candidates.append((
                    CursorSessionEntry(
                        id: meta.agentId,
                        title: truncateTitle(meta.name),
                        timestamp: sortDate,
                        projectPath: projectPath,
                        projectName: projectName
                    ),
                    sortDate
                ))
            }
        }

        candidates.sort { $0.sortDate > $1.sortDate }
        return candidates.prefix(maxSessionsToParse).map(\.entry)
    }

    private struct MetaPayload {
        let agentId: String
        let name: String
        let createdAt: Int64?
    }

    private static func parseMetaJSON(_ data: Data) -> MetaPayload? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let agentId = obj["agentId"] as? String,
              let name = obj["name"] as? String
        else { return nil }
        let createdAt: Int64?
        if let n = obj["createdAt"] as? Int64 {
            createdAt = n
        } else if let n = obj["createdAt"] as? Int {
            createdAt = Int64(n)
        } else if let n = obj["createdAt"] as? Double {
            createdAt = Int64(n)
        } else {
            createdAt = nil
        }
        return MetaPayload(agentId: agentId, name: name, createdAt: createdAt)
    }

    private static func readMetaZero(from dbURL: URL) -> Data? {
        guard let sqlite3 = sqlite3ExecutableURL() else {
            logger.warning("sqlite3 not found — cannot read Cursor session history")
            return nil
        }
        let process = Process()
        process.executableURL = sqlite3
        process.arguments = [dbURL.path, "SELECT value FROM meta WHERE key='0';"]
        process.currentDirectoryURL = URL(fileURLWithPath: NSTemporaryDirectory())

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        do {
            try process.run()
        } catch {
            return nil
        }

        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            if let errStr = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !errStr.isEmpty
            {
                logger.warning("sqlite3 failed for \(dbURL.lastPathComponent): \(errStr)")
            }
            return nil
        }

        let raw = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !raw.isEmpty else { return nil }
        let hex = raw.filter { !$0.isWhitespace }
        if let decoded = dataFromHex(hex), parseMetaJSON(decoded) != nil {
            return decoded
        }
        if let utf8 = raw.data(using: .utf8), parseMetaJSON(utf8) != nil {
            return utf8
        }
        return nil
    }

    private static func dataFromHex(_ hex: String) -> Data? {
        var data = Data()
        data.reserveCapacity(hex.count / 2)
        var idx = hex.startIndex
        while idx < hex.endIndex {
            let next = hex.index(idx, offsetBy: 2, limitedBy: hex.endIndex) ?? hex.endIndex
            guard next != idx, let byte = UInt8(hex[idx..<next], radix: 16) else { return nil }
            data.append(byte)
            idx = next
        }
        return data
    }

    private static func sqlite3ExecutableURL() -> URL? {
        let candidates = ["/usr/bin/sqlite3", "/bin/sqlite3"]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    /// Maps `md5(absoluteWorkspacePath)` → path. Cursor stores project dirs as path segments joined with `-` (each `/` → `-`).
    private static func workspaceHashToProjectPath() -> [String: String] {
        let projectsRoot = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".cursor/projects")
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: projectsRoot.path) else {
            return [:]
        }

        var map: [String: String] = [:]
        map.reserveCapacity(names.count * 2)
        for name in names {
            let tokens = name.split(separator: "-").map(String.init)
            guard !tokens.isEmpty else { continue }

            let paths: [String]
            if tokens.count <= maxHyphenTokensForPartition {
                paths = allPathSegmentations(from: tokens).map { "/" + $0.joined(separator: "/") }
            } else {
                paths = ["/" + name.replacingOccurrences(of: "-", with: "/")]
            }

            for path in paths {
                map[md5Hex(path)] = path
            }
        }
        return map
    }

    /// All ways to merge consecutive hyphen-split tokens into path segments (each segment may contain `-` again).
    private static func allPathSegmentations(from tokens: [String]) -> [[String]] {
        guard !tokens.isEmpty else { return [] }
        if tokens.count == 1 {
            return [[tokens[0]]]
        }
        var results: [[String]] = []
        for k in 1...tokens.count {
            let firstSegment = tokens[0..<k].joined(separator: "-")
            let rest = Array(tokens[k...])
            if rest.isEmpty {
                results.append([firstSegment])
            } else {
                for tail in allPathSegmentations(from: rest) {
                    results.append([firstSegment] + tail)
                }
            }
        }
        return results
    }

    private static func md5Hex(_ string: String) -> String {
        Insecure.MD5.hash(data: Data(string.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func truncateTitle(_ text: String) -> String {
        let firstLine = text.components(separatedBy: .newlines).first ?? text
        return firstLine.count > 100 ? String(firstLine.prefix(100)) + "..." : firstLine
    }
}
