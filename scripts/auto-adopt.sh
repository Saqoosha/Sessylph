#!/usr/bin/env bash
# Auto-adopt Claude Code features into Sessylph
# Runs daily via launchd, checks for new Claude Code versions,
# analyzes changelog, implements changes, and creates PRs.
set -euo pipefail

# --- PATH setup for launchd environment ---
export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:$PATH"

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE_DIR="$HOME/.local/share/sessylph-auto-adopt"
VERSION_FILE="$STATE_DIR/last-version.txt"
LOG_FILE="$STATE_DIR/auto-adopt.log"
WORKTREE_DIR="/tmp/sessylph-auto-adopt"
WORKSPACE_NAME="auto-adopt"
MAX_RETRIES=3

SLACK_WEBHOOK_FILE="$STATE_DIR/slack-webhook-url.txt"
CHANGELOG_URL="https://github.com/anthropics/claude-code/releases"

mkdir -p "$STATE_DIR"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S'): $*" >> "$LOG_FILE"; }

# --- Slack notification ---
# Reads webhook URL from file. Silently skips if file doesn't exist.
notify_slack() {
  local color="$1"  # good / warning / danger
  local title="$2"
  local body="$3"

  local webhook_url
  webhook_url=$(cat "$SLACK_WEBHOOK_FILE" 2>/dev/null) || return 0
  [ -n "$webhook_url" ] || return 0

  # Interpret \n as actual newlines, then JSON-escape for the payload
  # python3 failure must not abort the pipeline under set -e
  local escaped_title escaped_body
  escaped_title=$(printf '%b' "$title" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read())[1:-1])') || { log "WARNING: python3 not available for Slack notification"; return 0; }
  escaped_body=$(printf '%b' "$body" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read())[1:-1])') || return 0

  local payload
  payload=$(cat <<ENDJSON
{
  "attachments": [{
    "color": "${color}",
    "blocks": [
      {"type": "header", "text": {"type": "plain_text", "text": "${escaped_title}"}},
      {"type": "section", "text": {"type": "mrkdwn", "text": "${escaped_body}"}}
    ]
  }]
}
ENDJSON
)

  local http_code
  http_code=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$webhook_url" \
    -H 'Content-Type: application/json' \
    -d "$payload" 2>>"$LOG_FILE") || {
    log "WARNING: Slack notification failed (curl error)"
    return 0
  }
  if [ "$http_code" != "200" ]; then
    log "WARNING: Slack notification returned HTTP $http_code"
  fi
  _SLACK_NOTIFIED=1
}

# --- Lockfile to prevent concurrent execution ---
LOCKFILE="$STATE_DIR/auto-adopt.lock"
if ! mkdir "$LOCKFILE" 2>/dev/null; then
  if [ -d "$LOCKFILE" ] && find "$LOCKFILE" -maxdepth 0 -mmin +120 | grep -q .; then
    log "WARNING: Removing stale lock (>2h old)"
    rm -rf "$LOCKFILE"
    mkdir "$LOCKFILE"
  else
    log "ERROR: Another instance is running (lockfile exists: $LOCKFILE)"
    exit 1
  fi
fi

# --- Verify required commands ---
for cmd in npm jj gh xcodegen xcodebuild claude; do
  if ! command -v "$cmd" &>/dev/null; then
    log "ERROR: Required command '$cmd' not found in PATH=$PATH"
    exit 1
  fi
done

# --- Temp file tracking for cleanup ---
PROMPT_FILE=""
BUILD_LOG=""
ISSUE_BODY_FILE=""
PR_BODY_FILE=""
_SLACK_NOTIFIED=0  # Set to 1 after sending a specific Slack notification

cleanup_worktree() {
  cd "$REPO_DIR" || return 1
  if ! jj workspace forget "$WORKSPACE_NAME" --ignore-working-copy 2>>"$LOG_FILE"; then
    log "WARNING: jj workspace forget failed (may already be cleaned up)"
  fi
  rm -rf "$WORKTREE_DIR" || log "WARNING: Failed to remove $WORKTREE_DIR"
}

cleanup() {
  local exit_code=$?
  set +e  # Don't let cleanup failures mask the original error
  rm -f "$PROMPT_FILE" "$BUILD_LOG" "$ISSUE_BODY_FILE" "$PR_BODY_FILE"
  rm -rf "$LOCKFILE"
  if [ -d "$WORKTREE_DIR" ]; then
    cleanup_worktree 2>>"$LOG_FILE" || log "WARNING: worktree cleanup failed"
  fi
  if [ $exit_code -ne 0 ]; then
    log "ERROR: Script exited with code $exit_code"
    # Only send catch-all if no specific notification was already sent
    if [ "$_SLACK_NOTIFIED" -eq 0 ]; then
      notify_slack "danger" "Auto-Adopt Pipeline Failed (exit $exit_code)" \
        "Unexpected error in auto-adopt pipeline.\nCheck log: \`~/.local/share/sessylph-auto-adopt/auto-adopt.log\`" 2>/dev/null || true
    fi
  fi
  exit $exit_code
}
trap cleanup EXIT

# --- 1. Version check ---
if ! CURRENT=$(npm view @anthropic-ai/claude-code version 2>>"$LOG_FILE"); then
  log "ERROR: Failed to check npm version for @anthropic-ai/claude-code"
  exit 1
fi
CURRENT=$(echo "$CURRENT" | tr -d '[:space:]')
if ! [[ "$CURRENT" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[a-zA-Z0-9.]+)?$ ]]; then
  log "ERROR: npm returned invalid version string: '$CURRENT'"
  exit 1
fi
LAST=$(cat "$VERSION_FILE" 2>/dev/null || echo "")

# Guard: first run without initialization seeds the version instead of triggering a full pipeline run
if [ -z "$LAST" ]; then
  log "WARNING: last-version.txt not initialized, setting to $CURRENT"
  echo "$CURRENT" > "$VERSION_FILE"
  exit 0
fi

if [ "$CURRENT" = "$LAST" ]; then
  log "No update ($CURRENT)"
  exit 0
fi

log "New version detected: $LAST → $CURRENT"

# --- 2. Fetch release notes from GitHub ---
if ! RELEASE_NOTES=$(gh api "repos/anthropics/claude-code/releases/tags/v${CURRENT}" \
  --jq '.body' 2>>"$LOG_FILE"); then
  log "WARNING: No GitHub release found for v${CURRENT} — will retry next run"
  exit 0
fi

if [ -z "$RELEASE_NOTES" ]; then
  log "WARNING: Empty release notes for v${CURRENT} — will retry next run"
  exit 0
fi

# --- 3. Create isolated jj worktree ---
if [ -d "$WORKTREE_DIR" ]; then
  if ! cleanup_worktree 2>>"$LOG_FILE"; then
    log "ERROR: Failed to clean up stale worktree at $WORKTREE_DIR"
    exit 1
  fi
fi

# Fetch latest main before creating worktree
if ! jj git fetch --ignore-working-copy -R "$REPO_DIR" 2>>"$LOG_FILE"; then
  log "ERROR: jj git fetch failed — cannot create worktree from latest main"
  exit 1
fi

# Note: workspace add cannot use --ignore-working-copy (it needs to create the new working copy).
# This will snapshot the main workspace, which is harmless (just records current state).
if ! jj workspace add "$WORKTREE_DIR" --name "$WORKSPACE_NAME" -r main \
  -R "$REPO_DIR" 2>>"$LOG_FILE"; then
  log "ERROR: jj workspace add failed for $WORKSPACE_NAME"
  exit 1
fi
cd "$WORKTREE_DIR" || { log "ERROR: Cannot cd to worktree $WORKTREE_DIR"; exit 1; }

# Symlink libghostty.a from the main repo (untracked binary, not in jj)
if [ -f "$REPO_DIR/ghostty/Vendor/libghostty.a" ]; then
  mkdir -p "$WORKTREE_DIR/ghostty/Vendor"
  if ! ln -sf "$REPO_DIR/ghostty/Vendor/libghostty.a" "$WORKTREE_DIR/ghostty/Vendor/libghostty.a"; then
    log "ERROR: Failed to symlink libghostty.a into worktree"
    exit 1
  fi
else
  log "WARNING: libghostty.a not found at $REPO_DIR/ghostty/Vendor/ — build will likely fail"
fi

# Detect GitHub repo for gh commands (jj worktree has no .git directory)
GH_REPO_OUTPUT=$(cd "$REPO_DIR" && gh repo view --json nameWithOwner -q '.nameWithOwner' 2>&1) || true
GH_REPO=$(echo "$GH_REPO_OUTPUT" | head -1)
if [ -z "$GH_REPO" ] || [[ "$GH_REPO" == *"error"* ]]; then
  log "ERROR: Could not detect GitHub repo: $GH_REPO_OUTPUT"
  exit 1
fi

# --- 4. Run Claude Code CLI for analysis & implementation ---
# -p = non-interactive print mode
# --dangerously-skip-permissions = required for unattended execution (no human to approve tool usage)
# --model sonnet = cost-effective for automated changelog analysis (vs default model)
PROMPT_FILE=$(mktemp)
cat > "$PROMPT_FILE" <<'HEADER'
A new version of Claude Code has been released.

## Task
1. Read CLAUDE.md to understand the project overview
2. Identify changes from the changelog below that can be integrated into Sessylph:
   - Terminal title format changes → update ClaudeStateTracker
   - New hooks → update sessylph-notifier support
   - New CLI options → update LaunchConfig / Settings
   - New slash commands → update CommandStripView
   - etc.
3. If no actionable changes exist:
   Output only "NO_ACTIONABLE_CHANGES" and stop
4. If actionable changes exist:
   a. Implement them
   b. Update related documentation:
      - AGENTS.md (= CLAUDE.md) — Key Source Files, Architecture, Key Patterns, etc.
      - docs/ARCHITECTURE.md — update relevant sections with details
      - README.md / README.ja.md — add to Features section if needed
   c. Output a summary of the changes made

## Changelog
HEADER
echo "$RELEASE_NOTES" >> "$PROMPT_FILE"

if ! RESULT=$(claude -p --dangerously-skip-permissions \
  --model sonnet --max-budget-usd 5 < "$PROMPT_FILE" 2>>"$LOG_FILE"); then
  log "ERROR: claude CLI failed for v${CURRENT}"
  notify_slack "danger" "Claude Code v${CURRENT} — Pipeline Error" \
    "Claude CLI failed during changelog analysis for v${LAST} → v${CURRENT}.\nCheck log: \`~/.local/share/sessylph-auto-adopt/auto-adopt.log\`"
  exit 1
fi
rm -f "$PROMPT_FILE"
PROMPT_FILE=""

# --- 5. Check if changes were made ---
# Check BEFORE truncation so the marker isn't cut off
if echo "$RESULT" | grep -q "NO_ACTIONABLE_CHANGES"; then
  log "No actionable changes in v${CURRENT}"
  notify_slack "good" "Claude Code v${CURRENT} — No Changes Needed" \
    "New version released (v${LAST} → v${CURRENT}) but no actionable changes for Sessylph.\n\n<${CHANGELOG_URL}/tag/v${CURRENT}|View changelog>"
  echo "$CURRENT" > "$VERSION_FILE"
  exit 0
fi

# Truncate RESULT to avoid GitHub API body size limits (65536 chars, with 5536 buffer)
if [ ${#RESULT} -gt 60000 ]; then
  log "WARNING: Claude output truncated from ${#RESULT} to 60000 chars"
  TRUNCATED="${RESULT:0:60000}"
  FENCE_COUNT=$(echo "$TRUNCATED" | grep -c '```' || true)
  if [ $((FENCE_COUNT % 2)) -eq 1 ]; then
    RESULT="${TRUNCATED}
\`\`\`

_(output truncated)_"
  else
    RESULT="${TRUNCATED}

_(output truncated)_"
  fi
fi

# Check actual file changes (separate from Claude's text output)
DIFF_STAT=$(jj diff --stat 2>>"$LOG_FILE") || {
  log "ERROR: jj diff --stat failed in worktree"
  exit 1
}
if [ -z "$DIFF_STAT" ]; then
  log "Claude found no changes to make for v${CURRENT}"
  notify_slack "good" "Claude Code v${CURRENT} — No Changes Needed" \
    "New version released (v${LAST} → v${CURRENT}). Claude analyzed the changelog but found no code changes needed.\n\n<${CHANGELOG_URL}/tag/v${CURRENT}|View changelog>"
  echo "$CURRENT" > "$VERSION_FILE"
  exit 0
fi

# --- 6. Build verification ---
if ! xcodegen generate 2>>"$LOG_FILE"; then
  log "ERROR: xcodegen generate failed for v${CURRENT}"
  exit 1
fi

# Capture build output to file (piping to tee + pipefail could surface SIGPIPE as non-zero exit)
BUILD_LOG=$(mktemp)
if ! xcodebuild -scheme Sessylph -configuration Debug \
  -derivedDataPath build build > "$BUILD_LOG" 2>&1; then
  log "Build failed for v${CURRENT}"
  tail -20 "$BUILD_LOG" >> "$LOG_FILE"

  # Check retry count to prevent infinite loop
  RETRY_FILE="$STATE_DIR/retry-count-${CURRENT}.txt"
  RETRY_COUNT=$(cat "$RETRY_FILE" 2>/dev/null || echo "0")
  if ! [[ "$RETRY_COUNT" =~ ^[0-9]+$ ]]; then
    log "WARNING: Corrupt retry count '$RETRY_COUNT' in $RETRY_FILE, resetting to 0"
    RETRY_COUNT=0
  fi
  if [ "$RETRY_COUNT" -ge "$MAX_RETRIES" ]; then
    log "ERROR: v${CURRENT} failed $MAX_RETRIES times, skipping"
    notify_slack "danger" "Claude Code v${CURRENT} — Giving Up" \
      "Build failed ${MAX_RETRIES} times. v${CURRENT} will be skipped permanently.\nManual intervention required.\n\n<${CHANGELOG_URL}/tag/v${CURRENT}|Changelog>"
    echo "$CURRENT" > "$VERSION_FILE"
    rm -f "$RETRY_FILE"
    exit 1
  fi
  echo $((RETRY_COUNT + 1)) > "$RETRY_FILE"

  # Check for existing issue to avoid duplicates
  EXISTING_ISSUE=$(gh issue list --repo "$GH_REPO" \
    --search "auto-adopt: Claude Code v${CURRENT} build failed" \
    --state open --json number -q '.[0].number' 2>/dev/null || echo "")

  if [ -z "$EXISTING_ISSUE" ]; then
    ISSUE_BODY_FILE=$(mktemp)
    # Build issue body via temp file (--body-file avoids shell quoting issues in gh arguments)
    {
      echo "## auto-adopt: Claude Code v${CURRENT} — Build Failed"
      echo ""
      echo "### Claude's Analysis"
      echo "$RESULT"
      echo ""
      echo "### Build Error (last 50 lines)"
      echo '```'
      tail -50 "$BUILD_LOG"
      echo '```'
      echo ""
      echo "### Details"
      echo "- Previous version: v${LAST}"
      echo "- New version: v${CURRENT}"
      echo "- Retry: $((RETRY_COUNT + 1))/${MAX_RETRIES}"
      echo "- Changelog: https://github.com/anthropics/claude-code/releases"
      echo ""
      echo "Auto-adopt pipeline detected actionable changes but the build failed."
    } > "$ISSUE_BODY_FILE"

    if ISSUE_URL=$(gh issue create --repo "$GH_REPO" \
      --title "auto-adopt: Claude Code v${CURRENT} build failed" \
      --body-file "$ISSUE_BODY_FILE" \
      --label "auto-adopt" 2>>"$LOG_FILE"); then
      log "Created issue for build failure: $ISSUE_URL"
      notify_slack "danger" "Claude Code v${CURRENT} — Build Failed" \
        "Auto-adopt build failed (retry $((RETRY_COUNT + 1))/${MAX_RETRIES}).\n\n<${ISSUE_URL}|View issue> · <${CHANGELOG_URL}/tag/v${CURRENT}|Changelog>"
    else
      log "ERROR: Failed to create GitHub issue for build failure"
      notify_slack "danger" "Claude Code v${CURRENT} — Build Failed" \
        "Auto-adopt build failed (retry $((RETRY_COUNT + 1))/${MAX_RETRIES}). Issue creation also failed.\n\n<${CHANGELOG_URL}/tag/v${CURRENT}|Changelog>"
    fi
  else
    log "Issue #${EXISTING_ISSUE} already exists for v${CURRENT}, skipping issue creation"
    notify_slack "danger" "Claude Code v${CURRENT} — Build Failed (retry)" \
      "Auto-adopt build still failing (retry $((RETRY_COUNT + 1))/${MAX_RETRIES}).\n\nExisting issue: <https://github.com/${GH_REPO}/issues/${EXISTING_ISSUE}|#${EXISTING_ISSUE}>"
  fi

  exit 1
fi
rm -f "$BUILD_LOG"
BUILD_LOG=""

# Clean up retry counter on success
rm -f "$STATE_DIR/retry-count-${CURRENT}.txt"

# --- 7. Create PR (build succeeded) ---
BRANCH_NAME="auto-adopt/claude-code-v${CURRENT}"

if ! jj describe -m "auto-adopt: claude-code v${CURRENT}

- Auto-adopted features from Claude Code v${CURRENT}
- Build verified locally

Co-Authored-By: Claude Code CLI <noreply@anthropic.com>" 2>>"$LOG_FILE"; then
  log "ERROR: jj describe failed for v${CURRENT}"
  exit 1
fi

if ! jj bookmark create "$BRANCH_NAME" -r @ 2>>"$LOG_FILE"; then
  log "WARNING: bookmark create failed, trying set"
  if ! jj bookmark set "$BRANCH_NAME" --allow-backwards -r @ 2>>"$LOG_FILE"; then
    log "ERROR: jj bookmark set failed for $BRANCH_NAME"
    exit 1
  fi
fi

if ! jj git push --bookmark "$BRANCH_NAME" 2>>"$LOG_FILE"; then
  log "ERROR: jj git push failed for $BRANCH_NAME"
  exit 1
fi

# Build PR body via temp file (--body-file avoids shell quoting issues in gh arguments)
PR_BODY_FILE=$(mktemp)
{
  echo "## Auto-adopted Changes from Claude Code v${CURRENT}"
  echo ""
  echo "Previous version: v${LAST}"
  echo ""
  echo "### Claude's Analysis"
  echo "$RESULT"
  echo ""
  echo "### Build Verification"
  echo "Build passed"
  echo ""
  echo "---"
  echo "Changelog: https://github.com/anthropics/claude-code/releases"
} > "$PR_BODY_FILE"

if ! PR_URL=$(gh pr create --repo "$GH_REPO" \
  --title "auto-adopt: Claude Code v${LAST} → v${CURRENT}" \
  --head "$BRANCH_NAME" \
  --label "auto-adopt" \
  --body-file "$PR_BODY_FILE" 2>>"$LOG_FILE"); then
  log "ERROR: Branch $BRANCH_NAME was pushed but PR creation failed (check that 'auto-adopt' label exists)"
  log "Will retry on next run"
  notify_slack "warning" "Claude Code v${CURRENT} — PR Creation Failed" \
    "Branch \`${BRANCH_NAME}\` pushed but PR creation failed. Manual intervention needed.\n\n<${CHANGELOG_URL}/tag/v${CURRENT}|Changelog>"
  exit 1
fi
log "Created PR for v${CURRENT}: $PR_URL"

# Summarize changes for Slack (truncate to 6 lines to keep message compact)
DIFF_SUMMARY=$(echo "$DIFF_STAT" | head -6)
notify_slack "good" "Claude Code v${LAST} → v${CURRENT} — PR Created" \
  "<${PR_URL}|View PR>\n\n\`\`\`\n${DIFF_SUMMARY}\n\`\`\`\n\n<${CHANGELOG_URL}/tag/v${CURRENT}|Changelog>"

# --- 8. Update version tracking ---
echo "$CURRENT" > "$VERSION_FILE"
log "Done: $LAST → $CURRENT"
