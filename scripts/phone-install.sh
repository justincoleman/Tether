#!/usr/bin/env bash
# Build the iPhone app and install it on the first connected device.
# Requires a signing team configured in Xcode (CODE_SIGN_STYLE=Automatic).
set -euo pipefail
cd "$(dirname "$0")/.."
make project

DEVICE_ID="${TETHER_DEVICE_ID:-$(xcrun devicectl list devices --json-output /dev/stdout 2>/dev/null \
  | python3 -c 'import json,sys; d=json.load(sys.stdin)["result"]["devices"]; print(d[0]["identifier"] if d else "")')}"
[ -n "$DEVICE_ID" ] || { echo "No connected iPhone found. Set TETHER_DEVICE_ID." >&2; exit 1; }

# The project is regenerated on every build, so the team comes from the
# environment rather than Xcode's Signing tab.
TEAM="${TETHER_TEAM_ID:-}"
[ -n "$TEAM" ] || { echo "Set TETHER_TEAM_ID to your Apple Developer team ID (Xcode → Settings → Accounts)." >&2; exit 1; }

xcodebuild -project Apps/Tether.xcodeproj -scheme TetherPhone -configuration Debug \
  -destination "id=$DEVICE_ID" -derivedDataPath build/phone -allowProvisioningUpdates \
  DEVELOPMENT_TEAM="$TEAM" build
APP="$(find build/phone/Build/Products -name 'TetherPhone.app' -maxdepth 2 | head -1)"
xcrun devicectl device install app --device "$DEVICE_ID" "$APP"
echo "Installed $APP on $DEVICE_ID"
