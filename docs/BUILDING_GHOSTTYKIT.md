# Building GhosttyKit (libghostty) for Sessylph

Sessylph uses [GhosttyKit](https://github.com/ghostty-org/ghostty) (libghostty) as a static library for Metal-accelerated terminal rendering. This document describes how to build `libghostty.a` and `ghostty.h` from source.

> **Current version:** Sessylph uses **Ghostty v1.3.1** (released 2026-03-17). When upgrading, clone with `--branch v1.3.1` (or the desired tag) instead of using the tip of main.

> **Note:** libghostty is not a stable public API. Ghostty's author (Mitchell Hashimoto) has stated it is "not stable for general purpose use." Expect breaking changes when updating.

## Prerequisites

### Zig

Ghostty requires a **specific version** of Zig. Using a different version (even newer) will fail.

Check the required version in `build.zig.zon` (`minimum_zig_version` field) or Ghostty's [HACKING.md](https://github.com/ghostty-org/ghostty/blob/main/HACKING.md).

```bash
# Install via Homebrew (recommended — includes macOS compatibility patches):
brew install zig

# Or via mise:
mise install zig@0.15.2

# Or download manually from https://ziglang.org/download/

# Verify the installed version matches build.zig.zon requirements:
zig version
# Expected: 0.15.2 (or the version specified in build.zig.zon minimum_zig_version)
```

> **macOS 26 (Tahoe) note:** Zig 0.15.2 stock release has broken libSystem linking on macOS 26. Use `brew install zig` (which includes the fix as 0.15.2_1+) or wait for an upstream fix.

### Other Dependencies

- **Xcode** with macOS SDK (Command Line Tools alone may not be sufficient)
- **Metal Toolchain** (requires separate download on Xcode 26+)
- **gettext** (for translations)

```bash
xcode-select -p  # Verify Xcode is active
xcodebuild -downloadComponent MetalToolchain  # Required on Xcode 26+
brew install gettext
```

## Build Steps

### 1. Clone Ghostty

```bash
# Shallow clone of the specific release tag:
git clone --depth 1 --branch v1.3.1 https://github.com/ghostty-org/ghostty.git /tmp/ghostty-build
cd /tmp/ghostty-build
```

### 2. Build the Static Library

On macOS, Ghostty's build system produces an XCFramework containing `libghostty.a`.

```bash
# Build for native (arm64 macOS only):
zig build -Demit-xcframework=true -Dxcframework-target=native -Doptimize=ReleaseFast
```

> **Note:** The full xcframework build (`-Dxcframework-target=universal`) includes iOS targets whose Metal shaders may fail to compile on some Xcode versions. Use `-Dxcframework-target=native` for macOS-only builds.

### 3. Assemble the Combined Library

The Zig build produces the ghostty C API library and ~15 dependency libraries (FreeType, HarfBuzz, ImGui, etc.) as separate `.a` files in the Zig cache. These must be combined into a single archive.

> **macOS 26 (Tahoe) issue:** `libtool -static` on macOS 26 silently drops Zig-compiled objects that don't have 8-byte alignment. Use the `ar`-based workaround below instead.
>
> **Zig cache dependency:** This procedure relies on Zig's internal cache structure and was verified with Zig 0.15.2 + Ghostty v1.3.1. The cache layout may change across Zig versions.

```bash
BUILD_DIR=/tmp/ghostty-build
ZIG_CACHE=$BUILD_DIR/.zig-cache

# 1. Find all arm64 + macOS (platform 1) static libraries from the Zig cache
WORK=/tmp/ghostty-macos
rm -rf $WORK && mkdir -p $WORK/objs

find $ZIG_CACHE/o -name '*.a' -type f | while read lib; do
    # Check architecture (must be arm64)
    if ! lipo -info "$lib" 2>/dev/null | grep -q 'arm64'; then continue; fi
    # Check platform (must be macOS = platform 1, not iOS = 2 or simulator = 7)
    if ! otool -l "$lib" 2>/dev/null | grep -A2 'LC_BUILD_VERSION' | grep -q 'platform 1'; then continue; fi
    
    PREFIX=$(basename $(dirname "$lib"))
    cd $WORK/objs
    ar x "$lib"
    # Prefix extracted .o files to avoid name collisions
    for f in *.o; do
        [ -f "$f" ] && mv "$f" "${PREFIX}_${f}"
    done
    cd -
done

# 2. Combine all objects into a single archive
find $WORK/objs -name '*.o' > /tmp/objlist.txt
rm -f $WORK/libghostty-combined.a
xargs ar -q $WORK/libghostty-combined.a < /tmp/objlist.txt
ranlib $WORK/libghostty-combined.a

# 3. Verify key symbols are defined
nm -g $WORK/libghostty-combined.a | grep -E '_ghostty_app_free|_ImGui_Begin|_FT_Activate_Size'
```

### 4. Get the Header File

```bash
# The header is in the source tree:
ls /tmp/ghostty-build/include/ghostty.h
```

### 5. Copy to Sessylph

```bash
# From the Sessylph project root:
cp $WORK/libghostty-combined.a ghostty/Vendor/libghostty.a
cp /tmp/ghostty-build/include/ghostty.h ghostty/Vendor/ghostty.h
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
| `libghostty.a` | ~135 MB | Static library (arm64 only, all dependencies bundled) |
| `ghostty.h` | ~33 KB | C header (embedding API) |
| `module.modulemap` | ~67 B | Swift module map for `import GhosttyKit` |

> **Note:** `libghostty.a` is not checked into the repository due to its size. It must be built locally.

## Troubleshooting

### Missing Metal Toolchain

```
error: cannot execute tool 'metal' due to missing Metal Toolchain
```

Download the Metal Toolchain component (required on Xcode 26+):

```bash
xcodebuild -downloadComponent MetalToolchain
```

### Zig linking failure on macOS 26 (Tahoe)

```text
error: undefined symbol: _abort
error: undefined symbol: _free
error: undefined symbol: _bzero
```

Stock Zig 0.15.2 has broken libSystem linking on macOS 26. Install the patched version:

```bash
brew upgrade zig  # Gets 0.15.2_1+ with the fix
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

### Undefined symbols at link time

If Sessylph fails to link with undefined symbols (e.g., `_ImGui_Begin`, `_FT_Activate_Size`), the combined library is missing some dependency archives. Re-run the assembly step (Step 3) and verify all arm64+macOS libraries from the Zig cache are included.

```bash
# Check which library provides a missing symbol:
find $ZIG_CACHE/o -name '*.a' -exec sh -c 'nm -g "$1" 2>/dev/null | grep -l "_MISSING_SYMBOL" && echo "$1"' _ {} \;
```

### Architecture verification

```bash
lipo -info ghostty/Vendor/libghostty.a
# Expected: Non-fat file: ghostty/Vendor/libghostty.a is architecture: arm64
```

## References

- [Ghostty Build from Source](https://ghostty.org/docs/install/build)
- [Ghostty HACKING.md](https://github.com/ghostty-org/ghostty/blob/main/HACKING.md)
- [Mitchell Hashimoto — Integrating Zig and SwiftUI](https://mitchellh.com/writing/zig-and-swiftui)
