#!/usr/bin/env bash
# Build the iPhone app and install it on the first connected device.
# Requires a signing team configured in Xcode (CODE_SIGN_STYLE=Automatic).
set -euo pipefail
cd "$(dirname "$0")/.."
make project

# devicectl also lists simulators; take the first physical iOS device.
DEVICE_ID="${TETHER_DEVICE_ID:-$(xcrun devicectl list devices --json-output /dev/stdout 2>/dev/null | python3 -c '
import json, sys
devices = json.load(sys.stdin)["result"]["devices"]
phones = [d for d in devices
          if d.get("hardwareProperties", {}).get("reality") == "physical"
          and d.get("hardwareProperties", {}).get("platform") == "iOS"]
print(phones[0]["identifier"] if phones else "")
')}"
[ -n "$DEVICE_ID" ] || { echo "No connected iPhone found. Set TETHER_DEVICE_ID." >&2; exit 1; }

# The project is regenerated on every build, so the team comes from the
# environment rather than Xcode's Signing tab.
TEAM="${TETHER_TEAM_ID:-}"
[ -n "$TEAM" ] || { echo "Set TETHER_TEAM_ID to your Apple Developer team ID (Xcode → Settings → Accounts)." >&2; exit 1; }

xcodebuild -project Apps/Tether.xcodeproj -scheme TetherPhone -configuration Debug \
  -destination "id=$DEVICE_ID" -derivedDataPath build/phone -allowProvisioningUpdates \
  DEVELOPMENT_TEAM="$TEAM" build
# Device builds land in Debug-iphoneos; `make phone` leaves a simulator build beside it.
APP="build/phone/Build/Products/Debug-iphoneos/TetherPhone.app"
[ -d "$APP" ] || { echo "No device build at $APP" >&2; exit 1; }
xcrun devicectl device install app --device "$DEVICE_ID" "$APP"
echo "Installed $APP on $DEVICE_ID"
