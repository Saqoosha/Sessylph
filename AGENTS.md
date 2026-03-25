# Sessylph - Claude Code / Codex Wrapper for macOS

## Project Overview
macOS native app wrapping Claude Code and Codex CLI with tabs, tmux session management, notifications, remote SSH sessions, and configurable options.

## Tech Stack
- macOS 15.0+ (Sequoia), Swift 6
- AppKit-primary + SwiftUI for settings/dialogs
- GhosttyKit (libghostty v1.3.0) for Metal-accelerated terminal rendering
- tmux for session management (enables remote SSH access)
- xcodegen for project generation from `project.yml`

## Build Commands
```bash
# Generate Xcode project
xcodegen generate

# Build
xcodebuild -scheme Sessylph -configuration Debug -derivedDataPath build build

# Run
open build/Build/Products/Debug/Sessylph.app

# Kill running instance
pgrep -x Sessylph | xargs kill 2>/dev/null; true
```

## Architecture
- Each tab = one tmux session running the selected CLI (Claude Code or Codex)
- GhosttyKit (Metal) terminal view connects via PTY to `tmux attach-session`
- Terminal rendering: GhosttyKit (libghostty) with native Metal GPU rendering
- `ClaudeStateTracker` parses terminal title to detect Claude idle/working/attention states
- Notifications: local via Claude Code hooks / Codex notify + `sessylph-notifier` CLI → DistributedNotificationCenter; remote via title polling (working → idle detection)
- Hook events handled: `stop`, `stop_failure`, `notify`, `permission_prompt`, `permission_denied` (auto mode denials), `idle_prompt`, `user_prompt`
- Remote SSH sessions: connect to configured hosts, browse directories, launch Claude Code over SSH with tmux
- Launcher supports recent Claude Code, Codex, and remote session history with click-to-resume
- Sessions survive app restart (tmux persistence)
- Native window tabbing: `NSWindow.tabbingMode = .preferred`
- Settings window: NSToolbar + `toolbarStyle(.preference)` with SwiftUI content views

## Key Source Files
- `GhosttyTerminalView.swift` — NSView wrapping ghostty surface (Metal rendering, input handling)
- `GhosttyApp.swift` — ghostty_app lifecycle, action dispatch, clipboard callbacks
- `GhosttyConfig.swift` — ghostty configuration (font family/size, theme, scrollback)
- `GhosttyInputHandler.swift` — keyboard/IME input routing to ghostty
- `TerminalViewController.swift` — tab content controller, tmux attach orchestration, pane monitor (dynamic mouse mode)
- `TabWindowController.swift` — NSWindowController, tab management, state delegation
- `ClaudeStateTracker.swift` — title polling, Claude idle/working/attention state machine
- `CLIType.swift` — enum for Claude Code / Codex CLI selection
- `ClaudeCodeOptions.swift` — Claude Code options (model, effort level, permission mode, bare mode, channels, noFlicker, etc.)
- `CodexOptions.swift` — Codex options (model, approval mode, resume session)
- `CodexSessionHistory.swift` — parses recent Codex sessions from `~/.codex` for launcher resume
- `TmuxManager.swift` — tmux session lifecycle (create, configure, attach, destroy) + remote SSH commands + pane count / mouse mode
- `EnvironmentBuilder.swift` — login shell environment capture (thread-safe cached)
- `LaunchConfig.swift` — shared launcher config for Claude Code / Codex / remote session startup
- `CodexCLI.swift` — Codex CLI resolution and launcher option discovery
- `RemoteHost.swift` — remote host model with SSH args builder and validation
- `RemoteHostStore.swift` — persistent storage for remote host configurations
- `RemoteHistory.swift` — MRU list of remote host:directory pairs
- `RemoteDirectoryBrowser.swift` — SSH directory listing for remote host file browser
- `RemoteHostsSettingsView.swift` — settings tab for managing remote hosts
- `SessionConfigSheet.swift` — pre-launch config sheet (model, effort, permission mode, toggles)
- `SettingsWindow.swift` — NSToolbar-based settings window (General + Remote Hosts tabs)
- `TabManager.swift` — multi-window tab group coordination
- `CommandStripView.swift` — bottom bar with MRU-sorted slash command and phrase shortcut buttons
- `CommandListPopover.swift` — popover showing all recorded commands with search and manual add
- `SlashCommand.swift` — command data model (command/phrase, usage count, global/project scope)
- `SlashCommandStore.swift` — command usage persistence with built-in classification and per-project storage

## Automation
- `scripts/auto-adopt.sh` — daily pipeline that monitors Claude Code releases, analyzes changelog with Claude Code CLI, implements changes in an isolated jj worktree, and creates PRs after build verification
- `sh.saqoo.sessylph.auto-adopt.plist` — launchd config for daily execution (9:00 JST)
- See [docs/auto-adopt.md](docs/auto-adopt.md) for setup instructions

## Rendering Modes
Sessylph supports two rendering modes per session:

### Terminal Mode (v1, default)
- GhosttyKit (libghostty Metal) + tmux
- Used for: all CLI types (Claude Code, Codex, Cursor Agent)
- State detection: terminal title polling via ClaudeStateTracker
- Files: `Terminal/Ghostty*.swift`, `Terminal/TerminalViewController.swift`

### Native UI Mode (v2, Claude Code only)
- SwiftUI chat interface via `--sdk-url` WebSocket protocol
- Claude Code CLI spawned with `--sdk-url ws://localhost:PORT/ws/cli/SESSION_ID --print --output-format stream-json --input-format stream-json --include-partial-messages`
- `--sdk-url` is a hidden flag in Claude Code CLI v2.1.83+ (NOT in `--help`)
- NDJSON messages over WebSocket: system/init, assistant, stream_event, control_request, result, etc.
- Permission handling via native dialogs (control_request/control_response)
- Remote SSH via reverse tunnel (`ssh -R remotePort:localhost:localWSPort`)
- Session persistence via `--resume` (no tmux needed)
- NOT available for Codex or Cursor Agent (they lack `--sdk-url`)
- Files: `Protocol/`, `ChatUI/`, `Session/`
- Reference: [The Companion](https://github.com/The-Vibe-Company/companion) for protocol, [ClaudeCodeSDK](https://github.com/jamesrochabrun/ClaudeCodeSDK) for Swift patterns
- Plan: `docs/superpowers/plans/2026-03-26-sessylph-v2-native-ui.md`
- Analysis: `docs/vscode-extension-rendering-analysis.md`

### Key Native UI Source Files (v2)
- `Protocol/WebSocketServer.swift` — NWListener-based local WebSocket server
- `Protocol/NDJSONParser.swift` — NDJSON stream parser (actor, buffer-based)
- `Protocol/StreamMessage.swift` — All message type models (system, assistant, stream_event, control_request, result, etc.)
- `ChatUI/ChatViewController.swift` — Integration controller (wires ChatView ↔ CLIProcessManager ↔ WebSocket)
- `ChatUI/ChatView.swift` — Main chat layout + ChatViewModel (@Observable)
- `ChatUI/MessageBubble.swift` — Message rendering (text, thinking, tool_use, tool_result)
- `ChatUI/ToolCallCard.swift` — Collapsible tool card with IN/OUT grid (Bash, Edit, Read, Write, etc.)
- `ChatUI/PermissionBanner.swift` — Inline allow/deny banner for tool permissions
- `ChatUI/ChatInputView.swift` — User prompt input with slash command autocomplete
- `Session/CLIProcessManager.swift` — Claude CLI process lifecycle (spawn, monitor, restart)
- `Session/SessionStateMachine.swift` — State transitions (idle → starting → ready → streaming → ...)
- `Session/RemoteCLIManager.swift` — SSH reverse tunnel + remote claude --sdk-url

### WebSocket Protocol Quick Reference
```
App → CLI (outbound):
  user message, control_response (allow/deny), interrupt, set_model, set_permission_mode, rewind_files, mcp_*

CLI → App (inbound):
  system/init, assistant, stream_event, control_request (can_use_tool), result, tool_progress, keep_alive
```

## Key Patterns
- Bundle ID: sh.saqoo.Sessylph
- Development Team: G5G54TCH8W
- VCS: jj (Jujutsu)
- CLI paths resolved dynamically (`claude`, `codex`, `tmux`)
- Login shell environment captured for process spawning
- C interop: `strdup`/`free` for env vars passed to ghostty (pointer lifetime safety)
- Thread safety: `OSAllocatedUnfairLock` for shared mutable state
- TCC mitigation: all `Process()` and ghostty surface use `/tmp` as working directory
- Shell safety: `shellQuote()` for tmux session names, `shellEscape()` for paths in remote commands
- Remote tmux: `=` prefix not supported over SSH, use plain session names for remote `-t` targets
