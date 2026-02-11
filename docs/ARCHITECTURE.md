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
│  │  │  (SwiftUI)  │ │(GhosttyKit/    │ │      │
│  │  │             │ │ Metal)          │ │      │
│  │  └─────────────┘ └────────┬────────┘ │      │
│  │                    ClaudeStateTracker │      │
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
│   ├── Tabs/             TabManager, TabWindowController, ClaudeStateTracker
│   ├── Terminal/         GhosttyTerminalView, GhosttyApp, GhosttyConfig,
│   │                     GhosttyInputHandler, TerminalViewController
│   ├── Tmux/             TmuxManager
│   └── Utilities/        ClaudeCLI, EnvironmentBuilder, Defaults, ShellQuote,
│                         ImagePasteHelper, PermissionMode, RecentDirectories
├── SessylphNotifier/
│   └── main.swift         Bundled CLI for hook → DistributedNotification bridge
ghostty/
└── Vendor/               ghostty.h, libghostty.a (LFS), module.modulemap
```

## Core Components

### AppDelegate

Entry point. Responsible for:
- Menu bar setup (App, File, Edit, Window menus + Cmd+1–9 tab switching)
  - Standard macOS items: Hide, Hide Others, Show All, Settings
- DistributedNotificationCenter listener for hook events
- Notification permission request
- Auto-activate on task completion (`activateOnStop` preference) — brings app + tab to front
  - Handles hidden app state (`NSApp.unhide` + delayed activation)
  - Pre-computes `isFrontmost` before state changes to avoid notification suppression race
- Orphaned session reattachment on startup (two-phase: windows first, then tmux attach)
- PTY refresh on app activation (queries tmux window size, only bounces if mismatch)
- Quit flow with confirmation alerts

### TabManager (singleton, @MainActor)

Central registry of all open `TabWindowController` instances.

- `newTab()` / `newTab(directory:)` — Create launcher or pre-filled tabs
- `reattachOrphanedSessions()` — Restore running tmux sessions on app restart
- `findController(for:)` — Locate controller by Session ID
- `bringToFront(sessionId:)` — Navigate to a specific tab (handles hidden app state with unhide + delayed activate)
- `saveActiveSessionId()` / `restoreActiveTab()` — Persist active tab across restarts
- `addToTabGroup(_:in:)` — Private helper deduplicating tab group insertion logic

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

**State tracking:** Delegates to `ClaudeStateTracker`, which polls tmux pane title every 1 second and parses Claude Code's status emoji:
- `✳` (U+2733) → idle
- Braille spinner (U+2800–U+28FF) → working (animated spinner in tab title)
- `needsAttention` flag → set by notification hooks

### ClaudeStateTracker

Extracted from TabWindowController. Encapsulates:
- `ClaudeState` enum (idle, working, needsAttention, unknown)
- `parseClaudeTitle()` — Maps terminal title prefix to state
- Timer-based polling (1s interval on main run loop, works for inactive tabs)
- Tab title spinner animation
- `ClaudeStateTrackerDelegate` protocol for state change notifications

### TerminalViewController

Hosts a `GhosttyTerminalView` (Metal-rendered NSView), attaching to tmux via a PTY process running `tmux attach-session -t {name}`. Tmux attachment is deferred (not in `viewDidLoad`) — the parent calls `startTmuxAttach()` explicitly after the window is positioned, preventing buffer jumps from intermediate resizes.

**Working directory isolation:** The ghostty surface uses `/tmp` as its working directory (not the project directory) to avoid triggering macOS TCC prompts for ~/Documents. The actual working directory is managed by tmux via `new-session -c`.

### Terminal Rendering (GhosttyKit)

**GhosttyTerminalView** (NSView) — Wraps a ghostty surface for Metal-accelerated terminal rendering.
- Creates `ghostty_surface_t` with command, working directory, and environment variables
- C interop: uses `strdup()`/`free()` for env var strings to ensure pointer lifetime safety
- Handles title changes and process exit via callbacks
- `nonisolated(unsafe)` surface property allows deinit cleanup

**GhosttyApp** (singleton) — Manages the `ghostty_app_t` lifecycle.
- Initializes ghostty runtime with config from `GhosttyConfig`
- Handles action dispatch (new tab, close surface, render, clipboard operations)
- Clipboard callbacks dispatched to main queue for thread safety
- `surfaceView(from:)` helper to resolve surface → NSView

**GhosttyConfig** — Builds ghostty configuration from user preferences.
- Font family + size from `UserDefaults`
- Scrollback lines, cursor style, theme
- tmux-friendly terminal overrides

**GhosttyInputHandler** — Routes keyboard and IME input to ghostty.
- `keyDown()` passes raw virtual keycodes + accumulated text
- `insertText()` accumulates IME text for the next `keyDown()`
- `doCommand(by:)` overridden to suppress NSBeep on backspace
- Copy/paste implemented via `copy(_ sender:)` / `paste(_ sender:)` responders

### TmuxManager (Sendable)

All tmux operations. Runs on `DispatchQueue.global()`, exposes async/await API. Commands are batched using tmux's `;` separator to minimize process spawns.

- **Session lifecycle:** `createAndLaunchSession()` (create + configure + launch in one invocation), `configureSession()` (for reattach), kill
- **Queries:** list sessions, get pane title, get current path, get window size, capture pane history
- **Server config:** Extended keys, CSI u, alternate screen disabled (smcup@:rmcup@), mouse off, window size "latest" (all batched into session creation)
- **Session naming:** `sessylph-{first 8 chars of UUID}`

### Models

**Session** (Identifiable, Codable, Sendable)
- `id`, `directory`, `options`, `tmuxSessionName`, `isRunning`, `createdAt`
- `title` is computed from `directory.lastPathComponent`
- `CodingKeys` excludes `isRunning` (transient runtime state)

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
  → pre-computes isFrontmost before any state changes
  → "stop" event + activateOnStop preference:
      → TabManager.bringToFront(sessionId) — activates app/tab
      → 0.5s delayed notification post (avoids macOS swallowing it during activation)
  → "permission_prompt" → TabWindowController.markNeedsAttention()
  → NotificationManager posts UNUserNotification (if not frontmost)

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
- Behavior: activate on task completion (`activateOnStop`)
- Launcher state: persisted between launches
- Alerts: suppress close/quit confirmations
- Session state: active session ID, recent directories

**SettingsWindow** — Modal SwiftUI window with `GeneralSettingsView` (model picker, permission mode, notification toggles, font slider, Claude version display).

### Utilities

| Utility | Purpose |
|---------|---------|
| `ClaudeCLI` | Resolves `claude` and `tmux` binary paths dynamically |
| `EnvironmentBuilder` | Captures login shell environment (thread-safe with `OSAllocatedUnfairLock`) |
| `ShellQuote` | Safe shell argument quoting (enum namespace) |
| `ImagePasteHelper` | Extracts images from pasteboard, saves to temp, returns path |
| `PermissionMode` | Shared permission mode label formatting |
| `RecentDirectories` | Recent directory picker history |

## Concurrency Model

- **@MainActor:** AppDelegate, TabManager, TabWindowController, TerminalViewController, SessionStore, NotificationManager, SettingsWindow, ClaudeStateTracker
- **Sendable (nonisolated):** TmuxManager, Session, ClaudeCodeOptions
- **Thread safety:** `OSAllocatedUnfairLock` for `EnvironmentBuilder` cache, `DispatchQueue.main.async` for ghostty clipboard callbacks
- **C interop:** `nonisolated(unsafe)` on ghostty surface property for deinit access

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
