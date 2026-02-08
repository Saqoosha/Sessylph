Remove all existing Sessylph.app instances, download the latest release from GitHub, and install it.

## Steps

### 1. Version check

Get the latest release version from GitHub:

```bash
gh release list --limit 1
```

Get the currently installed version:

```bash
defaults read /Applications/Sessylph.app/Contents/Info.plist CFBundleShortVersionString 2>/dev/null
```

If both versions match, skip all remaining steps and report:
"Sessylph vX.X.X is already the latest version. No update needed."

### 2. Quit running Sessylph if any

```bash
osascript -e 'quit app "Sessylph"'
```

### 3. Find and remove all Sessylph.app instances

```bash
mdfind "kMDItemFSName == 'Sessylph.app'"
```

Remove all found instances including:
- `/Applications/Sessylph.app`
- Any build artifacts in the project's `build/` directory

### 4. Download latest release

Download the DMG from the latest release:

```bash
gh release download <latest_tag> --pattern '*.dmg' --dir <scratchpad>
```

### 5. Install

Mount the DMG, copy to `/Applications/`, and unmount:

```bash
hdiutil attach <dmg_path> -nobrowse
cp -R "/Volumes/Sessylph/Sessylph.app" /Applications/
hdiutil detach "/Volumes/Sessylph"
```

### 6. Open the app

```bash
open /Applications/Sessylph.app
```

### 7. Report

Display the installed version.
