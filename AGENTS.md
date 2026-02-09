# Sessylph - Claude Code Wrapper for macOS

## Project Overview
macOS native app wrapping Claude Code CLI with tabs, tmux session management, notifications, and configurable options.

## Tech Stack
- macOS 15.0+ (Sequoia), Swift 6
- AppKit-primary + SwiftUI for settings/dialogs
- xterm.js in WKWebView for terminal emulation
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
- Each tab = one tmux session running Claude Code
- xterm.js (WKWebView) connects via PTY to `tmux attach-session`
- Terminal rendering: xterm.js with WebGL → Canvas → DOM fallback chain
- Notifications via Claude Code hooks + sessylph-notifier CLI → DistributedNotificationCenter
- Sessions survive app restart (tmux persistence)
- Native window tabbing: `NSWindow.tabbingMode = .preferred`

## Key Patterns
- Bundle ID: sh.saqoo.Sessylph
- Development Team: G5G54TCH8W
- VCS: jj (Jujutsu)
- CLI paths resolved dynamically (claude, tmux)
- Login shell environment captured for process spawning
