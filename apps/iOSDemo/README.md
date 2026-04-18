# SimCameraDemo (iOS)

Minimal iOS app showing how to consume `SimulatorCameraClient`. Run the Mac server first, then build & run this demo on an iPhone simulator.

## What it does

- Instantiates `SimulatorCameraSession(host: "127.0.0.1", port: 9876)`
- Renders incoming frames via `SimulatorCameraPreviewView`
- Displays connection state and live FPS
- Runs a Vision `VNDetectRectanglesRequest` (optional) on each frame to prove the `CVPixelBuffer` is real and usable

## Usage

```swift
import SwiftUI
import SimulatorCameraClient

@main
struct SampleApp: App {
    var body: some Scene {
        WindowGroup {
            SimulatorCameraPreviewView()
        }
    }
}
```

See `SampleAppMain.swift` for the full integration including the Vision overlay.
