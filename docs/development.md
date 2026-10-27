# Development

Requires macOS 13+, Swift 5.9+ and [mise](https://mise.jdx.dev).

```sh
task init                     # install tools, create .env, install Git hooks
task check                    # Prettier, ShellCheck, warnings-as-errors build
task fix                      # apply Prettier formatting
swift test --disable-sandbox
swift build --product dp
swift build --product DisplayPanelApp
scripts/test-release-version.sh
python3 scripts/test-signing.py # fake tools only; no keys or privacy prompts
task build:release            # universal .build/DisplayPanel.app (https://taskfile.dev)
```

Tests use fake display writers and DDC channels; they never change real
displays. Create test UserDefaults suites and temp directories (including
sockets and helper-process output) with `makeTestDefaults` and
`makeTestDirectory` from `TestIsolation.swift`. Their names are fixed per
test and they are cleared in teardown, so reruns don't leave files behind.
Opt-in environment variables:

| Variable | Effect |
| --- | --- |
| `DISPLAYPANEL_TEST_LIVE_BLACKOUT=1` | Run a geometry test that briefly covers external screens with black windows |
| `DISPLAYPANEL_ICC_EVIDENCE_DIR=<dir>` | Replay saved ICC profiles (read-only) |
| `DISPLAYPANEL_SETTINGS_FIXTURE_OUTPUT=<dir>` | Write Settings screenshots (below) |
| `DISPLAYPANEL_DISCONNECT_FIXTURE_OUTPUT=<dir>` | Write Full disconnect screenshots |
| `DISPLAYPANEL_SETTINGS_FIXTURE_WIDTH=<pt>` / `_HEIGHT=<pt>` | Screenshot window size (width 440–680) |

Recovery checks that don't change displays are in
[display recovery](display-recovery.md#testing).

## Settings screenshots

Render Settings with fake displays, without launching the app or touching real
monitors:

```sh
mkdir -p /tmp/displaypanel-settings
DISPLAYPANEL_SETTINGS_FIXTURE_OUTPUT=/tmp/displaypanel-settings swift test --disable-sandbox \
  --filter 'SettingsWindowTests.test(Settings|Displays|DismissInputWarning|DisplayAction)FixtureSnapshots'
```

```sh
DISPLAYPANEL_DISCONNECT_FIXTURE_OUTPUT=/tmp/displaypanel-disconnect swift test --disable-sandbox \
  --filter 'DisplayDisconnectIntegrationTests|ExperimentalDisconnectTests'
```

SwiftUI exposes its accessibility tree only to a connected assistive client,
so native UI tests drive AppKit controls and check the rest through the model.

## App icon

`Packaging/AppIcon.icon` is the Icon Composer source. After editing it, run
`task build:icon` (Xcode 26+) to refresh the app icon images, which the README
also shows. The menu-bar mark in `StatusMark.swift` follows the same design.

## Release

The version in `Sources/DisplayPanelCore/CLIHelp.swift` must match the tag's base
version (`1.2.3` for `v1.2.3-beta.1`).

```sh
scripts/package-release.sh v1.2.3
```

This writes universal app and CLI archives with SHA-256 files to `dist/`.
Release CI requires the Developer ID Application identity and signs with the
hardened runtime and a secure timestamp. Local packaging uses the same identity
when configured; otherwise it prints an ad-hoc warning.

With notary credentials, packaging submits both archives with
`xcrun notarytool submit --wait`, staples the app and builds the final app
archive and checksums from the stapled bundle. Before publishing it requires
`xcrun stapler validate`, `codesign --verify --deep --strict` and
`spctl -a -vv -t exec` reporting `source=Notarized Developer ID`. A rejection
prints the notary log and fails. A bare Mach-O cannot be stapled, so the CLI
archive is notarized and Gatekeeper finds its ticket online; a downloaded `dp`
needs network access on first run. Without credentials, local
packaging prints a note and skips notarization unless
`DISPLAYPANEL_REQUIRE_NOTARIZATION=1`, as in release CI.

```sh
export DISPLAYPANEL_NOTARY_KEY_PATH=/path/to/AuthKey_KEYID.p8
export DISPLAYPANEL_NOTARY_KEY_ID=KEYID
export DISPLAYPANEL_NOTARY_ISSUER_ID=ISSUER_UUID
```

General settings shows the packaged release version. When HEAD is not at the
matching release tag, packaging appends the short Git SHA (for example,
`1.2.3 (abc1234)`) to distinguish development builds, with `-dirty` when the
working tree has uncommitted changes. Packaging requires a Git
checkout; bundle marketing and build numbers remain unchanged.

Release builds pass the SDK to the linker (`-Xclang-linker -isysroot`).
Without it, SwiftPM can record macOS 13.0 as the SDK and macOS runs the app
with macOS 13 behavior (for example, truncated Settings rows).
`scripts/package-app.sh` refuses binaries that don't record their SDK.

When cross-building for Intel, find the output with
`swift build … --show-bin-path` and check it with `xcrun lipo -archs`.

### Developer ID identity (owner setup)

Only the owner creates, exports and uploads the private key, `.p12`, its
password and API keys. Agents may prepare commands and check secret names with
`gh secret list`. Never put certificates with private keys, passwords or exports
in the repository, chat or logs. Creating a Developer ID certificate requires the
Apple Developer Program Account Holder role.

1. Create a **Developer ID Application** certificate (developer.apple.com →
   Certificates, or Xcode → Settings → Accounts → Manage Certificates) and keep
   it in the login keychain. Confirm it is valid:

   ```sh
   security find-identity -v -p codesigning
   ```

2. Copy the certificate's 40-character SHA-1 fingerprint (not the quoted name):

   ```sh
   export DISPLAYPANEL_SIGNING_IDENTITY=REPLACE_WITH_40_CHARACTER_CERTIFICATE_SHA1
   export DISPLAYPANEL_REQUIRE_SIGNING=1
   task build:release
   ```

   Both packaging scripts honor these variables. The fingerprint only selects
   the identity. `DISPLAYPANEL_SIGNING_KEYCHAIN` optionally selects a specific
   keychain path. An invalid or unavailable configured identity fails signing;
   it never falls back to ad-hoc. Without an identity, PR/local packaging may use
   ad-hoc signing with a visible warning, unless `DISPLAYPANEL_REQUIRE_SIGNING=1`.
   Direct `swift build` is not app packaging.

   For local `task` runs, set `DISPLAYPANEL_SIGNING_IDENTITY=…` in `.env`
   (created from `example.env` by `task init`; untracked), which the Taskfile
   loads. `task copy:release` refuses an app that is not Developer ID signed for
   the expected team, because each ad-hoc build would make macOS drop
   Accessibility and other privacy grants.

3. Export the identity with its private key as a password-protected `.p12`
   outside the checkout (the commands below use
   `/private/tmp/DisplayPanel-signing.p12`). Keep an encrypted backup in
   owner-controlled storage. Run these commands yourself; the password command
   prompts without putting it in shell history:

   ```sh
   base64 -i /private/tmp/DisplayPanel-signing.p12 | tr -d '\n' | gh secret set DISPLAYPANEL_SIGNING_P12_BASE64 --repo brettinternet/DisplayPanel
   gh secret set DISPLAYPANEL_SIGNING_P12_PASSWORD --repo brettinternet/DisplayPanel
   gh secret set DISPLAYPANEL_SIGNING_IDENTITY --repo brettinternet/DisplayPanel --body "$DISPLAYPANEL_SIGNING_IDENTITY"
   gh secret list --repo brettinternet/DisplayPanel
   ```

   Remove the temporary export through Finder after uploading and backing it up.
   Release CI imports these secrets into a job-local keychain, grants
   `/usr/bin/codesign` access, imports Apple's published Developer ID
   intermediates (`scripts/certificates/`), passes that keychain explicitly,
   temporarily adds it to the runner's keychain search list, and verifies the
   configured identity is valid as is. It never adds trust settings; an expired,
   untrusted or otherwise invalid identity fails. It deletes the temporary
   `.p12`, then restores the original search list and deletes the keychain in an
   `always()` step. Missing secrets, import failures or signing failures prevent
   publication. PR jobs do not receive these secrets. The ephemeral runner is the
   final cleanup boundary if a job is forcibly terminated. Run the **CI**
   workflow manually (`workflow_dispatch`) to check the import, sign a probe and
   validate notary credentials with `notarytool history` (no submission).

4. Create an App Store Connect API key with the Developer role (App Store
   Connect → Users and Access → Integrations) and upload it with its key ID and
   issuer ID:

   ```sh
   base64 -i /path/to/AuthKey_KEYID.p8 | tr -d '\n' | gh secret set DISPLAYPANEL_NOTARY_KEY_BASE64 --repo brettinternet/DisplayPanel
   gh secret set DISPLAYPANEL_NOTARY_KEY_ID --repo brettinternet/DisplayPanel
   gh secret set DISPLAYPANEL_NOTARY_ISSUER_ID --repo brettinternet/DisplayPanel
   ```

   Release CI writes the key with mode 0600 under `$RUNNER_TEMP` and removes it
   in an `always()` step.

The app identifier is `com.brettinternet.displaypanel`; the CLI/helper uses
`com.brettinternet.displaypanel.cli`. Nested code is signed before the app, using
one identity, with `--options runtime --timestamp` and no entitlements. The
designated requirement is codesign's default for Developer ID: the identifier,
`anchor apple generic`, the Developer ID certificate markers and
`certificate leaf[subject.OU] = "4NQM9EVPZ3"`. `scripts/signing.sh` commits that
Team ID and fails if a signature names another team. The requirement contains no
certificate hash or `cdhash`, so it survives certificate renewal. See Apple's
[code-signing requirements](https://developer.apple.com/library/archive/technotes/tn2206/).

### Signing acceptance and rotation

On each packaged app and CLI, run:

```sh
codesign --verify --deep --strict /path/to/DisplayPanel.app
codesign -d -r- /path/to/DisplayPanel.app
codesign -d -r- /path/to/DisplayPanel.app/Contents/Helpers/dp
codesign -d -r- /path/to/dp
codesign -dv /path/to/DisplayPanel.app 2>&1 | grep -E 'flags|Timestamp|TeamIdentifier'
/path/to/DisplayPanel.app/Contents/Helpers/dp help
/path/to/DisplayPanel.app/Contents/Helpers/dp probe --json
```

Each requirement must name the expected identifier, `anchor apple generic` and
the committed Team ID, with no `cdhash`. `codesign -dv` must show
`flags=0x10000(runtime)`, a `Timestamp` and the Team ID. `dp probe` is read-only;
its `symbols` must all be `true`, showing private lookups still resolve under
the hardened runtime. The fake-tool signing tests check policy and command
ordering only; they do not prove macOS accepts the certificate.

With explicit owner approval for desktop interaction, install the app using
`scripts/install-release.swift SOURCE_APP /Applications/DisplayPanel.app`,
verify opening it and Launch at Login registration, then confirm the bundled
helper executes and the installed signature still verifies. The installer copies
the signed bundle without re-signing. Do not run blackout or recovery commands to
test signing.

To rotate (renewal or expiry), create a new Developer ID Application
certificate for the same team, then replace the three `DISPLAYPANEL_SIGNING_*`
repository secrets and the local fingerprint together. The designated
requirement does not change, so privacy grants survive. Changing teams changes
the requirement and the committed Team ID; users must then remove/re-add
DisplayPanel's privacy grant once, as after the first upgrade from a self-signed
or ad-hoc build. A stale enabled switch in System Settings does not prove
permission is valid. Builds signed for the unchanged team are intended to
retain grants. DP-64 checks Accessibility in the app process and requests it
only from the explicit in-app button. Fake-backed tests never open the
permission prompt or move native windows; real window movement and grant-retention
validation still require separate explicit user approval.
