#!/usr/bin/env bash
# Build a Developer ID signed, notarized Tether.app and publish it as a
# GitHub release in the public releases repo (TETHER_RELEASES_REPO, default
# justincoleman/Tether-releases, which UpdateCheck.repository must match),
# which installed copies pick up through Check for Updates.
# One-time setup and the full flow: docs/RELEASING.md.
#
#   scripts/release.sh               build, notarize, publish
#   scripts/release.sh --no-publish  build and notarize only (build/release/)
set -euo pipefail
cd "$(dirname "$0")/.."

die() { echo "release: $*" >&2; exit 1; }

PUBLISH=1
[ "${1:-}" = "--no-publish" ] && PUBLISH=0

TEAM="${TETHER_TEAM_ID:-}"
[ -n "$TEAM" ] || die "Set TETHER_TEAM_ID to your Apple Developer team ID."
PROFILE="${TETHER_NOTARY_PROFILE:-tether-notary}"

VERSION=$(sed -n 's/^ *MARKETING_VERSION: "\(.*\)"$/\1/p' Apps/project.yml | head -1)
[ -n "$VERSION" ] || die "No MARKETING_VERSION in Apps/project.yml."
NOTES_VERSION=$(python3 -c 'import json; print(json.load(open("Apps/Tether/Resources/ReleaseNotes.json"))[0]["version"])')
[ "$VERSION" = "$NOTES_VERSION" ] || die "MARKETING_VERSION is $VERSION but ReleaseNotes.json starts at $NOTES_VERSION."
TAG="v$VERSION"
RELEASES_REPO="${TETHER_RELEASES_REPO:-justincoleman/Tether-releases}"

if [ "$PUBLISH" = 1 ]; then
  command -v gh >/dev/null || die "Install the GitHub CLI (brew install gh) and run gh auth login, or pass --no-publish."
  git diff --quiet && git diff --cached --quiet || die "Commit your changes first; a release is built from a clean tree."
  git fetch -q origin
  [ -n "$(git branch -r --contains HEAD)" ] || die "Push $(git rev-parse --short HEAD) first; the release tag points at it."
  gh repo view "$RELEASES_REPO" >/dev/null 2>&1 \
    || die "Can't see $RELEASES_REPO. Create it on GitHub (public, with a README so it has a branch) and run gh auth login."
  # A new repo with no commits passes `gh repo view` but rejects releases ("Repository is empty").
  gh api "repos/$RELEASES_REPO/commits?per_page=1" >/dev/null 2>&1 \
    || die "$RELEASES_REPO has no commits yet. Add a README on GitHub (or push one), then run again."
  if gh release view "$TAG" --repo "$RELEASES_REPO" >/dev/null 2>&1; then die "$TAG is already released. Bump MARKETING_VERSION."; fi
fi

xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1 \
  || die "No notarytool profile \"$PROFILE\". Create it once with: xcrun notarytool store-credentials $PROFILE"

# Over SSH the login keychain is locked and codesign fails; unlock it first.
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
if ! security show-keychain-info "$KEYCHAIN" >/dev/null 2>&1; then
  echo "Unlocking the login keychain so codesign can use your signing key."
  security unlock-keychain "$KEYCHAIN"
fi

OUT=build/release
rm -rf "$OUT"
mkdir -p "$OUT"
make project

echo "Archiving Tether ${VERSION}…"
xcodebuild -quiet -project Apps/Tether.xcodeproj -scheme Tether -configuration Release \
  -archivePath "$OUT/Tether.xcarchive" -derivedDataPath build/release-dd \
  -allowProvisioningUpdates DEVELOPMENT_TEAM="$TEAM" archive

cat > "$OUT/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>developer-id</string>
  <key>teamID</key><string>$TEAM</string>
  <key>signingStyle</key><string>automatic</string>
</dict>
</plist>
PLIST

echo "Signing with Developer ID…"
xcodebuild -quiet -exportArchive -archivePath "$OUT/Tether.xcarchive" -exportPath "$OUT/export" \
  -exportOptionsPlist "$OUT/ExportOptions.plist" -allowProvisioningUpdates
APP="$OUT/export/Tether.app"
[ -d "$APP" ] || die "Export produced no Tether.app."
codesign --verify --deep --strict "$APP"

ZIP="$OUT/Tether-$VERSION.zip"
ditto -c -k --keepParent "$APP" "$ZIP"
echo "Notarizing (usually a few minutes)…"
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$APP"
spctl --assess --type execute "$APP" || die "Gatekeeper rejects the stapled app."
# Zip again so the download carries the stapled ticket.
rm "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
echo "Built $ZIP"

[ "$PUBLISH" = 1 ] || exit 0

NOTES=$(python3 - <<'PY'
import json
entry = json.load(open("Apps/Tether/Resources/ReleaseNotes.json"))[0]
lines = [entry["summary"], ""]
lines += [f"- **{h['title']}** {h['body']}" for h in entry["highlights"]]
print("\n".join(lines))
PY
)
# The tag lands on the releases repo's default branch; the source commit is in the notes.
gh release create "$TAG" "$ZIP" --repo "$RELEASES_REPO" --title "Tether $VERSION" \
  --notes "$NOTES"$'\n\n'"Built from $(git rev-parse --short HEAD)."
echo "Published $TAG. Installed copies see it within six hours, or now with Tether → Check for Updates…"
