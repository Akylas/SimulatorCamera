# SimulatorCamera

> Plug a real camera, a video file, or your screen into the iOS Simulator. Finally.

[![Swift 5.9+](https://img.shields.io/badge/Swift-5.9%2B-orange.svg)](https://swift.org)
[![Platforms](https://img.shields.io/badge/platforms-iOS%2016%20%7C%20macOS%2013-blue.svg)](#installation)
[![SwiftPM](https://img.shields.io/badge/SwiftPM-compatible-brightgreen.svg)](#installation)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Release](https://img.shields.io/github/v/release/dautovri/SimulatorCamera?include_prereleases&label=release)](../../releases)
[![CI](https://github.com/dautovri/SimulatorCamera/actions/workflows/ci.yml/badge.svg)](../../actions)
[![Sponsor](https://img.shields.io/github/sponsors/dautovri?label=Sponsor&logo=github-sponsors)](https://github.com/sponsors/dautovri)

The iOS Simulator has never supported a real camera. `AVCaptureDevice` is empty. Every app that touches the camera — QR scanners, barcode readers, document capture, ML pipelines, AR prototypes — either stubs out the camera path, runs only on device, or ships a brittle "use a photo instead" fallback.

**SimulatorCamera** is a tiny two-piece developer tool that fixes it:

- a **macOS companion app** that streams video frames over `localhost:9876` using a compact binary protocol (SCMF — Simulator Camera Message Format), and
- an **iOS Swift Package** with an `AVCaptureSession`-shaped API. On device it compiles to a no-op.

Frames show up in your app. Vision, VisionKit, Core ML, barcode detection, custom pipelines — the SDK is designed to drive them in the Simulator at 25–30 FPS over localhost, no device, no cables, no private APIs.

---

## Why

Every camera-using app today has one of these:

```swift
#if targetEnvironment(simulator)
// TODO: fake it somehow
#else
let session = AVCaptureSession()
// ...real code
#endif
```

This project deletes that `TODO`. Same API shape in the Simulator and on device.

## Features

- 🎥 Live video into the Simulator at 30 FPS via `localhost` TCP
- 🧩 Drop-in SDK — `FrameSource` mirrors `AVCaptureSession` semantics (`start()`, `stop()`, delegate, `CVPixelBuffer` callbacks)
- 🔌 Sources on the Mac: test pattern (built-in), webcam, video file, screen region *(roadmap)*
- 📦 One-line install via Swift Package Manager
- 🛡 No private APIs — `Network.framework` + `CoreVideo` + `ImageIO`
- 📵 Zero overhead on device — `#if targetEnvironment(simulator)`-guarded
- 🔐 Localhost-only by default
- 🧪 Vision / Core ML ready — frames land as `CVPixelBuffer`

## Installation

### iOS SDK — Swift Package Manager

```swift
dependencies: [
    .package(url: "https://github.com/Akylas/SimulatorCamera.git", from: "1.0.0"),
],
targets: [
    .target(
        name: "MyApp",
        dependencies: [
            .product(name: "SimulatorCameraClient", package: "SimulatorCamera"),
        ]
    ),
]
```

Or in Xcode: **File → Add Package Dependencies…** → paste the repo URL.

### macOS companion app

**Homebrew (recommended):**

```bash
brew tap akylas/simulatorcamera https://github.com/Akylas/SimulatorCamera
brew install simulatorcamera
open -a SimulatorCameraServer
```

Or grab the signed & notarized `.dmg` from [Releases](../../releases). Or build from source:

```bash
git clone https://github.com/dautovri/SimulatorCamera.git
cd SimulatorCamera
brew install xcodegen
xcodegen generate --spec apps/MacServer/project.yml
open apps/MacServer/SimulatorCameraServer.xcodeproj
```

## Usage

1. Launch **SimCameraServer.app** on your Mac. Pick a source and click Start.
2. In your iOS code:

```swift
import SimulatorCameraClient

final class CameraController: NSObject, FrameSourceDelegate {
    private let source: FrameSource

    override init() {
        #if targetEnvironment(simulator)
        source = SimulatorCameraSession(host: "127.0.0.1", port: 9876)
        #else
        source = AVCaptureFrameSource() // your existing AVCapture wrapper
        #endif
        super.init()
        source.delegate = self
        source.start()
    }

    func frameSource(_ source: FrameSource, didOutput pixelBuffer: CVPixelBuffer, at time: CMTime) {
        // Feed to Vision, Core ML, preview layer, whatever.
    }
}
```

### Full AVCaptureSession drop-in

The shim now mirrors the whole `AVCaptureSession → addInput → addOutput → startRunning` dance. Your existing camera-setup code ports over by prefixing each type with `Simulator`:

```swift
import SimulatorCameraClient

SimulatorCamera.configure(host: "127.0.0.1", port: 9876)

let session = SimulatorCaptureSession()
session.sessionPreset = .hd1280x720

guard let device = SimulatorCaptureDevice.default(for: .video) else { return }
let input = try SimulatorCaptureDeviceInput(device: device)
session.addInput(input)

let output = SimulatorCameraOutput()          // AVCaptureVideoDataOutput-shaped
output.setSampleBufferDelegate(self, queue: frameQueue)
session.addOutput(output)

session.startRunning()                         // kicks off the network session
```

Your existing `captureOutput(_:didOutput:from:)` delegate fires with a valid `CMSampleBuffer` wrapping a `CVPixelBuffer` — same code path as the real device.

### Zero-change AVFoundation path (recommended)

If you already have an `AVCaptureVideoDataOutputSampleBufferDelegate`,
swap the output for `SimulatorCameraOutput` inside a simulator guard
and keep your delegate code unchanged. The standard
`captureOutput(_:didOutput:from:)` method fires with a real
`CMSampleBuffer` — `SimulatorCameraOutput` is an `AVCaptureVideoDataOutput`
subclass, so the first argument is a genuine AV output, not a stand-in:

```swift
#if targetEnvironment(simulator)
let output = SimulatorCameraOutput()
output.setSampleBufferDelegate(self, queue: myQueue)
SimulatorCamera.start()
#else
let output = AVCaptureVideoDataOutput()
output.setSampleBufferDelegate(self, queue: myQueue)
session.addOutput(output)
#endif
```

Or use the drop-in SwiftUI view:

```swift
import SwiftUI
import SimulatorCameraClient

struct ContentView: View {
    var body: some View {
        SimulatorCameraPreviewView()
    }
}
```

## Protocol (SCMF)

```
+--------+---------------+------------------+--------+---------+----------+
| magic  | payloadLength | timestamp        | width  | height  | jpegData |
| 4 B    | 4 B uint32 LE | 8 B Float64 LE   | 4 B LE | 4 B LE  | N bytes  |
| "SCMF" |                                                                |
+--------+---------------+------------------+--------+---------+----------+
```

Full spec: [docs/PROTOCOL.md](docs/PROTOCOL.md) · architecture: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) · roadmap: [docs/ROADMAP.md](docs/ROADMAP.md).

## Repo layout

```
SimulatorCamera/
├── Package.swift                        # SwiftPM manifest (exposes SimulatorCameraClient)
├── Sources/SimulatorCameraClient/       # the iOS SDK
├── Tests/SimulatorCameraClientTests/    # unit tests for the SCMF codec
├── apps/
│   ├── MacServer/                       # SwiftUI macOS companion app
│   └── iOSDemo/                         # sample iOS app using the SDK
├── docs/
│   ├── PROTOCOL.md                      # wire format
│   ├── ARCHITECTURE.md                  # threading, transport, failure modes
│   └── ROADMAP.md
├── Casks/simulatorcamera.rb             # Homebrew cask formula
├── scripts/
│   ├── bootstrap.sh                     # swift build + test
│   └── build-release.sh                 # archive + codesign + notarize + .dmg/.zip
├── .github/
│   ├── FUNDING.yml                      # GitHub Sponsors / BMC
│   └── workflows/
│       ├── ci.yml                       # SwiftPM CI on macos-14
│       └── release.yml                  # tag-driven signed release
└── RELEASING.md                         # release runbook
```

## Development

```bash
./scripts/bootstrap.sh   # swift build && swift test
brew install xcodegen
xcodegen generate --spec apps/MacServer/project.yml
xcodegen generate --spec apps/iOSDemo/project.yml
```

## Status

**v0.2.0 — "Use my real camera."** First stable release with a drop-in `AVCaptureSession` shim and live Mac webcam source. See [CHANGELOG.md](CHANGELOG.md) and [docs/RELEASE_NOTES_v0.2.0.md](docs/RELEASE_NOTES_v0.2.0.md).

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Good first issues are labelled on the tracker. For release mechanics, see [RELEASING.md](RELEASING.md).

## Sponsor

SimulatorCamera is fully MIT-licensed and maintained on donations. If it saves you a device-build loop, consider [sponsoring](https://github.com/sponsors/dautovri) or [buying a coffee](https://www.buymeacoffee.com/dautovri). No paid tier, no license keys, no telemetry — just a tip jar.

## License

MIT — see [LICENSE](LICENSE).
