#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/tether-codex-driver.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT
# Compile the real driver and its Foundation dependencies without app settings,
# Xcode, network access, a Codex account, or any inference.
swiftc -swift-version 6 -parse-as-library -emit-library -static -emit-module \
    -module-name TetherProtocol Sources/TetherProtocol/*.swift \
    -emit-module-path "$scratch/TetherProtocol.swiftmodule" -o "$scratch/libTetherProtocol.a"
swiftc -swift-version 6 -parse-as-library -emit-library -static -emit-module \
    -module-name TetherCore -I "$scratch" \
    Sources/TetherCore/*.swift \
    -emit-module-path "$scratch/TetherCore.swiftmodule" -o "$scratch/libTetherCore.a"
swiftc -swift-version 6 -I "$scratch" -L "$scratch" \
    -lTetherCore -lTetherProtocol \
    Apps/Tether/Mirror/CodexChatDriver.swift Tests/Native/CodexDriverSmoke.swift \
    -o "$scratch/driver-smoke"
"$scratch/driver-smoke" "$repo_root/Tests/Native/fake-codex"
