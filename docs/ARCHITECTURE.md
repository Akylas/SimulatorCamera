# Architecture

## Components

```
┌────────────────────────────────────────────────┐          ┌────────────────────────────────────────┐
│           SimCameraServer (macOS)              │          │     iOS Simulator: your app            │
│                                                │          │                                        │
│  ┌──────────────┐  ┌────────────────────────┐  │   TCP    │  ┌────────────────────────────────┐    │
│  │ FrameSource  │→ │ JPEG encoder (ImageIO) │→ │─────────▶│  │ SimulatorCameraSession         │    │
│  │  (pattern /  │  │ SCMF packer            │  │  :9876   │  │   └ SCMFStreamDecoder          │    │
│  │  webcam /    │  │ NWListener (TCP)       │  │          │  │   └ SCMFCodec.pixelBuffer      │    │
│  │  video file) │  │                        │  │          │  │ FrameSourceDelegate callback   │    │
│  └──────────────┘  └────────────────────────┘  │          │  └────────────────────────────────┘    │
│                                                │          │                                        │
└────────────────────────────────────────────────┘          └────────────────────────────────────────┘
```

## Threading

**Server:**
- UI + source picker on `@MainActor`.
- Source acquisition (`AVCaptureSession` or `AVAssetReader`) runs on its own queue.
- `NWListener` + each `NWConnection` run on a single `com.simulatorcamera.server.net` serial queue to serialize sends.
- JPEG encoding happens off-main via `CIContext.jpegRepresentation` on a shared worker queue.

**Client:**
- Networking and decoding run on `com.simulatorcamera.client.network` serial queue.
- All delegate callbacks are hopped to `DispatchQueue.main`. Your Vision/CoreML pipeline can dispatch back off-main as needed.

## Why JPEG, not HEVC?

- No codec licensing questions.
- `ImageIO` + `CGImageSourceCreateWithData` decode is fast on M-series and simulator ARM64.
- At 720p / Q0.8 we average ~55 KB/frame → 13 Mb/s at 30 FPS, trivial over loopback.

HEVC path arrives in v0.3 as an opt-in flag. That adds a 4-byte `codec` word in the payload header.

## Why not a socket file (Unix domain) or shared memory?

- The iOS Simulator shares a filesystem with the host but sandbox rules and file ownership make UDS flaky across Xcode updates.
- Shared memory across the Simulator ↔ host boundary isn't supported publicly.
- TCP over loopback is boring and works everywhere, forever.

## Failure modes

| Symptom | Likely cause |
| --- | --- |
| "Invalid magic" error on iOS | Server sent data with wrong endianness, or the stream got corrupted. Close and reconnect. |
| Alignment / `EXC_BREAKPOINT` at decode | Use `loadUnaligned(fromByteOffset:as:)` instead of `load(...)` on ARM64. |
| Simulator can't connect | Mac app sandbox missing `com.apple.security.network.server`. |
| Frames stop after ~256 KB | Not draining `decoder.nextFrame()` in a loop — only pulling the first frame per receive. |
