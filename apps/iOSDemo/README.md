# SimCameraDemo (iOS)

Classic Vision rectangle-detection demo that uses `AVFoundation` on both
device and Simulator.  Run the Mac server first, then build & run this demo
on an iPhone simulator.

## What it does

- **Simulator** — creates `SimulatorCameraOutput` (an `AVCaptureVideoDataOutput`
  subclass) and calls `SimulatorCamera.start()` to receive frames from the
  macOS companion app over TCP.
- **Device** — creates a real `AVCaptureSession` + `AVCaptureVideoDataOutput`
  backed by the back camera.
- The same `AVCaptureVideoDataOutputSampleBufferDelegate` runs Vision
  `VNDetectRectanglesRequest` in both environments.
- Renders the live preview frame-by-frame and overlays detected rectangles.

## Architecture

```
CameraController (NSObject, AVCaptureVideoDataOutputSampleBufferDelegate)
  │
  ├─ #if simulator  SimulatorCameraOutput.setSampleBufferDelegate(self, queue: frameQueue)
  │                 SimulatorCamera.start()
  │
  └─ #else          AVCaptureSession + AVCaptureVideoDataOutput.setSampleBufferDelegate(self, queue: frameQueue)
        │
        ▼
captureOutput(_:didOutput:from:)   ← called on frameQueue in BOTH environments
  ├─ previewModel.display(pixelBuffer:)  → @MainActor (via Task)
  ├─ FPS update  → DispatchQueue.main
  └─ visionQueue.async { VNDetectRectanglesRequest } → DispatchQueue.main
```

## Generate & open

```bash
brew install xcodegen
xcodegen generate --spec apps/iOSDemo/project.yml
open apps/iOSDemo/SimCameraDemo.xcodeproj
```

## Key pattern

```swift
#if targetEnvironment(simulator)
let output = SimulatorCameraOutput()
output.setSampleBufferDelegate(self, queue: frameQueue)
SimulatorCamera.start()
#else
let output = AVCaptureVideoDataOutput()
output.setSampleBufferDelegate(self, queue: frameQueue)
session.addOutput(output)
#endif
```

See `SampleAppMain.swift` for the complete implementation.
