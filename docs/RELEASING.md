# Releasing Tether

`make dev` builds are unsigned and update with `git pull`. A release is a
Developer ID signed, notarized `Tether.app`, attached to a GitHub release.
Installed release builds find it through Tether → Check for Updates… (and on
their own every six hours).

## One-time setup (Mac mini)

1. **Developer ID certificate.** Xcode → Settings → Accounts → your team →
   Manage Certificates → + → Developer ID Application. Needs the paid
   account (the same one the APNs key came from) and the Account Holder or
   Admin role.
2. **Notary credentials.** Make an app-specific password at
   account.apple.com, then store it in the keychain under the profile name
   the script uses:
   ```
   xcrun notarytool store-credentials tether-notary \
     --apple-id <your Apple ID> --team-id <TEAM_ID> --password <app-specific password>
   ```
   Another profile name works with `TETHER_NOTARY_PROFILE=<name>`.
3. **A public releases repo.** Create `justincoleman/Tether-releases` on
   GitHub: public, with a README so it has a default branch. It holds only
   release zips and notes; the source repo stays private. Another name works
   with `TETHER_RELEASES_REPO=<owner/name>`, but `UpdateCheck.repository`
   must be changed to match.
4. **GitHub CLI.** `brew install gh && gh auth login`, on the Mac that cuts
   releases. Only the script needs it: installed copies read the public repo
   with no login.
5. `export TETHER_TEAM_ID=<TEAM_ID>` (already set if `make phone-install` works).

## Cutting a release

1. Bump `MARKETING_VERSION` in `Apps/project.yml` and add the matching entry
   at the top of `Apps/Tether/Resources/ReleaseNotes.json` (`make test`
   fails otherwise). Commit and push.
2. `make release`. It archives a Release build, exports it signed with
   Developer ID, notarizes and staples it, zips it as `Tether-<version>.zip`,
   and runs `gh release create v<version>` in the releases repo with the
   notes from `ReleaseNotes.json` and the source commit. `scripts/release.sh --no-publish` stops after the zip
   in `build/release/`.
3. First install only: download the zip from the release, unzip, move
   `Tether.app` to /Applications and open it. From then on it updates itself.

## How the updater decides (`UpdateCheck`, TetherCore)

- Lists `GET /repos/justincoleman/Tether-releases/releases`. The repo is
  public, so no login is needed (the unauthenticated limit of 60 requests an
  hour per address is far above one check every six hours). Tether sends no
  token, so a stale one can't break the check.
- Takes the newest release that isn't a draft or pre-release, whose tag
  (`v0.4.0`) is above the running version, and that has a `Tether-*.zip`.
- Downloads it through the API (`Accept: application/octet-stream`),
  dropping the token when GitHub redirects to storage.
- Installs only if the new app passes `codesign` strict validation with the
  requirement `anchor apple generic and certificate leaf[subject.OU] = "<team>"`,
  the team being the running app's own. An unsigned build has no team, so
  it never offers to install.
- Swaps the bundle after Tether quits (the old copy is restored if the move
  fails) and reopens it. Claude tabs resume their sessions as after any restart.

## libghostty from source

`scripts/ghosttykit.sh` (or `make ghostty-source`) checks out the
libghostty-spm version Xcode resolved into `Vendor/libghostty-spm`, builds
its XCFramework from Ghostty's source for macOS with zig 0.16, and drops a
`.ghostty-source` marker. While the marker exists, `make project` rewrites
the spec into `Apps/project.source.yml` with the package pointing at the
vendored copy, so `make dev` and `make release` use the source build.
`--ref <commit>` builds a different Ghostty commit; `--off` removes the
marker. The SPM dependency stays the default until the source build has
been used for a while.
