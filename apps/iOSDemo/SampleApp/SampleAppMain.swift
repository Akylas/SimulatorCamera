// SampleAppMain.swift
// Demo iOS app: classic Vision rectangle detection driven by AVFoundation.
//
// In the iOS Simulator, frames are supplied by SimulatorCameraOutput (which
// receives JPEG frames from the macOS companion app and calls the standard
// AVCaptureVideoDataOutputSampleBufferDelegate — no simulator-specific
// branching inside the delegate).  On a real device the same delegate
// receives frames from a real AVCaptureSession + AVCaptureVideoDataOutput.
//
// Threading model
// ---------------
//   frameQueue  (serial, userInitiated)
//     • AVCaptureVideoDataOutput / SimulatorCameraOutput delivers here.
//     • CameraController.captureOutput() runs here.
//     • frameTimestamps and didReportConnected are exclusively on this queue.
//
//   visionQueue (serial, userInitiated)
//     • VNDetectRectanglesRequest runs here, keeping frameQueue responsive.
//     • Results are dispatched to the main queue for UI updates.
//
//   Main queue / @MainActor
//     • All @Published mutations, all UIKit/SwiftUI rendering.
//     • SimulatorCameraPreviewModel.display(pixelBuffer:) is nonisolated
//       and internally dispatches to MainActor — safe to call from frameQueue.

import AVFoundation
import CoreMedia
import CoreVideo
import SimulatorCameraClient
import SwiftUI
import Vision

// MARK: - App entry point

@main
struct SampleApp: App {
    var body: some Scene {
        WindowGroup {
            CameraDemoView()
        }
    }
}

// MARK: - Root view

struct CameraDemoView: View {
    @StateObject private var viewModel = CameraDemoViewModel()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // Camera preview — renders frames fed via CameraController.
            CameraPreviewView(model: viewModel.previewModel)
                .ignoresSafeArea()

            // Vision rectangle overlay
            GeometryReader { proxy in
                ForEach(viewModel.detectedRectangles, id: \.uuid) { rect in
                    RectangleOverlay(observation: rect, size: proxy.size)
                }
            }

            // Status + FPS badges
            VStack {
                HStack {
                    statusBadge
                    Spacer()
                    Text("\(viewModel.framesPerSecond, specifier: "%.1f") FPS")
                        .font(.caption.monospacedDigit())
                        .padding(6)
                        .background(.ultraThinMaterial, in: .rect(cornerRadius: 8))
                }
                .padding()
                Spacer()
                Text("Detected \(viewModel.detectedRectangles.count) rectangle(s)")
                    .font(.footnote)
                    .padding(8)
                    .background(.ultraThinMaterial, in: .capsule)
                    .padding(.bottom, 40)
            }
            .foregroundStyle(.white)
        }
        .onAppear  { viewModel.start() }
        .onDisappear { viewModel.stop() }
    }

    private var statusBadge: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(viewModel.isConnected ? Color.green : Color.orange)
                .frame(width: 8, height: 8)
            Text(viewModel.statusText)
                .font(.caption)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial, in: .capsule)
    }
}

// MARK: - View model

@MainActor
final class CameraDemoViewModel: ObservableObject {

    @Published var detectedRectangles: [VNRectangleObservation] = []
    @Published var statusText = "Waiting for camera…"
    @Published var isConnected = false
    @Published var framesPerSecond: Double = 0

    /// Observed directly by CameraPreviewView; frames are pushed into it by
    /// CameraController via display(pixelBuffer:) — no session is started inside.
    let previewModel = SimulatorCameraPreviewModel()

    private let controller: CameraController

    init() {
        let ctrl = CameraController(previewModel: previewModel)
        controller = ctrl

        // All callbacks are already dispatched to the main queue by CameraController.
        ctrl.onConnected = { [weak self] connected in
            self?.isConnected = connected
            self?.statusText = connected ? "Streaming" : "Waiting for camera…"
        }
        ctrl.onFPS = { [weak self] fps in
            self?.framesPerSecond = fps
        }
        ctrl.onRectangles = { [weak self] rects in
            self?.detectedRectangles = rects
        }
    }

    func start() { controller.start() }
    func stop()  { controller.stop() }
}

// MARK: - Camera controller

/// Manages the capture pipeline for both environments.
///
/// In the Simulator:
///   - Creates a `SimulatorCameraOutput` (AVCaptureVideoDataOutput subclass).
///   - Sets `self` as the sample-buffer delegate on `frameQueue`.
///   - Calls `SimulatorCamera.start()` to open the TCP connection to the
///     macOS companion app.
///
/// On device:
///   - Builds a real `AVCaptureSession` with the back camera.
///   - Adds a real `AVCaptureVideoDataOutput` with `self` as delegate on `frameQueue`.
///
/// The `AVCaptureVideoDataOutputSampleBufferDelegate` implementation is the
/// same code path in both environments.
final class CameraController: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {

    // MARK: Callbacks — always invoked on the main queue.
    var onConnected: ((Bool) -> Void)?
    var onFPS: ((Double) -> Void)?
    var onRectangles: (([VNRectangleObservation]) -> Void)?

    // MARK: Private

    private let previewModel: SimulatorCameraPreviewModel

    /// Serial queue on which AVFoundation / SimulatorCameraOutput delivers frames.
    private let frameQueue = DispatchQueue(
        label: "com.sampleapp.camera.frames",
        qos: .userInitiated
    )
    /// Separate serial queue for Vision — keeps frameQueue responsive.
    private let visionQueue = DispatchQueue(
        label: "com.sampleapp.camera.vision",
        qos: .userInitiated
    )

    // Accessed exclusively on frameQueue — no locking needed.
    private var frameTimestamps: [CFAbsoluteTime] = []
    private var didReportConnected = false
    /// Tracks the last time a UI-update was dispatched to the main queue.
    /// Coalesces FPS/connected dispatches to ≤10 per second so the main
    /// runloop isn't flooded at the full camera frame rate.
    private var lastUIDispatchTime: CFAbsoluteTime = 0

    // MARK: Platform-specific capture state

#if targetEnvironment(simulator)
    /// Retained so the router subscription stays alive.
    private var simOutput: SimulatorCameraOutput?
#else
    private var captureSession: AVCaptureSession?
#endif

    // MARK: Init

    init(previewModel: SimulatorCameraPreviewModel) {
        self.previewModel = previewModel
        super.init()
    }

    // MARK: Start / Stop

    func start() {
#if targetEnvironment(simulator)
        startSimulator()
#else
        startDevice()
#endif
    }

    func stop() {
#if targetEnvironment(simulator)
        // Releasing simOutput triggers deinit → _Router.unsubscribeOutput — no more frames.
        simOutput = nil
        SimulatorCamera.stop()
#else
        // stopRunning() blocks; run it off the main thread.
        let session = captureSession
        captureSession = nil
        frameQueue.async { session?.stopRunning() }
#endif
        // Reset connected state on the main queue.
        let cb = onConnected
        didReportConnected = false
        DispatchQueue.main.async { cb?(false) }
    }

    // MARK: AVCaptureVideoDataOutputSampleBufferDelegate
    //
    // Called on frameQueue by both AVCaptureVideoDataOutput (device) and
    // SimulatorCameraOutput (simulator).

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        // Push frame to the preview view.
        // display(pixelBuffer:) is nonisolated and dispatches to @MainActor internally.
        previewModel.display(pixelBuffer: pixelBuffer)

        // FPS tracking — all state is on frameQueue, safe without locking.
        let fps = updateFPS()
        let now = CFAbsoluteTimeGetCurrent()

        // Signal first-frame connection, and rate-limit all other main-queue
        // UI updates to ≤10/s so we don't flood the main runloop at 30 fps.
        let needConnected = !didReportConnected
        let needFPS = (now - lastUIDispatchTime >= 0.1)
        if needConnected || needFPS {
            if needConnected { didReportConnected = true }
            if needFPS       { lastUIDispatchTime = now }
            let connCb = needConnected ? onConnected : nil
            let fpsCb  = needFPS       ? onFPS       : nil
            DispatchQueue.main.async {
                connCb?(true)
                fpsCb?(fps)
            }
        }

        // Vision runs on a separate queue so it does not block frame delivery.
        // CVPixelBuffer retains backing memory as long as the closure holds it.
        visionQueue.async { [weak self, pixelBuffer] in
            self?.runRectangleDetection(on: pixelBuffer)
        }
    }

    // MARK: Private — FPS

    /// Must only be called from frameQueue.
    private func updateFPS() -> Double {
        let now = CFAbsoluteTimeGetCurrent()
        frameTimestamps.append(now)
        frameTimestamps.removeAll { now - $0 >= 1.0 }
        return Double(frameTimestamps.count)
    }

    // MARK: Private — Vision (runs on visionQueue)

    private func runRectangleDetection(on pixelBuffer: CVPixelBuffer) {
        let request = VNDetectRectanglesRequest()
        request.maximumObservations = 5
        request.minimumConfidence   = 0.7
        request.minimumAspectRatio  = 0.2

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
        try? handler.perform([request])

        let observations = (request.results as? [VNRectangleObservation]) ?? []
        let cb = onRectangles
        DispatchQueue.main.async { cb?(observations) }
    }

    // MARK: Private — platform setup

#if targetEnvironment(simulator)

    private func startSimulator() {
        let output = SimulatorCameraOutput()
        // Delegate receives CMSampleBuffer on frameQueue — same threading as a
        // real AVCaptureVideoDataOutput on device.
        output.setSampleBufferDelegate(self, queue: frameQueue)
        simOutput = output
        SimulatorCamera.start()
    }

#else

    private func startDevice() {
        // Camera permission check — must not block the main thread.
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            guard let self, granted else { return }
            self.frameQueue.async { self.setupAndStartSession() }
        }
    }

    /// Called on frameQueue.
    private func setupAndStartSession() {
        let session = AVCaptureSession()
        session.beginConfiguration()
        session.sessionPreset = .hd1280x720

        // Input: back wide-angle camera.
        guard
            let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
            let input  = try? AVCaptureDeviceInput(device: device),
            session.canAddInput(input)
        else {
            session.commitConfiguration()
            return
        }
        session.addInput(input)

        // Output: raw pixel buffers delivered to frameQueue.
        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        output.alwaysCopiesSampleData = false
        output.setSampleBufferDelegate(self, queue: frameQueue)

        guard session.canAddOutput(output) else {
            session.commitConfiguration()
            return
        }
        session.addOutput(output)
        session.commitConfiguration()

        captureSession = session
        session.startRunning()
    }

#endif
}

// MARK: - Camera preview view

/// Renders frames pushed into `SimulatorCameraPreviewModel` by CameraController.
/// Observing the model (not owning a session) means no duplicate network
/// connections are started.
struct CameraPreviewView: View {
    @ObservedObject var model: SimulatorCameraPreviewModel

    var body: some View {
        Group {
            if let img = model.image {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFill()
            } else {
                Color.black
                    .overlay {
                        ProgressView("Waiting for camera…")
                            .tint(.white)
                            .foregroundStyle(.white)
                    }
            }
        }
    }
}

// MARK: - Rectangle overlay

struct RectangleOverlay: View {
    let observation: VNRectangleObservation
    let size: CGSize

    var body: some View {
        // Vision uses normalised coords with (0,0) at bottom-left;
        // SwiftUI/UIKit have (0,0) at top-left — flip the Y axis.
        Path { p in
            let tl = flip(observation.topLeft)
            let tr = flip(observation.topRight)
            let br = flip(observation.bottomRight)
            let bl = flip(observation.bottomLeft)
            p.move(to: tl)
            p.addLine(to: tr)
            p.addLine(to: br)
            p.addLine(to: bl)
            p.closeSubpath()
        }
        .stroke(Color.yellow, lineWidth: 2)
    }

    private func flip(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x * size.width, y: (1 - point.y) * size.height)
    }
}
