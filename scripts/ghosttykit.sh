#!/usr/bin/env bash
# Build libghostty from Ghostty's source and point the Mac app at it, in place
# of the prebuilt XCFramework the libghostty-spm package downloads.
#
#   scripts/ghosttykit.sh             build the Ghostty commit the package pins
#   scripts/ghosttykit.sh --ref <sha> build another Ghostty commit (e.g. newer main)
#   scripts/ghosttykit.sh --off       go back to the prebuilt package
#
# The source build lives in Vendor/libghostty-spm (git-ignored), a checkout of
# the same package version Xcode resolved, whose Package.local.swift points
# the binary target at the local build. `.ghostty-source` is the switch:
# while it exists, `make project` (so `make dev`) uses the vendored package.
# Needs zig 0.16 (`brew install zig`) and Xcode's Metal toolchain.
set -euo pipefail
cd "$(dirname "$0")/.."

VENDOR=Vendor/libghostty-spm
FLAG=.ghostty-source
REPO=https://github.com/Lakr233/libghostty-spm.git
RESOLVED=Apps/Tether.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved

REF=
case "${1:-}" in
  --off)
    rm -f "$FLAG"
    echo "Using the prebuilt libghostty package again. Run make dev to rebuild."
    exit 0
    ;;
  --ref) REF="${2:?--ref needs a Ghostty commit or tag}" ;;
  "") ;;
  *) echo "usage: $0 [--ref <ghostty-commit>] | --off" >&2; exit 1 ;;
esac

command -v zig >/dev/null || { echo "zig not found. Install it with: brew install zig" >&2; exit 1; }
case "$(zig version)" in
  0.16.*) ;;
  *) echo "warning: libghostty-spm builds with zig 0.16; you have $(zig version)." >&2 ;;
esac

# The package version Xcode resolved, so the Swift wrapper matches what the
# app already builds against. Falls back to the newest 2.2.x tag.
TAG=
if [ -f "$RESOLVED" ]; then
  TAG=$(python3 - "$RESOLVED" <<'PY'
import json, sys
pins = json.load(open(sys.argv[1])).get("pins", [])
print(next((p["state"].get("version") or "" for p in pins if p["identity"] == "libghostty-spm"), ""))
PY
)
fi
if [ -z "$TAG" ]; then
  TAG=$(git ls-remote --tags --refs "$REPO" 'refs/tags/2.2.*' | sed 's#.*refs/tags/##' | sort -t. -k1,1n -k2,2n -k3,3n | tail -1)
fi
[ -n "$TAG" ] || { echo "Couldn't find a libghostty-spm version to build." >&2; exit 1; }
echo "libghostty-spm $TAG"

if [ -d "$VENDOR/.git" ]; then
  git -C "$VENDOR" checkout -q -- Package.swift
  git -C "$VENDOR" fetch -q --tags origin
else
  mkdir -p "$(dirname "$VENDOR")"
  git clone -q "$REPO" "$VENDOR"
fi
git -C "$VENDOR" checkout -q "$TAG"

# macOS only: the phone app doesn't embed a terminal.
(cd "$VENDOR" && ./build.sh --platforms macos --skip-tests ${REF:+--ref "$REF"})
[ -d "$VENDOR/BinaryTarget/GhosttyKit.xcframework" ] || { echo "The build produced no XCFramework." >&2; exit 1; }

cp "$VENDOR/Package.local.swift" "$VENDOR/Package.swift"
touch "$FLAG"
echo "Built libghostty from source (Ghostty ${REF:-$(cat "$VENDOR/Ghostty.ref")})."
echo "make dev now uses it. scripts/ghosttykit.sh --off switches back."
