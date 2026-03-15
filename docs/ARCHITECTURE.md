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
│  │  local + remote SSH commands          │      │
│  └────────────────────────────┬──────────┘      │
│                               │                  │
└───────────────────────────────┼──────────────────┘
                                │
                    ┌───────────┴───────────┐
                    │  tmux server          │
                    │  sessylph-XXXXXXXX    │ ← one session per tab
                    │  → selected CLI       │ (local or remote via SSH)
                    └───────────────────────┘
```

## Directory Structure

```
Sources/
├── Sessylph/
│   ├── App/              AppDelegate, main, Info.plist
│   ├── Launcher/         LauncherView (SwiftUI directory picker + CLI options),
│   │                     RemoteDirectoryBrowser, ComboBox
│   ├── Models/           Session, SessionStore, LaunchConfig, CLIType,
│   │                     Claude/Codex options, Claude/Codex session history,
│   │                     RemoteHost, RemoteHostStore, RemoteHistory,
│   │                     SlashCommand
│   ├── Notifications/    NotificationManager, HookSettingsGenerator
│   ├── Resources/        Assets
│   ├── Settings/         SettingsWindow (NSToolbar), GeneralSettingsView (font picker),
│   │                     RemoteHostsSettingsView, SessionConfigSheet (pre-launch config)
│   ├── Tabs/             TabManager, TabWindowController, ClaudeStateTracker
│   ├── Terminal/         GhosttyTerminalView, GhosttyApp, GhosttyConfig,
│   │                     GhosttyInputHandler, TerminalViewController,
│   │                     CommandStripView, CommandListPopover
│   ├── Tmux/             TmuxManager
│   └── Utilities/        ClaudeCLI, CodexCLI, CLIResolver, EnvironmentBuilder,
│                         Defaults, ShellQuote, ImagePasteHelper, PermissionMode,
│                         RecentDirectories, SlashCommandStore
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
- Auto-activate on task completion (`activateOnStop` preference) — brings app + tab to front for Claude Code stop events
  - Handles hidden app state (`NSApp.unhide` + delayed activation)
  - Pre-computes `isFrontmost` before state changes to avoid notification suppression race
- Codex `notify` events are handled as handoff-to-user notifications
- Orphaned session reattachment on startup (two-phase: windows first, then tmux attach)
- PTY refresh on app activation (queries tmux window size, only bounces if mismatch)
- Quit flow with confirmation alerts

### TabManager (singleton, @MainActor)

Central registry of all open `TabWindowController` instances.

- `newTab()` / `newTab(directory:)` — Create launcher or pre-filled tabs
- `newTab(directory:)` respects the saved default CLI type
- `reattachOrphanedSessions()` — Restore running tmux sessions on app restart
- `findController(for:)` — Locate controller by Session ID
- `bringToFront(sessionId:)` — Navigate to a specific tab (handles hidden app state with unhide + delayed activate)
- `saveActiveSessionId()` / `restoreActiveTab()` — Persist active tab across restarts
- `addToTabGroup(_:in:)` — Private helper deduplicating tab group insertion logic

### TabWindowController (@MainActor)

One per tab. Manages the lifecycle from launcher → terminal.

**Two UI modes:**
1. **Launcher** — SwiftUI `LauncherView` for CLI selection, directory selection, remote host selection, and session options
2. **Terminal** — `TerminalViewController` attached to a tmux session

**Launch flow (local):**
```
User clicks "Start <selected CLI>" in LauncherView
  → Button shows spinner, form disabled (immediate feedback)
  → Tab title updated with ⏳ emoji
  → If Claude Code: HookSettingsGenerator.generate(sessionId) → /tmp/.../hooks-{id}.json
  → If Codex: build notify config inline for `sessylph-notifier`
  → LaunchConfig builds the full CLI command
  → TmuxManager.createAndLaunchSession()  ← single tmux invocation:
      new-session + set-option×4 + send-keys (was 6 process spawns)
  → Switch to TerminalViewController → attachToTmux()
```

**Launch flow (remote):**
```
User selects remote host + directory (or picks from history)
  → LaunchConfig.remoteNewSession(host, directory, options)
  → TmuxManager creates remote tmux session via SSH
  → TerminalViewController attaches via: ssh -t <host> tmux attach-session -t <name>
  → ClaudeStateTracker polls remote pane title for notifications
```

**State tracking:** Claude Code sessions delegate to `ClaudeStateTracker`, which polls tmux pane title every 1 second and parses Claude Code's status emoji:
- `✳` (U+2733) → idle
- Braille spinner (U+2800–U+28FF) → working (animated spinner in tab title)
- `needsAttention` flag → set by notification hooks

For remote sessions, `ClaudeStateTracker` detects working → idle transitions and fires task completion notifications directly (no hook-based notification path available).

Codex sessions currently do not use title-based state parsing, but they do integrate with launcher history and handoff-to-user notifications.

### ClaudeStateTracker

Extracted from TabWindowController. Encapsulates:
- `ClaudeState` enum (idle, working, needsAttention, unknown)
- `parseClaudeTitle()` — Maps terminal title prefix to state
- Timer-based polling (1s interval on main run loop, works for inactive tabs)
- Tab title spinner animation
- `ClaudeStateTrackerDelegate` protocol for state change notifications
- Task completion detection: working → idle transition triggers `stateTrackerDidCompleteTask`
- `lastWorkingTaskDescription` — retained across idle transitions for notification content

### TerminalViewController

Hosts a `GhosttyTerminalView` (Metal-rendered NSView) and a `CommandStripView` (bottom bar), attaching to tmux via a PTY process running `tmux attach-session -t {name}`. For remote sessions, the command is `ssh -t <host> tmux attach-session -t <name>`. Tmux attachment is deferred (not in `viewDidLoad`) — the parent calls `startTmuxAttach()` explicitly after the window is positioned, preventing buffer jumps from intermediate resizes.

**Layout:** GhosttyTerminalView fills top to CommandStripView.top; CommandStripView is pinned to bottom (30px height).

**Working directory isolation:** The ghostty surface uses `/tmp` as its working directory (not the project directory) to avoid triggering macOS TCC prompts for ~/Documents. The actual working directory is managed by tmux via `new-session -c`.

**Pane Monitor (Dynamic Mouse Mode):** A 2-second timer polls `TmuxManager.getPaneCount()` and toggles tmux mouse mode automatically:
- Single pane → mouse off (GhosttyKit handles native scroll via scrollback buffer)
- Multiple panes → mouse on (enables tmux per-pane scrolling and click-to-select pane)
- Works for both local and remote sessions

### Command Strip

A persistent bottom bar displaying MRU-sorted shortcut buttons for slash commands and free-text phrases. Commands are automatically detected from user input and stored for quick re-execution. Users can also manually add commands via the "+" button.

**Input Detection:** `GhosttyTerminalView` tracks keystrokes in `inputLineBuffer`. When Enter is pressed and the buffer starts with `/`, the `onSlashCommand` callback fires. TerminalViewController records usage via `SlashCommandStore` and refreshes the strip.

**Command Execution:** Clicking a pill button calls `GhosttyTerminalView.typeCommand()`, which sends the entire command + `\r` as a single `ghostty_surface_key()` event (keycode 0, text = command + CR). This produces one atomic PTY write, immune to SSH buffering that could split characters across packets. `ghostty_surface_text()` is not used because it wraps text in bracketed paste mode, which TUI apps (Claude Code) do not execute.

**Storage Strategy:**
- Built-in slash commands (known Claude Code commands) → stored globally in `UserDefaults` (`slashCommandHistoryGlobal`), shown in all projects
- Project-specific commands (custom skills, unknown commands, free-text phrases) → stored per directory using SHA256-hashed key (`slashCommandHistory_<hash>`)
- Free-text phrases (non-`/` prefixed) are always stored project-specific
- Classification uses a static `builtInCommands` set in `SlashCommandStore`
- `SlashCommandStore.load(for:)` merges global + project-specific, sorted by `lastUsed` descending
- Max 100 entries per storage location; oldest purged when limit exceeded

**UI Components:**
- `CommandStripView` (NSView) — Horizontal scroll view with pill buttons + "+" button
- `PillButton` — Custom NSButton with hover tracking, rounded corners, `acceptsFirstResponder = false` (never steals focus from terminal)
- Right-click on pill button → "Remove" context menu
- "+" button → `CommandListPopover` (SwiftUI in NSPopover) with search field, Global/This Project sections, and inline "Add Shortcut" input for manually adding commands or phrases
- Empty state: hint label "Type a /command to add shortcuts here"

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
- Font family + size from `UserDefaults` (default: "Comic Code" 13pt)
- Scrollback lines, cursor style, theme
- tmux-friendly terminal overrides
- Supports live reload via `GhosttyApp.shared.reloadConfig()` when font settings change

**GhosttyInputHandler** — Routes keyboard and IME input to ghostty.
- `keyDown()` passes raw virtual keycodes + accumulated text
- `insertText()` accumulates IME text for the next `keyDown()`
- `doCommand(by:)` overridden to suppress NSBeep on backspace
- Copy/paste implemented via `copy(_ sender:)` / `paste(_ sender:)` responders

### TmuxManager (Sendable)

All tmux operations. Runs on `DispatchQueue.global()`, exposes async/await API. Commands are batched using tmux's `;` separator to minimize process spawns.

- **Session lifecycle:** `createAndLaunchSession()` (create + configure + launch in one invocation), `configureSession()` (for reattach), kill
- **Remote SSH:** `executeRemoteCommand()` runs tmux commands on remote hosts via SSH, `shellEscape()` for safe argument passing
- **Queries:** list sessions, get pane title, get current path, get window size, get pane count, capture pane history
- **Mouse mode:** `getPaneCount()` / `setMouse(on:)` — dynamic mouse toggle based on pane count
- **Server config:** Extended keys, CSI u, alternate screen disabled (smcup@:rmcup@), mouse off, window size "latest", allow-rename on (all batched into session creation)
- **Session naming:** `sessylph-{first 8 chars of UUID}`
- **Remote target safety:** Uses plain session names (no `=` prefix) for remote `-t` targets since `=` prefix is not supported over SSH

### Models

**CLIType** (String enum, Codable, Sendable, CaseIterable)
- `.claudeCode` ("claude") and `.codex` ("codex")
- Used by launcher to select which CLI to start
- Persisted as `defaultCLIType` in UserDefaults

**Session** (Identifiable, Codable, Sendable)
- `id`, `directory`, `options`, `tmuxSessionName`, `isRunning`, `createdAt`
- `remoteHost` — optional `RemoteHost` for remote sessions (backward-compatible Codable)
- `title` is computed from `directory.lastPathComponent`
- `isRemote` computed property checks for `remoteHost` presence
- `CodingKeys` excludes `isRunning` (transient runtime state)

**ClaudeCodeOptions** (Codable, Sendable)
- Claude Code launcher options: model, effort level (Low/Medium/High), permission mode, skip permissions, continue session, verbose, max budget
- `effortLevel` maps to `--effort` CLI flag
- `buildCommand()` constructs the full CLI invocation

**CodexOptions** (Codable, Sendable)
- Codex launcher options: model, approval mode (ask/fullAuto/yolo), dangerous bypass, full auto
- `resumeSessionId` for launcher history resume
- `buildCommand()` constructs the full CLI invocation with notifier TOML config

**LaunchConfig**
- Enum wrapping `.claudeCode(ClaudeCodeOptions)`, `.codex(CodexOptions)`, `.remoteAttach(RemoteHost, sessionName)`, and `.remoteNewSession(RemoteHost, directory, ClaudeCodeOptions)`
- Also builds a default launch configuration from `UserDefaults` for directory-based launches

**RemoteHost** (Identifiable, Codable, Hashable, Sendable)
- `id` (UUID), `label`, `host`, `port`, `user`, `identityFile`
- `sshArgs` computed property builds SSH argument array
- `isValid` computed property validates host format and port range

**RemoteHostStore** (@MainActor singleton)
- Persists `[RemoteHost]` to UserDefaults
- Provides CRUD operations for remote host configurations

**RemoteHistory**
- MRU list of `RemoteHistoryEntry` (hostId + directory + lastUsed), max 50 entries
- Persisted to UserDefaults as JSON
- Used by launcher to show recent remote host:directory pairs

**SlashCommand** (Codable, Identifiable, Hashable)
- `command` (also serves as `id`), `lastUsed`, `useCount`, `isGlobal`
- Global commands = recognized Claude Code built-in slash commands (stored app-wide)
- Project-specific commands = custom skills, unknown commands, or free-text phrases (stored per directory)

**ClaudeSessionHistory** / **CodexSessionHistory**
- Parse recent session metadata from `~/.claude/projects` and `~/.codex`
- Used by the launcher to provide click-to-resume history for both CLIs

**SessionStore** (@MainActor singleton)
- Persists `[Session]` to `~/Library/Application Support/sh.saqoo.Sessylph/sessions.json`

### Notifications

```
Local notifications:
  Claude Code hook or Codex notify fires
    → sessylph-notifier {sessionId} {event}    (bundled CLI)
    → reads stdin / argv[3] (hook context JSON)
    → DistributedNotificationCenter.post("sh.saqoo.Sessylph.hookEvent")

  AppDelegate listener
    → extracts sessionId, event, message
    → pre-computes isFrontmost before any state changes
    → Claude "stop" event + activateOnStop preference:
        → TabManager.bringToFront(sessionId) — activates app/tab
        → 0.5s delayed notification post (avoids macOS swallowing it during activation)
    → Codex "notify" event:
        → "Codex Is Ready" notification (handoff to user, no auto-activate)
    → "permission_prompt" → TabWindowController.markNeedsAttention()
    → NotificationManager posts UNUserNotification (if not frontmost)

Remote notifications:
  ClaudeStateTracker polls tmux pane title every 1s (via SSH for remote)
    → Detects working → idle state transition
    → TabWindowController.stateTrackerDidCompleteTask()
    → Posts UNUserNotification with task description
    → Optionally activates app/tab (activateOnStop preference)

User clicks notification
  → TabManager.bringToFront(sessionId)
```

**HookSettingsGenerator** — Creates per-session JSON config at `/tmp/sh.saqoo.Sessylph/hooks-{id}.json` defining Claude Code hooks:
1. **Stop hook** — Claude completed a task
2. **Notification hook** — Claude needs permission

**SessylphNotifier** (separate build target, bundled in .app) — Lightweight CLI that handles both Claude Code hooks and Codex notify events, then posts a DistributedNotification. Decouples CLI-side notifications from the main app process.

### Settings & Preferences

**SettingsWindow** — Singleton NSToolbar-based window with `toolbarStyle(.preference)` (macOS HIG-compliant).
- Two tabs: General, Remote Hosts
- Uses `NSWindowController.windowFrameAutosaveName` for persistent frame
- Single SwiftUI content view with `ObservableObject` tab selection for flicker-free switching
- `show(tab:)` method to open a specific tab programmatically (e.g., "Manage Hosts..." button)

**GeneralSettingsView** — Launcher defaults (CLI type, model, effort level, permission mode), notification toggles, font selection (monospaced font picker + size slider with live preview), Claude/Codex version display.

**SessionConfigSheet** — Pre-launch configuration sheet for Claude Code sessions. Displayed before starting a session; configures model, effort level, permission mode, skip permissions, continue session, verbose output. Returns config via `onStart()` callback.

**RemoteHostsSettingsView** — CRUD interface for remote host configurations with SSH connection testing.

**Defaults** — Static keys for `UserDefaults`:
- General: default CLI type, model, effort level, permission mode
- Appearance: font name, font size (10–24pt)
- Notifications: enabled, notify on stop, notify on permission
- Behavior: activate on task completion (`activateOnStop`)
- Launcher state: persisted between launches
- Alerts: suppress close/quit confirmations
- Command Strip: global command history, per-project command history
- Session state: active session ID, recent directories

### Utilities

| Utility | Purpose |
|---------|---------|
| `ClaudeCLI` | Resolves `claude` and discovers Claude Code CLI options |
| `CodexCLI` | Resolves `codex` and discovers approval modes for the launcher |
| `CLIResolver` | Shared executable path / version resolution for supported CLIs |
| `EnvironmentBuilder` | Captures login shell environment (thread-safe with `OSAllocatedUnfairLock`) |
| `ShellQuote` | Safe shell argument quoting (enum namespace) |
| `ImagePasteHelper` | Extracts images from pasteboard, saves to temp, returns path |
| `PermissionMode` | Shared permission mode label formatting |
| `RecentDirectories` | Recent directory picker history |
| `RemoteHistory` | MRU list of remote host:directory pairs |
| `SlashCommandStore` | Slash command usage tracking with built-in classification and per-project storage |

## Concurrency Model

- **@MainActor:** AppDelegate, TabManager, TabWindowController, TerminalViewController, SessionStore, NotificationManager, SettingsWindow, ClaudeStateTracker, RemoteHostStore
- **Sendable (nonisolated):** TmuxManager, Session, ClaudeCodeOptions, CodexOptions, RemoteHost
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

## Remote SSH Architecture

Remote sessions connect to hosts via SSH and manage tmux sessions on the remote machine.

```
LauncherView (remote mode)
  → User selects host + browses directories (RemoteDirectoryBrowser via SSH ls)
  → Or picks from RemoteHistory (MRU list of host:directory pairs)
  → TmuxManager.createAndLaunchSession() with remoteHost parameter
      → Executes tmux commands on remote via: ssh <args> tmux <commands>
      → Uses shellEscape() for safe argument passing over SSH
  → TerminalViewController attaches via:
      ssh -t <args> tmux attach-session -t <sessionName>
  → ClaudeStateTracker polls remote pane title via SSH for notifications

Key differences from local:
  - No `=` prefix for tmux -t targets (not supported over SSH)
  - `allow-rename on` set explicitly (remote tmux may default to off)
  - Notifications via title polling instead of hooks (hooks can't bridge SSH)
  - Remote history stored separately from local recent directories
```
