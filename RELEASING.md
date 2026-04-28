# Releasing SimulatorCamera

This runbook cuts a signed, notarized, Homebrew-installable release of the
Mac companion app and the iOS Swift Package.

## Prereqs (one-time per repo)

GitHub secrets must be configured on the repo:

| Secret | Purpose |
|---|---|
| `MAC_CERTIFICATE_P12_BASE64` | Developer ID certificate (base64-encoded .p12) |
| `MAC_CERTIFICATE_PASSWORD` | Password for the .p12 file |
| `KEYCHAIN_PASSWORD` | Ephemeral CI keychain password |
| `APPLE_ID` | Apple ID used for notarization |
| `APPLE_APP_PASSWORD` | App-specific password for `notarytool` |
| `APPLE_TEAM_ID` | 10-character Apple team ID |

## Cut a release (automated)

The `Release` workflow in `.github/workflows/release.yml` handles the full
release lifecycle. Trigger it from the GitHub Actions tab:

1. **Go to** Actions → Release → **Run workflow**.
2. **Choose the bump type**: `patch`, `minor`, or `major`.  
   The workflow reads the latest semver tag (or falls back to `CHANGELOG.md`)
   and computes the new version automatically.
3. **Toggle "Create GitHub release and tag"** (default: on).  
   Turn this off for a dry-run that builds and uploads artifacts without
   publishing a release.
4. **Click Run workflow**.

### What the workflow does

| Step | Description |
|---|---|
| Swift Package tests | Runs `swift test` as a gate before the build. |
| Compute version | Determines the current version from git tags and bumps it. |
| Generate release notes | Parses conventional commits since the last tag into Breaking / Features / Fixes / Other sections. |
| Update `CHANGELOG.md` | Inserts a new versioned section below `## [Unreleased]`. |
| Update cask | Bumps `version` in `Casks/simulatorcamera.rb`; fills in the real `sha256` after the build. |
| Import certificate | Imports the Developer ID cert into an ephemeral keychain. |
| Store notarytool profile | Stores Apple credentials under the `SimulatorCameraNotary` keychain profile once, so the build step never handles raw secrets. |
| Build, sign, notarize & package | Runs `scripts/build-release.sh` using the stored keychain profile. |
| Commit version bump | Commits `CHANGELOG.md` and `Casks/simulatorcamera.rb` and pushes to the triggering branch. |
| Create release | Creates the git tag and publishes the GitHub Release with the generated notes and `.dmg` / `.zip` / `.sha256` attachments (when `create_release` is true). |

## Local dry run

```sh
SKIP_NOTARIZE=1 VERSION=X.Y.Z ./scripts/build-release.sh
open dist/
```

Sanity-check that the `.app` launches from the `.dmg` before triggering
the full workflow.

## Update the Homebrew tap

After a successful release the `Casks/simulatorcamera.rb` in **this repo**
is updated automatically. You still need to update the **tap repo**
(`dautovri/homebrew-tap`) separately:

```sh
brew bump-cask-pr \
    --version X.Y.Z \
    --sha256 <dmg-sha256> \
    dautovri/tap/simulatorcamera
```

## Smoke test

```sh
brew update
brew upgrade --cask simulatorcamera
open -a SimulatorCameraServer
```

Then in a throwaway iOS app:
```swift
import SimulatorCameraClient

SimulatorCamera.configure()
SimulatorCamera.start()
```
Verify frames arrive at 25–30 FPS.

## If something goes wrong

- **Notarization stuck.** Check the log:  
  `xcrun notarytool log <submission-id> --keychain-profile SimulatorCameraNotary`  
  Apple tells you exactly which rule tripped.
- **CI artifacts wrong version.** The workflow derives the version from git
  tags; if filenames look wrong, check whether an unexpected semver tag
  exists in the repo (`git tag --sort=-v:refname | head -5`).
- **Need to yank a release.** Delete the tag, delete the GitHub Release, and
  revert the version-bump commit. Existing users stay on whatever they have;
  Homebrew won't downgrade by default.
