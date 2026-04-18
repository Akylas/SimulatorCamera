# Contributing

Thanks for considering a contribution! SimulatorCamera is small and opinionated — we keep it that way.

## Ground rules

1. **No private APIs.** Ever. Every symbol we import must be public and documented in Apple's SDK.
2. **No device overhead.** Client code on a real device must compile to a no-op. Guard Simulator-only code with `#if targetEnvironment(simulator)`.
3. **Localhost by default.** Any change that exposes the server on non-loopback interfaces requires explicit opt-in and a loud warning.
4. **Wire format is a contract.** Changes to SCMF need a version bump in [docs/PROTOCOL.md](docs/PROTOCOL.md) and a decoder that handles both versions.

## Dev setup

```bash
git clone https://github.com/dautovri/SimulatorCamera.git
cd SimulatorCamera
swift test                          # SDK unit tests
open apps/MacServer/SimCameraServer.xcodeproj   # Mac server
open apps/iOSDemo/SimCameraDemo.xcodeproj        # Sample iOS app
```

## Pull requests

- Branch off `main`.
- Add/update tests in `Tests/SimulatorCameraClientTests/`.
- Keep PRs small and focused. One feature / bug per PR.
- Run `swiftformat .` and `swiftlint` before pushing (configs in the repo root).
- Update [CHANGELOG.md](CHANGELOG.md) under `[Unreleased]`.

## Filing issues

Use the issue templates. For bugs, include:
- macOS + Xcode + iOS Simulator versions
- Minimal repro (ideally a fork of `apps/iOSDemo`)
- Crash logs / `os_log` output from both sides

## Code of conduct

Be decent. We follow the [Contributor Covenant](https://www.contributor-covenant.org/).
