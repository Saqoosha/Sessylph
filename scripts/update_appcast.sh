#!/usr/bin/env bash
set -euo pipefail

# Update Sparkle appcast.xml and push to gh-pages branch.
# Usage: ./scripts/update_appcast.sh <version>
# Can also be run standalone after a release to regenerate the appcast.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${ROOT_DIR}/build"
SPARKLE_BIN="${BUILD_DIR}/SourcePackages/artifacts/sparkle/Sparkle/bin"
APPCAST_DIR="${BUILD_DIR}/appcast"

VERSION="${1:-}"
if [[ -z "$VERSION" ]]; then
  VERSION=$(grep 'MARKETING_VERSION:' "${ROOT_DIR}/project.yml" | sed 's/.*: *"\(.*\)".*/\1/')
  echo "No version specified, using current: ${VERSION}"
fi

DMG_NAME="Sessylph-${VERSION}.dmg"
DOWNLOAD_URL="https://github.com/Saqoosha/Sessylph/releases/download/v${VERSION}/${DMG_NAME}"

if [[ ! -x "${SPARKLE_BIN}/generate_appcast" ]]; then
  echo "Error: generate_appcast not found. Build the project first to resolve SPM dependencies."
  exit 1
fi

# Prepare appcast directory with the DMG
mkdir -p "$APPCAST_DIR"

# Download DMG from GitHub Release if not available locally
DMG_PATH="${BUILD_DIR}/${DMG_NAME}"
if [[ ! -f "$DMG_PATH" ]]; then
  echo "DMG not found locally, downloading from GitHub Release..."
  gh release download "v${VERSION}" --pattern "${DMG_NAME}" --dir "$BUILD_DIR"
fi
cp "$DMG_PATH" "$APPCAST_DIR/"

# If an existing appcast.xml exists on gh-pages, fetch it so generate_appcast
# can append to it (preserving older versions in the feed).
EXISTING_APPCAST=$(mktemp)
if git show origin/gh-pages:appcast.xml > "$EXISTING_APPCAST" 2>/dev/null; then
  cp "$EXISTING_APPCAST" "$APPCAST_DIR/appcast.xml"
  echo "Fetched existing appcast.xml from gh-pages"
fi
rm -f "$EXISTING_APPCAST"

# Generate/update appcast.xml with Sparkle's tool
# This signs the DMG with the EdDSA key from Keychain and creates/updates appcast.xml
"${SPARKLE_BIN}/generate_appcast" \
  --download-url-prefix "https://github.com/Saqoosha/Sessylph/releases/download/v${VERSION}/" \
  "$APPCAST_DIR"

if [[ ! -f "${APPCAST_DIR}/appcast.xml" ]]; then
  echo "Error: generate_appcast failed to create appcast.xml"
  exit 1
fi

echo "Generated appcast.xml:"
cat "${APPCAST_DIR}/appcast.xml"

# Push appcast.xml to gh-pages branch
WORKTREE_DIR=$(mktemp -d)
trap 'rm -rf "$WORKTREE_DIR"' EXIT

# Check if gh-pages branch exists
if git rev-parse --verify origin/gh-pages >/dev/null 2>&1; then
  git worktree add "$WORKTREE_DIR" origin/gh-pages --detach
  cd "$WORKTREE_DIR"
  git checkout -B gh-pages origin/gh-pages
else
  # Create orphan gh-pages branch
  git worktree add --detach "$WORKTREE_DIR"
  cd "$WORKTREE_DIR"
  git checkout --orphan gh-pages
  git rm -rf . 2>/dev/null || true
fi

cp "${APPCAST_DIR}/appcast.xml" "$WORKTREE_DIR/appcast.xml"

git add appcast.xml
if git diff --cached --quiet; then
  echo "appcast.xml unchanged, skipping push"
else
  git commit -m "Update appcast for v${VERSION}"
  git push origin gh-pages
  echo "Pushed appcast.xml to gh-pages"
fi

cd "$ROOT_DIR"
git worktree remove "$WORKTREE_DIR" 2>/dev/null || true
