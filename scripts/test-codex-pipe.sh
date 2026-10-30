#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/tether-codex-pipe.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT
swiftc -swift-version 6 Sources/TetherCore/JSONValue.swift \
    Sources/TetherCore/CodexAppServer.swift Tests/Native/CodexPipeSmoke.swift \
    -o "$scratch/pipe-smoke"
"$scratch/pipe-smoke"
