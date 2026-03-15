# Auto-Adopt Claude Code Features

Automated pipeline that monitors Claude Code releases and creates draft PRs when new features can be integrated into Sessylph.

## How It Works

```
Daily (9:00 JST via launchd)
  │
  ├─ Check latest @anthropic-ai/claude-code version on npm
  ├─ Compare with last checked version
  ├─ No change → exit
  └─ New version found
      ├─ Fetch latest main (--ignore-working-copy), fetch release notes from GitHub Releases API
      ├─ Create isolated jj worktree (separate working copy — main workspace unaffected)
      ├─ Claude Code CLI analyzes changelog & implements changes
      ├─ xcodegen + xcodebuild for build verification
      ├─ Build passes → draft PR
      ├─ Build fails → GitHub Issue (deduplicated, max 3 retries)
      └─ Cleanup worktree
```

## Key Features

- **Isolated execution**: Uses `jj workspace add` to create a separate worktree — never modifies your current workspace
- **Build verification**: Runs `xcodegen generate && xcodebuild` before creating PRs
- **Failure reporting**: Build failures create GitHub Issues with Claude's analysis and build error logs
- **Retry with limits**: Failed versions are retried up to 3 times, with duplicate issue prevention
- **Robust error handling**: `trap EXIT` cleanup, command existence checks, error logging at every step

## Setup

Designed for an always-on Mac (e.g., Mac Studio) running scheduled tasks.

### Prerequisites

- `claude` CLI authenticated
- `npm`, `jj`, `gh`, `xcodegen`, `xcodebuild` available in PATH (script also adds `/opt/homebrew/bin`)
- GitHub CLI (`gh`) authenticated with repo access

### Installation

```bash
# 1. Initialize state directory
mkdir -p ~/.local/share/sessylph-auto-adopt
npm view @anthropic-ai/claude-code version > ~/.local/share/sessylph-auto-adopt/last-version.txt

# 2. Create GitHub label (one-time)
gh label create auto-adopt --color 0E8A16 --description "Auto-adopted from upstream"

# 3. Register launchd agent
cp sh.saqoo.sessylph.auto-adopt.plist ~/Library/LaunchAgents/
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/sh.saqoo.sessylph.auto-adopt.plist

# 4. Verify
launchctl list | grep sessylph
```

### Manual Run

```bash
./scripts/auto-adopt.sh
```

## Files

| File | Purpose |
|------|---------|
| `scripts/auto-adopt.sh` | Main pipeline script |
| `sh.saqoo.sessylph.auto-adopt.plist` | launchd schedule config |

## State (stored outside repo)

```
~/.local/share/sessylph-auto-adopt/
├── last-version.txt        # Last checked version number
├── auto-adopt.log          # Execution log
└── retry-count-X.Y.Z.txt  # Retry counter per version (auto-cleaned)
```

## Logs

- Execution log: `~/.local/share/sessylph-auto-adopt/auto-adopt.log`
- stdout: `/tmp/sessylph-auto-adopt.stdout.log`
- stderr: `/tmp/sessylph-auto-adopt.stderr.log`

## Uninstall

```bash
launchctl bootout gui/$(id -u)/sh.saqoo.sessylph.auto-adopt
rm ~/Library/LaunchAgents/sh.saqoo.sessylph.auto-adopt.plist
rm -rf ~/.local/share/sessylph-auto-adopt
```
