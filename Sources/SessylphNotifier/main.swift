import Foundation

/// sessylph-notifier: Bundled CLI tool that relays Claude Code hook events
/// to the main Sessylph app via DistributedNotificationCenter.
///
/// Usage: sessylph-notifier <sessionId> <event>
///   event: "stop" | "permission_prompt" | "idle_prompt"
///
/// Called by Claude Code hooks (via --settings).
/// Reads hook context from stdin (JSON) when available, posts a distributed
/// notification that the main app listens for.

let args = CommandLine.arguments
guard args.count >= 3 else {
    fputs("Usage: sessylph-notifier <sessionId> <event>\n", stderr)
    exit(1)
}

let sessionId = args[1]
let event = args[2]

// Read stdin (Claude Code hook context JSON), but don't block forever
var stdinData = Data()
let stdinHandle = FileHandle.standardInput
if isatty(STDIN_FILENO) == 0 {
    stdinData = stdinHandle.readDataToEndOfFile()
}

// Try to extract useful info from hook context
var message = ""
if !stdinData.isEmpty,
   let json = try? JSONSerialization.jsonObject(with: stdinData) as? [String: Any]
{
    if let hookMessage = json["message"] as? String {
        message = hookMessage
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
