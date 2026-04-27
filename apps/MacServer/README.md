# SimCameraServer (Mac)

SwiftUI macOS app that streams frames to iOS Simulator clients over `127.0.0.1:9876` using the [SCMF](../../docs/PROTOCOL.md) wire format.

## Build

Generate the project, then open it in Xcode:

```bash
brew install xcodegen
xcodegen generate --spec apps/MacServer/project.yml
open apps/MacServer/SimulatorCameraServer.xcodeproj
```

## Entitlements

The app runs sandboxed with:

- `com.apple.security.network.server` — accept incoming connections on `127.0.0.1:9876`
- `com.apple.security.network.client` — only if you enable the webcam source, which goes through AVFoundation

## Sources

| File | Purpose |
| --- | --- |
| `SimulatorCameraServerApp.swift` | App entry point |
| `ContentView.swift` | UI: source picker, start/stop, connection list, FPS |
| `FrameStreamer.swift` | `NWListener` on port 9876, SCMF packing, per-client send loop |
| `MacCameraReader.swift` | Built-in webcam source via `AVCaptureDevice` |
| `VideoFileReader.swift` | Video file source via `AVAssetReader` |

The checked-in `project.yml` generates `apps/MacServer/SimulatorCameraServer.xcodeproj`.
