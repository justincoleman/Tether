#!/bin/bash
# Build the Mac app first. Optional arguments select its products and Ghostty headers.
set -euo pipefail
cd "$(dirname "$0")/.."
products=$(cd "${1:-build/mac/Build/Products/Debug}" && pwd)
headers=$(cd "${2:-build/mac/SourcePackages/artifacts/libghostty-spm/libghostty/GhosttyKit.xcframework/macos-arm64_x86_64/Headers}" && pwd)
check_dir=$(mktemp -d "${TMPDIR:-/tmp}/tether-ghostty-lifetime.XXXXXX")
ln -s "$products/GhosttyKit_GhosttyTerminal.bundle" "$check_dir/GhosttyKit_GhosttyTerminal.bundle"
swiftc -swift-version 6 -parse-as-library -target "$(uname -m)-apple-macos26.0" \
  -I "$products" -I "$headers" -I "$headers/libghostty" -L "$products" \
  -lghostty -lc++ -framework Carbon \
  "$products/GhosttyTerminal.o" "$products/GhosttyKit.o" "$products/DisplayLink.o" \
  "$products/TetherCore.o" "$products/TetherProtocol.o" \
  Apps/Tether/Terminal/PersistentTerminalStack.swift Apps/Tether/Terminal/TerminalPane.swift \
  Tests/AppLifecycle/GhosttyLifetimeCheck.swift -o "$check_dir/ghostty-lifetime"
"$check_dir/ghostty-lifetime"
