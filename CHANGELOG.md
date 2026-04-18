# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and
this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.2.0] — 2026-04-15

### Added
- **Full `AVCaptureSession` drop-in shim.** New `SimulatorCaptureSession`, `SimulatorCaptureDevice`, `SimulatorCaptureDeviceInput` types let existing camera-setup code port by prefixing each AVFoundation type with `Simulator`.
- `SimulatorCamera` top-level facade (`configure(host:port:)`, `start()`, `stop()`, `isActive`) — one entry point for the whole SDK.
- Internal `_Router` fan-out: a single network session drives N `SimulatorCameraOutput` / preview sinks.
- **Mac Camera source** in the companion app (`AVCaptureDevice.default(for: .video)`) — pick between video file and live Mac webcam from the server UI.
- Homebrew cask formula + tap instructions for one-line install of the Mac companion app.
- `scripts/build-release.sh` — archive, codesign, notarize, staple, and package the Mac app as both `.dmg` and `.zip`.
- `.github/workflows/release.yml` — tag-driven release: builds artifacts, drafts GitHub Release, uploads the `.dmg` and `.zip`.
- `RELEASING.md` runbook.
- `FUNDING.yml` for GitHub Sponsors / Buy Me a Coffee.

### Changed
- README: Homebrew install path, donation badge, v0.2 feature matrix, new "Full AVCaptureSession drop-in" usage block.
- Package is stable on iOS 16 / macOS 13; no source-breaking changes from 0.1.0 — existing `SimulatorCameraSession` / `SimulatorCameraOutput` code compiles unchanged.

### Fixed
- `SimulatorCameraOutput`: replaced broken `objc_setAssociatedObject(_, String, …)` wiring with a typed `routerToken` — package now compiles cleanly.

## [0.1.0] — 2026-04-14

First public alpha.

### Added
- Monorepo layout with root SwiftPM `Package.swift`.
- `FrameSource` protocol + `SimulatorCameraSession` + `SimulatorCameraPreviewView`.
- Reference SCMF codec and stream decoder.
- Mac companion app with test-pattern source.
- iOS demo app with Vision rectangle-detection hook.
- Protocol spec ([docs/PROTOCOL.md](docs/PROTOCOL.md)), architecture overview, roadmap.
