import SwiftUI
import SimulatorCameraClient
import AVFoundation
import CoreMedia
import CoreVideo
import Vision
import QuartzCore
import UIKit

// MARK: - ENTRY

@main
struct SampleApp: App {
    var body: some Scene {
        WindowGroup {
            DemoListView()
        }
    }
}

// MARK: - MODE

enum CameraMode: String, CaseIterable, Identifiable {
//    case proxy = "Proxy (Recommended)"
//    case swizzled = "Swizzled AVFoundation"
    case manual = "Manual Simulator Output"

    var id: String { rawValue }
}

// MARK: - LIST

struct DemoListView: View {
    var body: some View {
        NavigationStack {
            List(CameraMode.allCases) { mode in
                NavigationLink(mode.rawValue) {
                    CameraDemoScreen(mode: mode)
                }
            }
            .navigationTitle("Camera Demo Modes")
        }
    }
}

// MARK: - SCREEN

struct CameraDemoScreen: View {

    let mode: CameraMode
    @StateObject private var viewModel: CameraDemoViewModel

    init(mode: CameraMode) {
        self.mode = mode
        _viewModel = StateObject(
            wrappedValue: CameraDemoViewModel(mode: mode)
        )
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            CameraPreviewView(model: viewModel.previewModel)
                .ignoresSafeArea()

            overlay
        }
        .navigationTitle(mode.rawValue)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { viewModel.start() }
        .onDisappear { viewModel.stop() }
    }

    private var overlay: some View {
        VStack {
            HStack {
                status
                Spacer()
                Text("\(viewModel.framesPerSecond, specifier: "%.1f") FPS")
                    .font(.caption.monospacedDigit())
                    .padding(6)
                    .background(.ultraThinMaterial, in: .capsule)
            }
            .padding()

            Spacer()

            VStack(spacing: 8) {
                Text("Pipeline: \(viewModel.pipelineName)")
                    .font(.caption.bold())
                    .padding(6)
                    .background(.ultraThinMaterial, in: .capsule)

                Text("Detected \(viewModel.detectedRectangles.count)")
                    .font(.footnote)
                    .padding(6)
                    .background(.ultraThinMaterial, in: .capsule)
            }
            .padding(.bottom, 40)
            .foregroundStyle(.white)
        }
    }

    private var status: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(viewModel.isConnected ? .green : .orange)
                .frame(width: 8)

            Text(viewModel.statusText)
                .font(.caption)
        }
        .padding(8)
        .background(.ultraThinMaterial, in: .capsule)
        .foregroundStyle(.white)
    }
}

// MARK: - VIEW MODEL

@MainActor
final class CameraDemoViewModel: ObservableObject {

    @Published var detectedRectangles: [VNRectangleObservation] = []
    @Published var statusText = "Waiting…"
    @Published var isConnected = false
    @Published var framesPerSecond: Double = 0
    @Published var pipelineName: String = ""

    let previewModel = SimulatorCameraPreviewModel()
    private let controller: CameraController

    init(mode: CameraMode) {
        controller = CameraController(previewModel: previewModel, mode: mode)
        pipelineName = mode.rawValue

        controller.onConnected = { [weak self] v in
            self?.isConnected = v
            self?.statusText = v ? "Streaming" : "Waiting"
        }

        controller.onFPS = { [weak self] v in
            self?.framesPerSecond = v
        }

        controller.onRectangles = { [weak self] v in
            self?.detectedRectangles = v
        }
    }

    func start() { controller.start() }
    func stop() { controller.stop() }
}

// MARK: - CAMERA CONTROLLER

final class CameraController: NSObject,
                              AVCaptureVideoDataOutputSampleBufferDelegate {

    enum Mode {
        case proxy
        case swizzled
        case manual
    }

    private let mode: Mode
    let previewModel: SimulatorCameraPreviewModel

    private let frameQueue = DispatchQueue(label: "frames", qos: .userInitiated)
    private let visionQueue = DispatchQueue(label: "vision", qos: .userInitiated)

    var onConnected: ((Bool) -> Void)?
    var onFPS: ((Double) -> Void)?
    var onRectangles: (([VNRectangleObservation]) -> Void)?

#if targetEnvironment(simulator)
    private var session: AnyObject?
    private var output: AnyObject?
#else
    private var captureSession: AVCaptureSession?
#endif

    private var timestamps: [CFAbsoluteTime] = []
    private var didConnect = false
    private var lastUI: CFAbsoluteTime = 0

    init(previewModel: SimulatorCameraPreviewModel, mode: CameraMode) {
        self.previewModel = previewModel
        self.mode = {
            switch mode {
//            case .proxy: return .proxy
//            case .swizzled: return .swizzled
            case .manual: return .manual
            }
        }()
        super.init()
    }

    func start() {
#if targetEnvironment(simulator)
        switch mode {
        case .proxy: startProxy()
        case .swizzled: startSwizzled()
        case .manual: startManual()
        }
#else
        startDevice()
#endif
    }

    func stop() {
#if targetEnvironment(simulator)
        session = nil
        output = nil
        SimulatorCamera.stop()
#else
        let s = captureSession
        captureSession = nil
        frameQueue.async { s?.stopRunning() }
#endif
        DispatchQueue.main.async { self.onConnected?(false) }
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        previewModel.display(pixelBuffer: pb)

        let fps = updateFPS()
        let now = CFAbsoluteTimeGetCurrent()

        if !didConnect || now - lastUI > 0.1 {
            didConnect = true
            lastUI = now

            DispatchQueue.main.async {
                self.onConnected?(true)
                self.onFPS?(fps)
            }
        }

        visionQueue.async {
            self.runVision(pb)
        }
    }

    private func updateFPS() -> Double {
        let now = CFAbsoluteTimeGetCurrent()
        timestamps.append(now)
        timestamps.removeAll { now - $0 > 1 }
        return Double(timestamps.count)
    }

    private func runVision(_ pb: CVPixelBuffer) {
        let req = VNDetectRectanglesRequest()
        let h = VNImageRequestHandler(cvPixelBuffer: pb)
        try? h.perform([req])

        let results = req.results as? [VNRectangleObservation] ?? []
        DispatchQueue.main.async { self.onRectangles?(results) }
    }

#if targetEnvironment(simulator)

    private func startProxy() {
//        let s = SimulatorCamera.makeSession()
//
//        let o = AVCaptureVideoDataOutput()
//        o.setSampleBufferDelegate(self, queue: frameQueue)
//
//        s.addOutput(o)
//        s.startRunning()
//
//        session = s as AnyObject
    }

    private func startSwizzled() {
        SimulatorCamera.install()
        let s = AVCaptureSession()

        let o = AVCaptureVideoDataOutput()
        o.setSampleBufferDelegate(self, queue: frameQueue)

        s.addOutput(o)
        s.startRunning()

        session = s
    }

    private func startManual() {
        let o = SimulatorCameraOutput()
        o.setSampleBufferDelegate(self, queue: frameQueue)

        output = o
        SimulatorCamera.start()
    }

#else

    private func startDevice() { }

#endif
}


// MARK: - Camera preview view

/// Renders frames pushed into `SimulatorCameraPreviewModel` by CameraController.
/// Uses SimulatorCameraLayerView which renders directly via AVSampleBufferDisplayLayer
/// — no UIImage conversion, no SwiftUI diff for video content.
/// Observing the model (not owning a session) means no duplicate network
/// connections are started.
struct CameraPreviewView: View {
    var model: SimulatorCameraPreviewModel

    var body: some View {
        SimulatorCameraLayerView(model: model, videoGravity: .resizeAspectFill)
    }
}
