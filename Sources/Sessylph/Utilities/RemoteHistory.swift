import Foundation

struct RemoteHistoryEntry: Codable, Identifiable, Hashable {
    var id: String { "\(hostId.uuidString):\(directory)" }
    let hostId: UUID
    let directory: String
    var lastUsed: Date
}

enum RemoteHistory {
    static let maxCount = 50
    private static let key = "remoteHistory"

    @MainActor
    static func load() -> [RemoteHistoryEntry] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let entries = try? JSONDecoder().decode([RemoteHistoryEntry].self, from: data)
        else { return [] }
        let hostIds = Set(RemoteHostStore.shared.hosts.map(\.id))
        return entries.filter { hostIds.contains($0.hostId) }
    }

    static func add(hostId: UUID, directory: String) {
        var entries = allEntries()
        entries.removeAll { $0.hostId == hostId && $0.directory == directory }
        entries.insert(RemoteHistoryEntry(hostId: hostId, directory: directory, lastUsed: Date()), at: 0)
        if entries.count > maxCount {
            entries = Array(entries.prefix(maxCount))
        }
        save(entries)
    }

    static func remove(_ entry: RemoteHistoryEntry) {
        var entries = allEntries()
        entries.removeAll { $0.hostId == entry.hostId && $0.directory == entry.directory }
        save(entries)
    }

    // Internal: load without filtering deleted hosts (for add/remove)
    private static func allEntries() -> [RemoteHistoryEntry] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let entries = try? JSONDecoder().decode([RemoteHistoryEntry].self, from: data)
        else { return [] }
        return entries
    }

    private static func save(_ entries: [RemoteHistoryEntry]) {
        if let data = try? JSONEncoder().encode(entries) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
