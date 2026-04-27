import AVFoundation
import CoreImage
import Foundation

final class VideoFileReader {

    enum State {
        case idle
        case playing
        case stopped
    }

    private(set) var state: State = .idle

    private var asset: AVAsset?
    private var track: AVAssetTrack?

    private var reader: AVAssetReader?
    private var trackOutput: AVAssetReaderTrackOutput?

    private let frameQueue = DispatchQueue(
        label: "com.simulatorcamera.videoreader",
        qos: .userInteractive
    )

    /// Called on frameQueue
    var onFrame: ((CGImage, Double) -> Void)?

    private static let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    private var startTime: CFAbsoluteTime = 0
    private var firstPTS: CMTime?
    private var isLooping = true

    // MARK: - Load

    func loadVideo(url: URL) async throws {
        let asset = AVURLAsset(url: url)
        self.asset = asset

        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw NSError(domain: "VideoFileReader", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "No video track"])
        }

        self.track = track
    }

    // MARK: - Playback

    func startPlaying(loop: Bool = true) {
        guard state != .playing else { return }
        state = .playing
        isLooping = loop

        frameQueue.async { [weak self] in
            self?.startReaderAndLoop()
        }
    }

    func stopPlaying() {
        state = .stopped

        frameQueue.async { [weak self] in
            self?.reader?.cancelReading()
            self?.reader = nil
            self?.trackOutput = nil
        }
    }

    // MARK: - Core Loop

    private func startReaderAndLoop() {
        do {
            try setupReader()
            playbackLoop()
        } catch {
            print("[VideoFileReader] Failed to start:", error)
        }
    }

    private func playbackLoop() {
        guard state == .playing else { return }

        while state == .playing {
            autoreleasepool {
                guard let output = trackOutput else { return }

                guard let sampleBuffer = output.copyNextSampleBuffer() else {
                    handleEndOfStream()
                    return
                }

                guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
                    return
                }

                let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

                if firstPTS == nil {
                    firstPTS = pts
                    startTime = CFAbsoluteTimeGetCurrent()
                }

                // 🕒 PTS-based timing
                let elapsedPTS = CMTimeSubtract(pts, firstPTS!)
                let targetTime = CMTimeGetSeconds(elapsedPTS)
                let now = CFAbsoluteTimeGetCurrent() - startTime

                let delay = targetTime - now
                if delay > 0 {
                    Thread.sleep(forTimeInterval: delay)
                }

                let ciImage = CIImage(cvPixelBuffer: pixelBuffer)

                if let cgImage = Self.ciContext.createCGImage(ciImage, from: ciImage.extent) {
                    onFrame?(cgImage, CMTimeGetSeconds(pts))
                }
            }
        }
    }

    // MARK: - Reader Setup

    private func setupReader() throws {
        guard let asset = asset,
              let track = track else {
            throw NSError(domain: "VideoFileReader", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Asset not loaded"])
        }

        reader = try AVAssetReader(asset: asset)

        let outputSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]

        let output = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
        output.alwaysCopiesSampleData = false

        guard let reader = reader else { return }
        reader.add(output)

        if !reader.startReading() {
            throw reader.error ?? NSError(domain: "VideoFileReader", code: 3,
                                          userInfo: [NSLocalizedDescriptionKey: "Failed to start reader"])
        }

        trackOutput = output
        firstPTS = nil
    }

    // MARK: - Looping

    private func handleEndOfStream() {
        guard let reader = reader else { return }

        switch reader.status {
        case .completed:
            if isLooping {
                restartReader()
            } else {
                stopPlaying()
            }

        case .failed:
            print("[VideoFileReader] Reader failed:", reader.error ?? "unknown")
            stopPlaying()

        case .cancelled:
            break

        default:
            break
        }
    }

    private func restartReader() {
        reader?.cancelReading()
        reader = nil
        trackOutput = nil

        do {
            try setupReader()
        } catch {
            print("[VideoFileReader] Restart failed:", error)
            stopPlaying()
        }
    }
}
