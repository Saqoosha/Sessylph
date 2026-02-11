import Foundation

/// Namespace for shell quoting utilities.
enum ShellQuote {
    /// Wraps a string in single quotes if it contains shell-sensitive characters.
    static func quote(_ value: String) -> String {
        guard !value.isEmpty else { return "''" }
        let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._/~+:@"))
        if value.unicodeScalars.allSatisfy({ safe.contains($0) }) {
            return value
        }
        let escaped = value.replacingOccurrences(of: "'", with: "'\\''")
        return "'\(escaped)'"
    }
}

/// Backward-compatible free function wrapping `ShellQuote.quote(_:)`.
func shellQuote(_ value: String) -> String { ShellQuote.quote(value) }
