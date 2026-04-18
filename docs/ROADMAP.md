# Roadmap

## v0.1 — current · open-source alpha
- Mac server: built-in **test pattern** source (animated gradient + frame counter)
- iOS SDK: SCMF decode, `FrameSource` protocol, `SimulatorCameraSession`, `SimulatorCameraPreviewView`
- Sample iOS app with live preview
- MIT license, SwiftPM distribution

## v0.2 — "use my real camera"
- Built-in macOS webcam source (`AVCaptureDevice.default(.builtInWideAngleCamera)`)
- Local video-file source (`AVAssetReader` → JPEG)
- Screen-region capture source (`SCStream`)
- Multi-client broadcast (N iOS simulators at once)
- Signed & notarized `.dmg`

## v0.3 — "make it as good as AVFoundation"
- HEVC codec path (opt-in), ~5× bitrate savings
- Audio track (SCMF v2 with interleaved audio samples)
- Depth frames (front TrueDepth parity)
- Front/back camera switch
- ObjC-callable headers for non-Swift apps
- CocoaPods + Carthage distribution

## v0.4 — "fits in my workflow"
- Xcode Source Editor Extension: one-click "Enable SimulatorCamera" for the current target
- Menu-bar Mac app + auto-start on Xcode launch
- CLI: `simcam --source file.mov --port 9876` for CI and Fastlane lanes
- Android Emulator client (Kotlin SDK over the same wire protocol)

## v1.0 — production
- Paid Pro tier: multi-source mixer, scripted frame sequences (replay attacks for QR/barcode QA), per-simulator routing
- Sparkle auto-update
- Enterprise license option (team-wide notarized pkg + offline SDK artifact)
- Uptime guarantees, commercial support SLA

## Post-1.0 backlog
- Visual-regression harness: pipe frames into XCTest screenshot tests
- Ghost-frame injection for glitch / jitter / low-light tests (reliability fuzzing)
- Detox / Appium bindings
- Linux server port (for headless CI agents driving iOS Simulators over network)
