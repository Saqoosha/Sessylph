# Sessylph

A native macOS wrapper for [Claude Code](https://docs.anthropic.com/en/docs/claude-code) with tabbed terminal sessions, tmux persistence, and desktop notifications.

## Features

- **Tabbed Interface** — Each tab runs an independent Claude Code session using native macOS window tabbing
- **tmux Persistence** — Sessions survive app restarts; reconnect to running conversations seamlessly
- **Desktop Notifications** — Get notified when Claude Code completes a task or needs your attention
- **Image Paste** — Paste images directly into the terminal with Cmd+V
- **Configurable** — Customize appearance, shell environment, and behavior via Settings

## Requirements

- macOS 15.0 (Sequoia) or later
- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) CLI installed
- [tmux](https://github.com/tmux/tmux) installed

## Building

```bash
# Install xcodegen if needed
brew install xcodegen

# Generate Xcode project and build
xcodegen generate
xcodebuild -scheme Sessylph -configuration Debug -derivedDataPath build build

# Run
open build/Build/Products/Debug/Sessylph.app
```

## License

[MIT](LICENSE)
