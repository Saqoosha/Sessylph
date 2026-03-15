#!/usr/bin/env bash
# Auto-adopt Claude Code features into Sessylph
# Runs daily via launchd, checks for new Claude Code versions,
# analyzes changelog, implements changes, and creates draft PRs.
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

mkdir -p "$STATE_DIR"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S'): $*" >> "$LOG_FILE"; }

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
  if [ -d "$WORKTREE_DIR" ]; then
    cleanup_worktree 2>>"$LOG_FILE" || log "WARNING: worktree cleanup failed"
  fi
  if [ $exit_code -ne 0 ]; then
    log "ERROR: Script exited with code $exit_code"
  fi
}
trap cleanup EXIT

# --- 1. Version check ---
if ! CURRENT=$(npm view @anthropic-ai/claude-code version 2>>"$LOG_FILE"); then
  log "ERROR: Failed to check npm version for @anthropic-ai/claude-code"
  exit 1
fi
LAST=$(cat "$VERSION_FILE" 2>/dev/null || echo "0.0.0")

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
  cleanup_worktree
fi

# Fetch latest main before creating worktree
jj git fetch --ignore-working-copy -R "$REPO_DIR" 2>>"$LOG_FILE" || \
  log "WARNING: jj git fetch failed, using local main"

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
GH_REPO=$(cd "$REPO_DIR" && gh repo view --json nameWithOwner -q '.nameWithOwner' 2>/dev/null || echo "")
if [ -z "$GH_REPO" ]; then
  log "ERROR: Could not detect GitHub repo — cannot create issues or PRs"
  exit 1
fi

# --- 4. Run Claude Code CLI for analysis & implementation ---
# -p = non-interactive print mode
# --dangerously-skip-permissions = required for unattended execution (no human to approve tool usage)
PROMPT_FILE=$(mktemp)
cat > "$PROMPT_FILE" <<'HEADER'
Claude Code の新バージョンがリリースされた。

## タスク
1. CLAUDE.md を読んでプロジェクトの全体像を把握
2. 下記 changelog から Sessylph に統合可能/有益な変更を特定:
   - terminal title format の変更 → ClaudeStateTracker 更新
   - 新しい hooks → sessylph-notifier 対応
   - 新しい CLI オプション → LaunchConfig / Settings 追加
   - 新しい slash commands → CommandStripView 対応
   - etc.
3. 統合可能な変更がない場合:
   "NO_ACTIONABLE_CHANGES" とだけ出力して終了
4. 統合可能な変更がある場合:
   a. 実装する
   b. 関連するドキュメントも更新する:
      - AGENTS.md (= CLAUDE.md) — Key Source Files, Architecture, Key Patterns 等
      - docs/ARCHITECTURE.md — 該当セクションの詳細を更新
      - README.md / README.ja.md — Features セクションに必要なら追記
   c. 変更内容のサマリーを出力

## Changelog
HEADER
echo "$RELEASE_NOTES" >> "$PROMPT_FILE"

if ! RESULT=$(claude -p --dangerously-skip-permissions \
  --max-budget-usd 5 < "$PROMPT_FILE" 2>>"$LOG_FILE"); then
  log "ERROR: claude CLI failed for v${CURRENT}"
  exit 1
fi
rm -f "$PROMPT_FILE"
PROMPT_FILE=""

# Truncate RESULT to avoid GitHub API body size limits (65536 chars)
if [ ${#RESULT} -gt 60000 ]; then
  RESULT="${RESULT:0:60000}

... (truncated)"
fi

# --- 5. Check if changes were made ---
if echo "$RESULT" | grep -q "NO_ACTIONABLE_CHANGES"; then
  log "No actionable changes in v${CURRENT}"
  echo "$CURRENT" > "$VERSION_FILE"
  exit 0
fi

# Check actual file changes (separate from Claude's text output)
DIFF_STAT=$(jj diff --stat 2>>"$LOG_FILE") || {
  log "ERROR: jj diff --stat failed in worktree"
  exit 1
}
if [ -z "$DIFF_STAT" ]; then
  log "Claude found no changes to make for v${CURRENT}"
  echo "$CURRENT" > "$VERSION_FILE"
  exit 0
fi

# --- 6. Build verification ---
if ! xcodegen generate 2>>"$LOG_FILE"; then
  log "ERROR: xcodegen generate failed for v${CURRENT}"
  exit 1
fi

# Capture build output to file (no pipe — avoids exit code contamination from tee/tail)
BUILD_LOG=$(mktemp)
if ! xcodebuild -scheme Sessylph -configuration Debug \
  -derivedDataPath build build > "$BUILD_LOG" 2>&1; then
  log "Build failed for v${CURRENT}"
  tail -20 "$BUILD_LOG" >> "$LOG_FILE"

  # Check retry count to prevent infinite loop
  RETRY_FILE="$STATE_DIR/retry-count-${CURRENT}.txt"
  RETRY_COUNT=$(cat "$RETRY_FILE" 2>/dev/null || echo "0")
  if [ "$RETRY_COUNT" -ge "$MAX_RETRIES" ]; then
    log "ERROR: v${CURRENT} failed $MAX_RETRIES times, skipping"
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
    # Write body in parts to avoid shell expansion of $RESULT
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

    if ! gh issue create --repo "$GH_REPO" \
      --title "auto-adopt: Claude Code v${CURRENT} build failed" \
      --body-file "$ISSUE_BODY_FILE" \
      --label "auto-adopt" 2>>"$LOG_FILE"; then
      log "ERROR: Failed to create GitHub issue for build failure"
    fi
  else
    log "Issue #${EXISTING_ISSUE} already exists for v${CURRENT}, skipping issue creation"
  fi

  exit 1
fi
rm -f "$BUILD_LOG"
BUILD_LOG=""

# Clean up retry counter on success
rm -f "$STATE_DIR/retry-count-${CURRENT}.txt"

# --- 7. Create PR (build succeeded) ---
BRANCH_NAME="auto-adopt/claude-code-v${CURRENT}"

jj describe -m "auto-adopt: claude-code v${CURRENT}

- Auto-adopted features from Claude Code v${CURRENT}
- Build verified locally

Co-Authored-By: Claude Code CLI <noreply@anthropic.com>" 2>>"$LOG_FILE"

if ! jj bookmark create "$BRANCH_NAME" -r @ 2>>"$LOG_FILE"; then
  log "WARNING: bookmark create failed, trying set"
  if ! jj bookmark set "$BRANCH_NAME" -r @ 2>>"$LOG_FILE"; then
    log "ERROR: jj bookmark set failed for $BRANCH_NAME"
    exit 1
  fi
fi

if ! jj git push --bookmark "$BRANCH_NAME" 2>>"$LOG_FILE"; then
  log "ERROR: jj git push failed for $BRANCH_NAME"
  exit 1
fi

# Write PR body safely (echo avoids shell expansion issues with heredocs)
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

if gh pr create --draft --repo "$GH_REPO" \
  --title "auto-adopt: Claude Code v${LAST} → v${CURRENT}" \
  --head "$BRANCH_NAME" \
  --body-file "$PR_BODY_FILE" 2>>"$LOG_FILE"; then
  log "Created draft PR for v${CURRENT}"
else
  log "ERROR: Branch $BRANCH_NAME was pushed but PR creation failed"
  log "Manual action: gh pr create --draft --head $BRANCH_NAME"
fi

# --- 8. Update version tracking ---
echo "$CURRENT" > "$VERSION_FILE"
log "Done: $LAST → $CURRENT"
