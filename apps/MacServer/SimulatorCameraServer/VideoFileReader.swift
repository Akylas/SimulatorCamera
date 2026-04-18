// VideoFileReader.swift
// macOS Companion App — Decodes video files frame-by-frame using AVAssetReader.

import AVFoundation
import CoreImage
import Foundation

/// Reads a video file and delivers CGImage frames at the video's native frame rate,
/// looping continuously until stopped.
final class VideoFileReader {

    enum State {
        case idle
        case playing
        case stopped
    }

    private(set) var state: State = .idle
    private var asset: AVAsset?
    private var displayLink: CVDisplayLink?
    private var frameQueue: DispatchQueue = DispatchQueue(label: "com.simulatorcamera.videoreader", qos: .userInteractive)

    private var decodedFrames: [(CGImage, CMTime)] = []
    private var currentFrameIndex: Int = 0
    private var lastFrameTime: CFAbsoluteTime = 0
    private var frameDuration: Double = 1.0 / 30.0

    var fpsLimit: Double = 30.0

    /// Called on the main thread with each frame.
    var onFrame: ((CGImage, Double) -> Void)?

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
        let ciContext = CIContext()

        while reader.status == .reading {
            guard let sampleBuffer = trackOutput.copyNextSampleBuffer(),
                  let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
                continue
            }

            let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

            if let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent) {
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

    /// Start playing frames in a loop using a timer.
    @MainActor
    func startPlaying() {
        guard !decodedFrames.isEmpty else { return }
        state = .playing
        currentFrameIndex = 0
        lastFrameTime = CFAbsoluteTimeGetCurrent()
        scheduleNextFrame()
    }

    /// Stop playback.
    @MainActor
    func stopPlaying() {
        state = .stopped
    }

    // MARK: - Frame scheduling

    @MainActor
    private func scheduleNextFrame() {
        guard state == .playing else { return }

        let now = CFAbsoluteTimeGetCurrent()
        let elapsed = now - lastFrameTime
        let delay = max(0, frameDuration - elapsed)

        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.deliverFrame()
        }
    }

    @MainActor
    private func deliverFrame() {
        guard state == .playing, !decodedFrames.isEmpty else { return }

        let (image, pts) = decodedFrames[currentFrameIndex]
        let timestamp = CMTimeGetSeconds(pts)

        onFrame?(image, timestamp)

        // Advance and loop
        currentFrameIndex = (currentFrameIndex + 1) % decodedFrames.count
        lastFrameTime = CFAbsoluteTimeGetCurrent()

        scheduleNextFrame()
    }
}
