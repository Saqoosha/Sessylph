import Foundation

struct RemoteHost: Codable, Sendable, Identifiable, Hashable {
    let id: UUID
    var label: String          // User-friendly name (e.g. "Dev Server")
    var host: String           // hostname or IP
    var user: String?          // SSH user (nil = current user)
    var port: Int?             // SSH port (nil = default 22)
    var identityFile: String?  // Path to SSH identity file (nil = default)

    init(label: String, host: String, user: String? = nil, port: Int? = nil, identityFile: String? = nil) {
        self.id = UUID()
        self.label = label
        self.host = host
        self.user = user
        self.port = port
        self.identityFile = identityFile
    }

    /// Whether this host configuration is valid for saving.
    var isValid: Bool {
        !label.isEmpty
            && !host.isEmpty
            && !host.hasPrefix("-")
            && (port == nil || (1...65535).contains(port!))
    }

    /// Display name for UI (e.g. "Dev Server (user@host)")
    var displayName: String {
        let userHost = user.map { "\($0)@\(host)" } ?? host
        return "\(label) (\(userHost))"
    }

    /// Builds SSH command-line arguments for connecting to this host.
    /// Does NOT include the "ssh" executable itself.
    /// Example: ["-o", "ConnectTimeout=5", "-p", "2222", "-i", "/path/to/key", "user@host"]
    var sshArgs: [String] {
        var args: [String] = ["-o", "ConnectTimeout=10", "-o", "ServerAliveInterval=30", "-o", "ServerAliveCountMax=3"]
        if let port {
            args += ["-p", String(port)]
        }
        if let identityFile {
            args += ["-i", identityFile]
        }
        let target = user.map { "\($0)@\(host)" } ?? host
        args.append(target)
        return args
    }

    /// SSH destination string for display (e.g. "user@host:2222" or "host")
    var sshDestination: String {
        var result = user.map { "\($0)@\(host)" } ?? host
        if let port {
            result += ":\(port)"
        }
        return result
    }
}
