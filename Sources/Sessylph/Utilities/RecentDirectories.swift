import Foundation

// MARK: - Recent Directories

enum RecentDirectories {
    static let maxCount = 10

    static func load() -> [URL] {
        guard let paths = UserDefaults.standard.stringArray(forKey: Defaults.recentDirectories) else {
            return []
        }
        return paths.map { URL(fileURLWithPath: $0) }
    }

    static func remove(_ url: URL) {
        var paths = UserDefaults.standard.stringArray(forKey: Defaults.recentDirectories) ?? []
        paths.removeAll { $0 == url.path }
        UserDefaults.standard.set(paths, forKey: Defaults.recentDirectories)
    }

    static func add(_ url: URL) {
        var paths = UserDefaults.standard.stringArray(forKey: Defaults.recentDirectories) ?? []
        paths.removeAll { $0 == url.path }
        paths.insert(url.path, at: 0)
        if paths.count > maxCount {
            paths = Array(paths.prefix(maxCount))
        }
        UserDefaults.standard.set(paths, forKey: Defaults.recentDirectories)
    }
}

// MARK: - URL Extension

extension URL {
    var abbreviatingWithTildeInPath: String {
        (path as NSString).abbreviatingWithTildeInPath
    }
}
