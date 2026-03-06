import Foundation

enum CLIResolver {
    enum ResolveError: Error, LocalizedError {
        case notFound(String)

        var errorDescription: String? {
            switch self {
            case .notFound(let name):
                return "\(name) not found in PATH or common locations"
            }
        }
    }

    static func resolve(name: String, knownPaths: [String]) throws -> String {
        // Check known paths first
        for path in knownPaths {
            let resolved = resolveSymlink(path)
            if FileManager.default.isExecutableFile(atPath: resolved) {
                return path
            }
        }

        // Try `which` via the login shell environment
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-l", "-c", "which \(name)"]
        process.currentDirectoryURL = URL(fileURLWithPath: NSTemporaryDirectory())

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            throw ResolveError.notFound(name)
        }

        // Read before waitUntilExit to avoid pipe buffer deadlock
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        if process.terminationStatus == 0 {
            if let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !path.isEmpty
            {
                return path
            }
        }

        throw ResolveError.notFound(name)
    }

    /// Runs `--version` on the executable and returns the output.
    static func versionOutput(for pathProvider: () throws -> String, firstLineOnly: Bool = false) -> String? {
        guard let path = try? pathProvider() else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["--version"]
        process.currentDirectoryURL = URL(fileURLWithPath: NSTemporaryDirectory())

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return nil
        }

        // Read before waitUntilExit to avoid pipe buffer deadlock
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return firstLineOnly ? output?.components(separatedBy: "\n").first : output
    }

    private static func resolveSymlink(_ path: String) -> String {
        (try? FileManager.default.destinationOfSymbolicLink(atPath: path)) ?? path
    }
}
