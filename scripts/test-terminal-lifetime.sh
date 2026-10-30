#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
check_dir=$(mktemp -d "${TMPDIR:-/tmp}/tether-lifetime.XXXXXX")
swiftc -swift-version 6 -parse-as-library \
  Apps/Tether/Terminal/PersistentTerminalStack.swift \
  Tests/AppLifecycle/TerminalLifetimeCheck.swift \
  -o "$check_dir/terminal-lifetime"
"$check_dir/terminal-lifetime"
