#!/bin/bash
# Build a separate, offline-only QA app without changing production sources.
# Requires a healthy booted simulator. Display 1 is the Duo outer screen.
# Capturing a file is not visual verification; inspect every PNG afterward.
set -euo pipefail
cd "$(dirname "$0")/.."
products="${TETHER_PHONE_PRODUCTS:-/tmp/tether-codex-phone/Build/Products/Debug-iphonesimulator}"
preview_dir="${TETHER_PHONE_QA_DIR:-/tmp/tether-phone-workflow-preview}"
device="${TETHER_PHONE_QA_DEVICE:-booted}"
mkdir -p "$preview_dir/TetherPhoneQA.app"
python3 - "$preview_dir" <<'PY'
import pathlib, sys
out = pathlib.Path(sys.argv[1])
connection = pathlib.Path('Apps/Shared/MacConnection.swift').read_text()
assert 'func connect() {' in connection
connection = connection.replace('func connect() {', 'func connect() {\n        return () // QA host never connects to a network.\n', 1)
connection += '''\n@MainActor extension MacConnection {
    func qaInstall(snapshot: Snapshot, transcripts: [SessionID: TranscriptModel]) {
        self.snapshot = snapshot
        self.transcripts = transcripts
        self.status = .online
    }
}\n'''
(out / 'MacConnection.swift').write_text(connection)
store = pathlib.Path('Apps/TetherPhone/Model/PhoneStore.swift').read_text()
assert 'connections = MacKeychain.load().map(MacConnection.init(mac:))' in store
store = store.replace('connections = MacKeychain.load().map(MacConnection.init(mac:))', 'connections = [] // QA host never loads saved pairings.', 1)
store += '''\n@MainActor extension PhoneStore {
    func qaInstall(connection: MacConnection) { connections = [connection] }
}\n'''
(out / 'PhoneStore.swift').write_text(store)
PY
sources=()
while IFS= read -r source; do
    case "$source" in
        */TetherPhoneApp.swift|*/MacConnection.swift|*/PhoneStore.swift) ;;
        *) sources+=("$source") ;;
    esac
done < <(find Apps/TetherPhone Apps/Shared Apps/PhoneShared -name '*.swift' -type f | sort)
sdk="$(xcrun --sdk iphonesimulator --show-sdk-path)"
SDKROOT="$sdk" xcrun swiftc -swift-version 6 -parse-as-library -sdk "$sdk" -target arm64-apple-ios26.0-simulator \
    -I "$products" "${sources[@]}" "$preview_dir/MacConnection.swift" "$preview_dir/PhoneStore.swift" \
    Tests/Native/PhoneWorkflowPreview.swift "$products/TetherProtocol.o" \
    -o "$preview_dir/TetherPhoneQA.app/TetherPhoneQA"
cat > "$preview_dir/TetherPhoneQA.app/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>com.justincoleman.tether.qa.phone</string><key>CFBundleExecutable</key><string>TetherPhoneQA</string><key>CFBundleName</key><string>Tether QA</string><key>CFBundlePackageType</key><string>APPL</string><key>CFBundleVersion</key><string>1</string><key>CFBundleShortVersionString</key><string>1.0</string><key>LSRequiresIPhoneOS</key><true/><key>UIDeviceFamily</key><array><integer>1</integer></array><key>UILaunchScreen</key><dict/></dict></plist>
PLIST
codesign --force --sign - "$preview_dir/TetherPhoneQA.app"
xcrun simctl install "$device" "$preview_dir/TetherPhoneQA.app"
for screen in native command empty overview; do
    xcrun simctl terminate "$device" com.justincoleman.tether.qa.phone >/dev/null 2>&1 || true
    SIMCTL_CHILD_TETHER_QA_SCREEN="$screen" xcrun simctl launch "$device" com.justincoleman.tether.qa.phone
    sleep 2
    xcrun simctl io "$device" screenshot --display="${TETHER_PHONE_QA_DISPLAY:-1}" "/tmp/tether-phone-workflows-$screen.png"
done
printf '%s\n' 'QA screenshots: /tmp/tether-phone-workflows-{native,command,empty,overview}.png'
