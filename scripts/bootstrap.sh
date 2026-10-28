#!/usr/bin/env bash
# One-time developer setup: installs xcodegen and generates Apps/Tether.xcodeproj.
set -euo pipefail
cd "$(dirname "$0")/.."

if ! command -v xcodegen >/dev/null 2>&1; then
  if command -v brew >/dev/null 2>&1; then
    brew install xcodegen
  else
    echo "xcodegen not found and Homebrew is unavailable. Install from https://github.com/yonaskolb/XcodeGen" >&2
    exit 1
  fi
fi

(cd Apps && xcodegen generate --spec project.yml)
echo "Generated Apps/Tether.xcodeproj"
