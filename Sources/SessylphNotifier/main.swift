import Foundation

/// sessylph-notifier: Bundled CLI tool that relays Claude Code / Codex hook events
/// to the main Sessylph app via DistributedNotificationCenter.
///
/// Usage: sessylph-notifier <sessionId> <event> [json]
///   event: "stop" | "notify" | "permission_prompt" | "idle_prompt" | "user_prompt"
///
/// Called by Claude Code hooks (via --settings) with JSON on stdin,
/// or by Codex notify hooks with JSON as argv[3].

let args = CommandLine.arguments
guard args.count >= 3 else {
    fputs("Usage: sessylph-notifier <sessionId> <event> [json]\n", stderr)
    exit(1)
}

let sessionId = args[1]
let event = args[2]

// Try to extract useful info from hook context JSON.
// Claude Code sends JSON via stdin; Codex sends it as argv[3].
var message = ""

func extractMessage(from data: Data) -> String? {
    guard !data.isEmpty,
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return nil }
    // UserPromptSubmit uses "prompt"
    if let prompt = json["prompt"] as? String { return prompt }
    // Claude Code uses "message"
    if let hookMessage = json["message"] as? String { return hookMessage }
    // Codex uses "last-assistant-message" or "summary"
    if let summary = json["summary"] as? String { return summary }
    if let lastMessage = json["last-assistant-message"] as? String {
        // Truncate long messages
        return String(lastMessage.prefix(200))
    }
    return nil
}

// Check argv[3] first (Codex notify hook)
if args.count >= 4, let data = args[3].data(using: .utf8) {
    message = extractMessage(from: data) ?? ""
}

// Fall back to stdin (Claude Code hook)
if message.isEmpty {
    let stdinHandle = FileHandle.standardInput
    if isatty(STDIN_FILENO) == 0 {
        let stdinData = stdinHandle.readDataToEndOfFile()
        message = extractMessage(from: stdinData) ?? ""
    }
}

// Post distributed notification to the main app
let userInfo: [String: String] = [
    "sessionId": sessionId,
    "event": event,
    "message": message,
]

DistributedNotificationCenter.default().postNotificationName(
    NSNotification.Name("sh.saqoo.Sessylph.hookEvent"),
    object: nil,
    userInfo: userInfo,
    deliverImmediately: true
)
