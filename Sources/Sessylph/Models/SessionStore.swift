import Foundation
import os.log

private let logger = Logger(subsystem: "sh.saqoo.Sessylph", category: "SessionStore")

@MainActor
final class SessionStore: ObservableObject {
    static let shared = SessionStore()

    @Published var sessions: [Session] = []

    private var storageURL: URL? {
        guard let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first else {
            logger.error("Application Support directory not found")
            return nil
        }
        let appDir = appSupport.appendingPathComponent("sh.saqoo.Sessylph")
        return appDir.appendingPathComponent("sessions.json")
    }

    private init() {
        load()
    }

    func save() {
        guard let storageURL else {
            logger.error("Cannot save: storage URL unavailable")
            return
        }
        let dir = storageURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: dir, withIntermediateDirectories: true
            )
        } catch {
            logger.error("Failed to create directory: \(error.localizedDescription)")
            return
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        do {
            let data = try encoder.encode(sessions)
            try data.write(to: storageURL, options: .atomic)
        } catch {
            logger.error("Failed to save sessions: \(error.localizedDescription)")
        }
    }

    func load() {
        guard let storageURL else {
            logger.error("Cannot load: storage URL unavailable")
            sessions = []
            return
        }
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
            logger.error("Failed to load sessions: \(error.localizedDescription)")
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
