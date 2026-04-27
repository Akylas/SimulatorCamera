// MacCameraReader.swift
// macOS Companion App — Optional: stream from the Mac's built-in camera.

import AVFoundation
import CoreImage

/// Captures frames from the Mac's camera and delivers them as CGImage.
final class MacCameraReader: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {

    private let session = AVCaptureSession()
    private let outputQueue = DispatchQueue(label: "com.simulatorcamera.maccamera", qos: .userInteractive)
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    /// Called on `outputQueue` (NOT the main thread) with each camera frame.
    /// Callers must dispatch to the main thread themselves if needed.
    var onFrame: ((CGImage, Double) -> Void)?

    var isRunning: Bool { session.isRunning }

    // MARK: - Setup

    func configure() throws {
        session.beginConfiguration()
        session.sessionPreset = .hd1280x720

        // Find default camera
        guard let device = AVCaptureDevice.default(for: .video) else {
            throw NSError(domain: "MacCameraReader", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "No camera found"])
        }

        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else {
            throw NSError(domain: "MacCameraReader", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Cannot add camera input"])
        }
        session.addInput(input)

        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        output.alwaysCopiesSampleData = false
        output.setSampleBufferDelegate(self, queue: outputQueue)

        guard session.canAddOutput(output) else {
            throw NSError(domain: "MacCameraReader", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "Cannot add video output"])
        }
        session.addOutput(output)
        session.commitConfiguration()
    }

    // MARK: - Start / Stop

    func start() {
        guard !session.isRunning else { return }
        session.startRunning()
    }

    func stop() {
        guard session.isRunning else { return }
        session.stopRunning()
    }

    // MARK: - Delegate

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent) else { return }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let timestamp = CMTimeGetSeconds(pts)

        // Call directly on outputQueue — no main-thread hop.
        // FrameStreamer.sendFrame is thread-safe and dispatches encoding
        // to its own encodeQueue, so calling from here is safe and fast.
        onFrame?(cgImage, timestamp)
    }
}
