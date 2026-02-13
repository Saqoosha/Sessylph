# Building GhosttyKit (libghostty) for Sessylph

Sessylph uses [GhosttyKit](https://github.com/ghostty-org/ghostty) (libghostty) as a static library for Metal-accelerated terminal rendering. This document describes how to build `libghostty.a` and `ghostty.h` from source.

> **Important:** Sessylph uses the **tip (main branch)** of Ghostty, not a stable release. The embedding API used by Sessylph includes features not yet available in release versions (e.g., `ghostty_config_load_file`, `GHOSTTY_SURFACE_CONTEXT_TAB`). Using a release tarball (1.2.x) will result in compilation errors due to API mismatches.

> **Note:** libghostty is not a stable public API. Ghostty's author (Mitchell Hashimoto) has stated it is "not stable for general purpose use." Expect breaking changes when updating.

## Prerequisites

### Zig

Ghostty requires a **specific version** of Zig. Using a different version (even newer) will fail.

Check the required version in `build.zig.zon` (`minimum_zig_version` field) or Ghostty's [HACKING.md](https://github.com/ghostty-org/ghostty/blob/main/HACKING.md).

```bash
# Install via mise (recommended):
mise install zig@0.15.2   # Check build.zig.zon for the current required version

# Or download manually from https://ziglang.org/download/
```

### Other Dependencies

- **Xcode** with macOS SDK (Command Line Tools alone may not be sufficient)
- **Metal Toolchain** (may need separate download)
- **gettext** (for translations)

```bash
xcode-select -p  # Verify Xcode is active
brew install gettext
```

## Build Steps

### 1. Clone Ghostty (tip)

```bash
# Shallow clone is sufficient (saves bandwidth):
git clone --depth 1 https://github.com/ghostty-org/ghostty.git
cd ghostty
```

### 2. Build the Static Library

On macOS, Ghostty's build system produces an XCFramework containing `libghostty.a`.

```bash
# If installed via mise:
~/.local/share/mise/installs/zig/0.15.2/bin/zig build -Demit-xcframework -Doptimize=ReleaseFast

# Or if zig is on PATH:
zig build -Demit-xcframework -Doptimize=ReleaseFast
```

The output `libghostty.a` is at:
```
macos/GhosttyKit.xcframework/macos-arm64_x86_64/libghostty.a
```

### 3. Get the Header File

```bash
# The header is in the source tree:
ls include/ghostty.h

# Or from the XCFramework:
ls macos/GhosttyKit.xcframework/macos-arm64_x86_64/Headers/ghostty.h
```

### 4. Copy to Sessylph

```bash
# From the Sessylph project root:
cp /path/to/ghostty/macos/GhosttyKit.xcframework/macos-arm64_x86_64/libghostty.a \
   ghostty/Vendor/libghostty.a
cp /path/to/ghostty/include/ghostty.h \
   ghostty/Vendor/ghostty.h
```

The `module.modulemap` in `ghostty/Vendor/` should already exist:

```
module GhosttyKit [system] {
    header "ghostty.h"
    export *
}
```

## Sessylph Integration

The Xcode project (via `project.yml`) links against `libghostty.a` with these settings:

```yaml
SWIFT_INCLUDE_PATHS: "$(SRCROOT)/ghostty/Vendor"
HEADER_SEARCH_PATHS: "$(SRCROOT)/ghostty/Vendor"
LIBRARY_SEARCH_PATHS: "$(SRCROOT)/ghostty/Vendor"
OTHER_LDFLAGS:
  - "-lghostty"
  - "-lz"
  - "-lc++"
  - "-framework Metal"
  - "-framework MetalKit"
  - "-framework IOSurface"
  - "-framework Carbon"
  - "-framework CoreGraphics"
  - "-framework CoreText"
  - "-framework QuartzCore"
```

## File Inventory

After building, `ghostty/Vendor/` should contain:

| File | Size | Description |
|------|------|-------------|
| `libghostty.a` | ~272 MB | Static library (universal: arm64 + x86_64) |
| `ghostty.h` | ~33 KB | C header (embedding API) |
| `module.modulemap` | ~67 B | Swift module map for `import GhosttyKit` |

> **Note:** `libghostty.a` is not checked into the repository due to its size. It must be built locally.

## Troubleshooting

### Missing Metal Toolchain

```
error: cannot execute tool 'metal' due to missing Metal Toolchain
```

Download the Metal Toolchain component:

```bash
xcodebuild -downloadComponent MetalToolchain
```

### Wrong Zig version

```
error: Zig version X.Y.Z is not supported
```

Install the exact Zig version specified in `build.zig.zon` (`minimum_zig_version`).

### macOS SDK not found

```bash
sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer
```

### Architecture mismatch

Verify the built library:

```bash
lipo -info ghostty/Vendor/libghostty.a
# Expected: Architectures in the fat file: libghostty.a are: x86_64 arm64
```

## References

- [Ghostty Build from Source](https://ghostty.org/docs/install/build)
- [Ghostty HACKING.md](https://github.com/ghostty-org/ghostty/blob/main/HACKING.md)
- [Mitchell Hashimoto — Integrating Zig and SwiftUI](https://mitchellh.com/writing/zig-and-swiftui)
