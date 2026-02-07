import Foundation

@MainActor
final class SessionStore: ObservableObject {
    static let shared = SessionStore()

    @Published var sessions: [Session] = []

    private var storageURL: URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        let appDir = appSupport.appendingPathComponent("sh.saqoo.Sessylph")
        return appDir.appendingPathComponent("sessions.json")
    }

    private init() {
        load()
    }

    func save() {
        let dir = storageURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: dir, withIntermediateDirectories: true
            )
        } catch {
            print("SessionStore: failed to create directory: \(error)")
            return
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        do {
            let data = try encoder.encode(sessions)
            try data.write(to: storageURL, options: .atomic)
        } catch {
            print("SessionStore: failed to save: \(error)")
        }
    }

    func load() {
        guard FileManager.default.fileExists(atPath: storageURL.path) else {
            sessions = []
            return
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        do {
            let data = try Data(contentsOf: storageURL)
            sessions = try decoder.decode([Session].self, from: data)
        } catch {
            print("SessionStore: failed to load: \(error)")
            sessions = []
        }
    }

    func add(_ session: Session) {
        sessions.append(session)
        save()
    }

    func remove(id: UUID) {
        sessions.removeAll { $0.id == id }
        save()
    }

    func update(_ session: Session) {
        guard let index = sessions.firstIndex(where: { $0.id == session.id }) else {
            return
        }
        sessions[index] = session
        save()
    }
}
