# Sessylph Architecture

Internal architecture documentation for developers.

## High-Level Overview

```
┌─────────────────────────────────────────────────┐
│  Sessylph.app                                   │
│                                                  │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐      │
│  │  Tab 1   │  │  Tab 2   │  │  Tab 3   │ ...  │
│  │ (Window) │  │ (Window) │  │ (Window) │      │
│  └────┬─────┘  └────┬─────┘  └────┬─────┘      │
│       │              │              │            │
│  ┌────┴──────────────┴──────────────┴────┐      │
│  │         TabManager (singleton)        │      │
│  └───────────────────┬───────────────────┘      │
│                      │                           │
│  ┌───────────────────┴───────────────────┐      │
│  │  TabWindowController                  │      │
│  │  ┌─────────────┐ ┌─────────────────┐ │      │
│  │  │ LauncherView│→│TerminalView     │ │      │
│  │  │  (SwiftUI)  │ │(xterm.js/WebView)│ │      │
│  │  └─────────────┘ └────────┬────────┘ │      │
│  └────────────────────────────┼──────────┘      │
│                               │                  │
│  ┌────────────────────────────┴──────────┐      │
│  │          TmuxManager                  │      │
│  │  create / attach / kill / query       │      │
│  └────────────────────────────┬──────────┘      │
│                               │                  │
└───────────────────────────────┼──────────────────┘
                                │
                    ┌───────────┴───────────┐
                    │  tmux server          │
                    │  sessylph-XXXXXXXX    │ ← one session per tab
                    │  → claude (CLI)       │
                    └───────────────────────┘
```

## Directory Structure

```
Sources/
├── Sessylph/
│   ├── App/              AppDelegate, main, Info.plist
│   ├── Launcher/         LauncherView (SwiftUI directory picker + options)
│   ├── Models/           Session, SessionStore, ClaudeCodeOptions
│   ├── Notifications/    NotificationManager, HookSettingsGenerator
│   ├── Resources/        Assets
│   ├── Settings/         SettingsWindow, GeneralSettingsView, SessionConfigSheet
│   ├── Tabs/             TabManager, TabWindowController
│   ├── Terminal/         TerminalViewController (xterm.js/WKWebView host), TerminalBridge, WebResources/
│   ├── Tmux/             TmuxManager
│   └── Utilities/        ClaudeCLI, EnvironmentBuilder, Defaults, ShellQuote, ImagePasteHelper
└── SessylphNotifier/
    └── main.swift         Bundled CLI for hook → DistributedNotification bridge
```

## Core Components

### AppDelegate

Entry point. Responsible for:
- Menu bar setup (File, Edit, Window, Settings + Cmd+1–9 tab switching)
- DistributedNotificationCenter listener for hook events
- Notification permission request
- tmux server configuration (one-time, batched single invocation)
- Orphaned session reattachment on startup (two-phase: windows first, then tmux attach)
- PTY refresh on app activation (queries tmux window size, only bounces if mismatch)
- Quit flow with confirmation alerts

### TabManager (singleton, @MainActor)

Central registry of all open `TabWindowController` instances.

- `newTab()` / `newTab(directory:)` — Create launcher or pre-filled tabs
- `reattachOrphanedSessions()` — Restore running tmux sessions on app restart
- `findController(for:)` — Locate controller by Session ID
- `bringToFront()` — Navigate to a specific tab
- `saveActiveSessionId()` / `restoreActiveTab()` — Persist active tab across restarts

### TabWindowController (@MainActor)

One per tab. Manages the lifecycle from launcher → terminal.

**Two UI modes:**
1. **Launcher** — SwiftUI `LauncherView` for directory selection and Claude options
2. **Terminal** — `TerminalViewController` attached to a tmux session

**Launch flow:**
```
User clicks "Start Claude" in LauncherView
  → Button shows spinner, form disabled (immediate feedback)
  → Tab title updated with ⏳ emoji
  → HookSettingsGenerator.generate(sessionId) → /tmp/.../hooks-{id}.json
  → ClaudeCodeOptions.buildCommand() → full CLI string
  → TmuxManager.createAndLaunchSession()  ← single tmux invocation:
      new-session + set-option×4 + send-keys (was 6 process spawns)
  → Switch to TerminalViewController → attachToTmux()
```

**Title polling:** Every 2 seconds, queries tmux pane title and parses Claude Code's status emoji:
- `✳` (U+2733) → idle
- Braille spinner (U+2800–U+28FF) → working

### TerminalViewController

Hosts xterm.js inside a `WKWebView`, attaching to tmux via a PTY process running `tmux attach-session -t {name}`. Tmux attachment is deferred (not in `viewDidLoad`) — the parent calls `startTmuxAttach()` explicitly after the window is positioned, preventing buffer jumps from intermediate resizes.

**Scrollback preloading:** On reattach, `capture-pane -p -e -S -1000 -E -1` fetches tmux history and feeds it to xterm.js before PTY attach. Pre-fed history stays in xterm.js scrollback; tmux's cursor-positioning redraw only overwrites the viewport.

**PTY size refresh:** On app activation, queries tmux's actual window size via `display-message -p '#{window_width},#{window_height}'` and only performs a SIGWINCH bounce (rows+1 → rows) if sizes differ. Normal tab switching skips this entirely.

**TerminalBridge** — Bridges Swift ↔ JavaScript via `WKScriptMessageHandler`. Handles resize events, keyboard input, focus management, and data flow between PTY and xterm.js.

**Event handling (via xterm.js + JavaScript):**
- Shift+Enter → sends literal newline (LF)
- Cmd+V → image paste via `ImagePasteHelper`
- Selection → auto-copy to clipboard
- URL click detection → open in browser
- Scroll wheel → xterm.js native scrollback (tmux mouse off)

### TmuxManager (Sendable)

All tmux operations. Runs on `DispatchQueue.global()`, exposes async/await API. Commands are batched using tmux's `;` separator to minimize process spawns.

- **Session lifecycle:** `createAndLaunchSession()` (create + configure + launch in one invocation), `configureSession()` (for reattach), kill
- **Queries:** list sessions, get pane title, get current path, get window size
- **Server config:** Extended keys, CSI u, scroll bindings, window size "latest" (all batched into single invocation at startup)
- **Session naming:** `sessylph-{first 8 chars of UUID}`

### Models

**Session** (Identifiable, Codable, Sendable)
- `id`, `directory`, `options`, `tmuxSessionName`, `title`, `isRunning`, timestamps

**ClaudeCodeOptions** (Codable, Sendable)
- Model selection, permission modes, tool allow/deny lists, session flags, budget, system prompt, MCP configs
- `buildCommand()` — Constructs the full `claude` CLI invocation

**SessionStore** (@MainActor singleton)
- Persists `[Session]` to `~/Library/Application Support/sh.saqoo.Sessylph/sessions.json`

### Notifications

```
Claude Code hook fires
  → sessylph-notifier {sessionId} {event}    (bundled CLI)
  → reads stdin (hook context JSON)
  → DistributedNotificationCenter.post("sh.saqoo.Sessylph.hookEvent")

AppDelegate listener
  → extracts sessionId, event, message
  → TabWindowController.markNeedsAttention()
  → NotificationManager.postNeedsAttention()
  → UNUserNotificationCenter alert (if session not in foreground)

User clicks notification
  → TabManager.bringToFront(sessionId)
```

**HookSettingsGenerator** — Creates per-session JSON config at `/tmp/sh.saqoo.Sessylph/hooks-{id}.json` defining two hooks:
1. **Stop hook** — Claude completed a task
2. **Notification hook** — Claude needs permission

**SessylphNotifier** (separate build target, bundled in .app) — Lightweight CLI that reads stdin and posts a DistributedNotification. Decouples Claude Code hooks from the main app process.

### Settings & Preferences

**Defaults** — Static keys for `UserDefaults`:
- General: default model, permission mode
- Appearance: font name, font size (10–24pt)
- Notifications: enabled, notify on stop, notify on permission
- Launcher state: persisted between launches
- Alerts: suppress close/quit confirmations
- Session state: active session ID, recent directories

**SettingsWindow** — Modal SwiftUI window with `GeneralSettingsView` (model picker, permission mode, notification toggles, font slider, Claude version display).

### Utilities

| Utility | Purpose |
|---------|---------|
| `ClaudeCLI` | Resolves `claude` and `tmux` binary paths dynamically |
| `EnvironmentBuilder` | Captures login shell environment for process spawning |
| `ShellQuote` | Safe shell argument quoting |
| `ImagePasteHelper` | Extracts images from pasteboard, saves to temp, returns path |

## Concurrency Model

- **@MainActor:** AppDelegate, TabManager, TabWindowController, TerminalViewController, SessionStore, NotificationManager, SettingsWindow
- **Sendable (nonisolated):** TmuxManager, Session, ClaudeCodeOptions
- **Bridge pattern:** xterm.js ↔ Swift via WKScriptMessageHandler (TerminalBridge)

## Session Persistence & Reattachment

Sessions survive app restart because tmux sessions persist independently. Reattachment uses a two-phase approach to avoid visible buffer jumps:

```
App launches
  → TmuxManager.listSessylphSessions() → running tmux sessions
  → Compare with SessionStore (saved JSON)
  → Phase 1: Create all windows and add to tab group (no tmux attach yet)
      → Windows settle at their final size from frame autosave
      → Restore previously active tab
  → Phase 2: Start tmux attachment for all controllers
      → tmux only sees the correct final window size
```

## Window Management

- Native macOS tabbing via `NSWindow.tabbingMode = .preferred`
- Frame autosave: `NSWindowController.windowFrameAutosaveName = "SessylphTerminalWindow"`
- Tab order: `addTabbedWindow(newWindow, ordered: .above)` relative to last added window
- Cmd+1–9 switching: `NSEvent.addLocalMonitorForEvents(matching: .keyDown)`
