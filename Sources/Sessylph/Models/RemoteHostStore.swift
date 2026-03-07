import Foundation
import os.log

private let logger = Logger(subsystem: "sh.saqoo.Sessylph", category: "RemoteHostStore")

@MainActor
final class RemoteHostStore: ObservableObject {
    static let shared = RemoteHostStore()

    @Published var hosts: [RemoteHost] = []

    private var storageURL: URL? {
        guard let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first else {
            logger.error("Application Support directory not found")
            return nil
        }
        let appDir = appSupport.appendingPathComponent("sh.saqoo.Sessylph")
        return appDir.appendingPathComponent("remote-hosts.json")
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
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            logger.error("Failed to create directory: \(error.localizedDescription)")
            return
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        do {
            let data = try encoder.encode(hosts)
            try data.write(to: storageURL, options: .atomic)
        } catch {
            logger.error("Failed to save remote hosts: \(error.localizedDescription)")
        }
    }

    func load() {
        guard let storageURL else {
            logger.error("Cannot load: storage URL unavailable")
            hosts = []
            return
        }
        guard FileManager.default.fileExists(atPath: storageURL.path) else {
            hosts = []
            return
        }

        do {
            let data = try Data(contentsOf: storageURL)
            hosts = try JSONDecoder().decode([RemoteHost].self, from: data)
        } catch {
            logger.error("Failed to load remote hosts: \(error.localizedDescription)")
            hosts = []
        }
    }

    func add(_ host: RemoteHost) {
        hosts.append(host)
        save()
    }

    func update(_ host: RemoteHost) {
        guard let index = hosts.firstIndex(where: { $0.id == host.id }) else { return }
        hosts[index] = host
        save()
    }

    func remove(id: UUID) {
        hosts.removeAll { $0.id == id }
        save()
    }
}
