// VideoFileReader.swift
// macOS Companion App — Decodes video files frame-by-frame using AVAssetReader.

import AVFoundation
import CoreImage
import Foundation

/// Reads a video file and delivers CGImage frames at the video's native frame rate,
/// looping continuously until stopped.
///
/// Frame delivery runs on an internal background queue (not the main thread).
/// Callers' `onFrame` closure is invoked from that queue.
final class VideoFileReader {

    enum State {
        case idle
        case playing
        case stopped
    }

    private(set) var state: State = .idle
    private var asset: AVAsset?

    /// Internal queue used both for frame delivery timing and for `onFrame` callbacks.
    private let frameQueue = DispatchQueue(
        label: "com.simulatorcamera.videoreader",
        qos: .userInteractive
    )

    private var decodedFrames: [(CGImage, CMTime)] = []
    private var currentFrameIndex: Int = 0
    private var frameDuration: Double = 1.0 / 30.0

    var fpsLimit: Double = 30.0

    /// Called on `frameQueue` (NOT the main thread) with each frame.
    /// Callers must dispatch to the appropriate thread themselves if needed.
    var onFrame: ((CGImage, Double) -> Void)?

    // DispatchSourceTimer drives frame pacing on frameQueue — replaces the
    // DispatchQueue.main.asyncAfter chain which tied delivery to main-queue
    // availability and caused frame-rate jitter.
    private var timer: DispatchSourceTimer?

    // Static shared CIContext — GPU-accelerated; never allocate per call.
    private static let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    // MARK: - Public API

    /// Load and pre-decode all frames from a video file.
    /// For very long videos, consider streaming instead — this approach works well
    /// for test clips up to ~60 seconds / 1080p.
    func loadVideo(url: URL) async throws {
        let asset = AVURLAsset(url: url)
        self.asset = asset

        // Get video track
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw NSError(domain: "VideoFileReader", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "No video track found"])
        }

        let nominalFrameRate = try await track.load(.nominalFrameRate)
        if nominalFrameRate > 0 {
            frameDuration = 1.0 / Double(min(nominalFrameRate, Float(fpsLimit)))
        }

        // Decode all frames
        let reader = try AVAssetReader(asset: asset)
        let outputSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        let trackOutput = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
        trackOutput.alwaysCopiesSampleData = false
        reader.add(trackOutput)

        guard reader.startReading() else {
            throw reader.error ?? NSError(domain: "VideoFileReader", code: 2,
                                           userInfo: [NSLocalizedDescriptionKey: "Failed to start reading"])
        }

        var frames: [(CGImage, CMTime)] = []
        // Static shared context — GPU-accelerated; CIContext allocation is ~1–5 ms
        // so we must not create one per call.

        while reader.status == .reading {
            guard let sampleBuffer = trackOutput.copyNextSampleBuffer(),
                  let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
                continue
            }

            let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

            if let cgImage = Self.ciContext.createCGImage(ciImage, from: ciImage.extent) {
                frames.append((cgImage, pts))
            }
        }

        guard !frames.isEmpty else {
            throw NSError(domain: "VideoFileReader", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "No frames decoded"])
        }

        self.decodedFrames = frames
        print("[VideoFileReader] Loaded \(frames.count) frames, frame duration: \(frameDuration)s")
    }

    /// Start playing frames in a loop.
    /// Uses a DispatchSourceTimer on `frameQueue` for accurate, jitter-free
    /// pacing that is independent of main-thread availability.
    @MainActor
    func startPlaying() {
        guard !decodedFrames.isEmpty else { return }
        state = .playing
        currentFrameIndex = 0

        let t = DispatchSource.makeTimerSource(queue: frameQueue)
        // leeway: 2 ms — tight enough for smooth video, loose enough to let
        // the OS coalesce wakeups and save power.
        t.schedule(deadline: .now(), repeating: frameDuration, leeway: .milliseconds(2))
        t.setEventHandler { [weak self] in
            self?.deliverNextFrame()
        }
        t.resume()
        timer = t
    }

    /// Stop playback.
    @MainActor
    func stopPlaying() {
        state = .stopped
        timer?.cancel()
        timer = nil
    }

    // MARK: - Frame delivery (runs on frameQueue)

    private func deliverNextFrame() {
        guard !decodedFrames.isEmpty else { return }
        let (image, pts) = decodedFrames[currentFrameIndex]
        let timestamp = CMTimeGetSeconds(pts)
        // Deliver on frameQueue — FrameStreamer.sendFrame is thread-safe.
        onFrame?(image, timestamp)
        currentFrameIndex = (currentFrameIndex + 1) % decodedFrames.count
    }
}
