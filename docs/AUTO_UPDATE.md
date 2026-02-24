# Auto Update (Sparkle)

Sessylph uses [Sparkle 2.x](https://github.com/sparkle-project/Sparkle) for automatic updates outside the Mac App Store.

## How It Works

1. On launch, Sparkle checks `SUFeedURL` for a new version (every 24 hours)
2. Users can also manually check via **Sessylph → Check for Updates...**
3. Sparkle compares `sparkle:version` (build number) in the appcast with the running app's `CFBundleVersion`
4. If a newer version exists, Sparkle shows a download/install dialog
5. Delta updates are used when available (only downloads the diff)

## Architecture

```
GitHub Pages (gh-pages branch)
  └── appcast.xml              ← Sparkle polls this URL

GitHub Releases (tagged)
  ├── Sessylph-X.Y.Z.dmg      ← Full installer
  └── SessylphNN-MM.delta      ← Delta patches (optional)
```

- **Appcast URL**: `https://saqoosha.github.io/Sessylph/appcast.xml`
- **DMG URL pattern**: `https://github.com/Saqoosha/Sessylph/releases/download/vX.Y.Z/Sessylph-X.Y.Z.dmg`

## EdDSA Signing

Sparkle uses EdDSA (Ed25519) to verify update integrity.

- **Public key**: Stored in `Info.plist` as `SUPublicEDKey` (configured in `project.yml`)
- **Private key**: Stored in macOS Keychain (generated once, never committed to repo)
- `generate_appcast` reads the private key from Keychain to sign DMGs

### Regenerating Keys

If the private key is lost, generate a new keypair:

```bash
build/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys
```

Then update `SUPublicEDKey` in `project.yml`. All users must update manually once since the old signature chain is broken.

### Exporting Private Key (for CI or backup)

```bash
build/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys -x sparkle_private.key
```

Store securely. Never commit to the repository.

## Release Workflow

The release script (`scripts/release.sh`) handles everything automatically:

1. Bump version in `project.yml`
2. Build, codesign, notarize, create DMG
3. Commit, tag, push, create GitHub Release with DMG
4. Run `scripts/update_appcast.sh` which:
   - Downloads previous DMGs from GitHub Releases (up to 5)
   - Runs `generate_appcast` to sign and generate delta updates
   - Uploads delta files to the GitHub Release
   - Pushes updated `appcast.xml` to `gh-pages` branch

### Manual Appcast Regeneration

To regenerate the appcast without a full release:

```bash
scripts/update_appcast.sh 1.9.1
```

## Info.plist Keys

Configured in `project.yml` under `info.properties`:

| Key | Value | Description |
|-----|-------|-------------|
| `SUFeedURL` | `https://saqoosha.github.io/Sessylph/appcast.xml` | Appcast feed URL |
| `SUPublicEDKey` | `CfVhssjAg+...` | EdDSA public key for signature verification |

## Delta Updates

Sparkle generates binary diffs between consecutive versions. When a user updates from version A to B, Sparkle downloads the small delta patch instead of the full DMG.

- Delta files are named `SessylphBB-AA.delta` (build numbers)
- Typically 1-5% of the full DMG size
- Falls back to full DMG if delta is unavailable or fails

## Code Integration

In `AppDelegate.swift`:

```swift
import Sparkle

private let updaterController = SPUStandardUpdaterController(
    startingUpdater: true,       // Auto-check on launch
    updaterDelegate: nil,
    userDriverDelegate: nil
)
```

Menu item wired to `SPUStandardUpdaterController.checkForUpdates(_:)`.

## Sparkle Tools

Located at `build/SourcePackages/artifacts/sparkle/Sparkle/bin/` after SPM resolution:

| Tool | Purpose |
|------|---------|
| `generate_appcast` | Generate/update appcast.xml, sign DMGs, create deltas |
| `generate_keys` | Generate EdDSA keypair |
| `sign_update` | Sign a single file manually |

## Troubleshooting

### Keychain Access Dialog

`generate_appcast` may prompt for Keychain access to read the EdDSA private key. Click **Always Allow** to avoid repeated prompts.

### Appcast Not Updating

GitHub Pages has a CDN cache. Verify the raw content:

```bash
curl -s "https://saqoosha.github.io/Sessylph/appcast.xml?$(date +%s)"
```

### Testing Updates Locally

Build a lower version, install it, then release a higher version. The app should detect the update on next launch or via the menu.
