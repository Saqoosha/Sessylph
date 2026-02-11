# Building GhosttyKit (libghostty) for Sessylph

Sessylph uses [GhosttyKit](https://github.com/ghostty-org/ghostty) (libghostty) as a static library for Metal-accelerated terminal rendering. This document describes how to build `libghostty.a` and `ghostty.h` from source.

> **Note:** libghostty is not a stable public API. Ghostty's author (Mitchell Hashimoto) has stated it is "not stable for general purpose use." Expect breaking changes when updating.

## Prerequisites

### Zig

Ghostty requires a **specific version** of Zig. Using a different version (even newer) will fail.

Check the required version in Ghostty's [HACKING.md](https://github.com/ghostty-org/ghostty/blob/main/HACKING.md) or `build.zig.zon`.

```bash
# Download the exact version from https://ziglang.org/download/
# Example for Zig 0.14.1 on macOS arm64:
curl -LO https://ziglang.org/builds/zig-macos-aarch64-0.14.1.tar.xz
tar xf zig-macos-aarch64-0.14.1.tar.xz
export PATH="$PWD/zig-macos-aarch64-0.14.1:$PATH"

# Verify
zig version
```

### Other Dependencies

- **Xcode** with macOS SDK (Command Line Tools alone may not be sufficient)
- **gettext** (for translations)

```bash
xcode-select -p  # Verify Xcode is active
brew install gettext
```

## Build Steps

### 1. Clone Ghostty

```bash
git clone https://github.com/ghostty-org/ghostty.git
cd ghostty
```

Or download a release tarball (fewer dependencies than git clone):

```bash
# Check https://ghostty.org/docs/install/build for the latest version
curl -LO https://release.files.ghostty.org/1.2.1/ghostty-1.2.1.tar.gz
tar xzf ghostty-1.2.1.tar.gz
cd ghostty-1.2.1
```

### 2. Build the Static Library

On macOS, Ghostty's build system does not install `libghostty.a` directly — it produces an XCFramework instead. To get the static library, use one of these methods:

#### Method A: Extract from XCFramework (recommended)

```bash
# Build the XCFramework
zig build -Demit-xcframework -Doptimize=ReleaseFast

# The XCFramework is at:
#   macos/GhosttyKit.xcframework/

# Extract libghostty.a (arm64 only)
cp macos/GhosttyKit.xcframework/macos-arm64_x86_64/GhosttyKit.framework/GhosttyKit \
   libghostty.a

# Or extract arm64-only slice from the universal binary:
lipo -thin arm64 \
  macos/GhosttyKit.xcframework/macos-arm64_x86_64/GhosttyKit.framework/GhosttyKit \
  -output libghostty.a
```

#### Method B: Patch build.zig to install directly

```bash
# Edit build.zig — find this block:
#   if (!config.target.result.os.tag.isDarwin()) {
#       libghostty_static.install("libghostty.a");
#   }
#
# Add before the Darwin check:
#   libghostty_static.install("libghostty.a");

zig build -Doptimize=ReleaseFast

# Output at:
ls zig-out/lib/libghostty.a
```

### 3. Get the Header File

```bash
# The header is in the source tree:
ls include/ghostty.h

# Or from the XCFramework:
ls macos/GhosttyKit.xcframework/macos-arm64_x86_64/GhosttyKit.framework/Headers/ghostty.h
```

### 4. Copy to Sessylph

```bash
# From the Sessylph project root:
cp /path/to/ghostty/libghostty.a  ghostty/Vendor/libghostty.a
cp /path/to/ghostty/include/ghostty.h  ghostty/Vendor/ghostty.h
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
| `libghostty.a` | ~135 MB | Static library (arm64), tracked by Git LFS |
| `ghostty.h` | ~33 KB | C header (embedding API) |
| `module.modulemap` | ~67 B | Swift module map for `import GhosttyKit` |

## Troubleshooting

### Wrong Zig version

```
error: Zig version X.Y.Z is not supported
```

Install the exact Zig version specified in Ghostty's build requirements. Each Ghostty release pins a specific Zig version.

### macOS SDK not found

```bash
sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer
```

### Architecture mismatch

Verify the built library matches your Mac's architecture:

```bash
lipo -info ghostty/Vendor/libghostty.a
# Expected: Non-fat file: libghostty.a is architecture: arm64
```

## References

- [Ghostty Build from Source](https://ghostty.org/docs/install/build)
- [Ghostty HACKING.md](https://github.com/ghostty-org/ghostty/blob/main/HACKING.md)
- [Mitchell Hashimoto — Integrating Zig and SwiftUI](https://mitchellh.com/writing/zig-and-swiftui)
