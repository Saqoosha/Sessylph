English | [日本語](README.ja.md)

# Sessylph

<p align="center">
  <img src="images/appicon.png" width="128" height="128" alt="Sessylph icon">
  <br>
  A native macOS wrapper for <a href="https://docs.anthropic.com/en/docs/claude-code">Claude Code</a> with tabbed terminal sessions, tmux persistence, and desktop notifications.
</p>

## Features

- **Tabbed Interface** — Each tab runs an independent Claude Code session using native macOS window tabbing
- **tmux Persistence** — Sessions survive app restarts; reconnect to running conversations with scrollback history preserved
- **Desktop Notifications** — Get notified when Claude Code completes a task or needs your attention
- **Image Paste** — Paste images directly into the terminal with Cmd+V
- **Configurable** — Customize model, permission mode, appearance, and behavior via Settings

## Requirements

- macOS 15.0 (Sequoia) or later
- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) CLI installed
- [tmux](https://github.com/tmux/tmux) installed

---

## Development

### Architecture

```
User opens new tab
        ↓
  LauncherView (pick directory + options)
        ↓
  TmuxManager.createAndLaunchSession()  ← single tmux invocation
        ↓
  TerminalViewController (xterm.js/WKWebView attaches to tmux)

Notifications:
  Claude Code hook → sessylph-notifier CLI
        ↓
  DistributedNotificationCenter
        ↓
  NotificationManager → UNUserNotificationCenter
```

See [ARCHITECTURE.md](docs/ARCHITECTURE.md) for detailed internal documentation.

### Requirements

- Xcode 16.0+
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)

### Build from Source

```bash
git clone https://github.com/Saqoosha/Sessylph.git
cd Sessylph
xcodegen generate
xcodebuild -scheme Sessylph -configuration Debug -derivedDataPath build build

# The app is located at:
# build/Build/Products/Debug/Sessylph.app
```

### Build Commands

```bash
xcodegen generate                                                          # Generate Xcode project
xcodebuild -scheme Sessylph -configuration Debug -derivedDataPath build build   # Debug build
/usr/bin/python3 scripts/generate_icon.py                                  # Regenerate app icons
```

### Project Structure

```
Sources/
├── Sessylph/              # Main app (AppKit + SwiftUI)
│   ├── App/               # AppDelegate, entry point
│   ├── Launcher/          # Directory picker + options (SwiftUI)
│   ├── Models/            # Session, SessionStore, ClaudeCodeOptions
│   ├── Notifications/     # Hook integration + desktop notifications
│   ├── Settings/          # Preferences window (SwiftUI)
│   ├── Tabs/              # TabManager, TabWindowController
│   ├── Terminal/          # xterm.js terminal view (WKWebView)
│   ├── Tmux/              # tmux session management
│   └── Utilities/         # CLI resolvers, environment, helpers
└── SessylphNotifier/      # Bundled CLI for hook → notification bridge
```

## Third-Party Libraries

- [xterm.js](https://github.com/xtermjs/xterm.js) — Terminal emulator for the web (rendered in WKWebView)

## License

MIT
