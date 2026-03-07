# Sessylph - Claude Code / Codex Wrapper for macOS

## Project Overview
macOS native app wrapping Claude Code and Codex CLI with tabs, tmux session management, notifications, and configurable options.

## Tech Stack
- macOS 15.0+ (Sequoia), Swift 6
- AppKit-primary + SwiftUI for settings/dialogs
- GhosttyKit (libghostty) for Metal-accelerated terminal rendering
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
- Notifications via Claude Code hooks / Codex notify + `sessylph-notifier` CLI → DistributedNotificationCenter
- Launcher supports recent Claude Code and Codex session history with click-to-resume
- Sessions survive app restart (tmux persistence)
- Native window tabbing: `NSWindow.tabbingMode = .preferred`

## Key Source Files
- `GhosttyTerminalView.swift` — NSView wrapping ghostty surface (Metal rendering, input handling)
- `GhosttyApp.swift` — ghostty_app lifecycle, action dispatch, clipboard callbacks
- `GhosttyConfig.swift` — ghostty configuration (font, theme, scrollback)
- `GhosttyInputHandler.swift` — keyboard/IME input routing to ghostty
- `TerminalViewController.swift` — tab content controller, tmux attach orchestration
- `TabWindowController.swift` — NSWindowController, tab management, state delegation
- `ClaudeStateTracker.swift` — title polling, Claude idle/working/attention state machine
- `CodexSessionHistory.swift` — parses recent Codex sessions from `~/.codex` for launcher resume
- `TmuxManager.swift` — tmux session lifecycle (create, configure, attach, destroy)
- `EnvironmentBuilder.swift` — login shell environment capture (thread-safe cached)
- `LaunchConfig.swift` — shared launcher config for Claude Code / Codex session startup
- `CodexCLI.swift` — Codex CLI resolution and launcher option discovery
- `TabManager.swift` — multi-window tab group coordination

## Key Patterns
- Bundle ID: sh.saqoo.Sessylph
- Development Team: G5G54TCH8W
- VCS: jj (Jujutsu)
- CLI paths resolved dynamically (`claude`, `codex`, `tmux`)
- Login shell environment captured for process spawning
- C interop: `strdup`/`free` for env vars passed to ghostty (pointer lifetime safety)
- Thread safety: `OSAllocatedUnfairLock` for shared mutable state
- TCC mitigation: all `Process()` and ghostty surface use `/tmp` as working directory
