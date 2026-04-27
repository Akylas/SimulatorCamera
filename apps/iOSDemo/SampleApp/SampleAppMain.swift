// SampleAppMain.swift
// Demo iOS app that consumes SimulatorCameraClient and runs Vision
// rectangle detection on incoming frames.
//
// In the iOS Simulator, frames come from the macOS companion app.
// On a real device, frames come from the real camera via AVCaptureSession.
// The same recognition pipeline runs in both cases.

import SwiftUI
import Vision
import CoreVideo
import CoreMedia
import SimulatorCameraClient

@main
struct SampleApp: App {
    var body: some Scene {
        WindowGroup {
            CameraDemoView()
        }
    }
}

// MARK: - Demo view

struct CameraDemoView: View {
    @StateObject private var viewModel = CameraDemoViewModel()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            PreviewViewRepresentable(viewModel: viewModel)
                .ignoresSafeArea()

            // Rectangle overlay
            GeometryReader { proxy in
                ForEach(viewModel.detectedRectangles, id: \.uuid) { rect in
                    RectangleOverlay(observation: rect, size: proxy.size)
                }
            }

            // Status overlay
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
        .onAppear { viewModel.start() }
        .onDisappear { viewModel.stop() }
    }

    private var statusBadge: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(viewModel.isConnected ? .green : .orange)
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
final class CameraDemoViewModel: ObservableObject, @MainActor FrameSourceDelegate {
    func frameSource(_ source: any SimulatorCameraClient.FrameSource, didOutput pixelBuffer: CVPixelBuffer, at time: CMTime) {
        self.handleFrame(pixelBuffer: pixelBuffer, time: time)
    }
    

    @Published var detectedRectangles: [VNRectangleObservation] = []
    @Published var statusText = "Idle"
    @Published var isConnected = false
    @Published var framesPerSecond: Double = 0

    // Use the factory — in Simulator it returns a SimulatorCameraFrameSource,
    // on device it returns a DeviceCameraFrameSource. Same interface.
    private let source: FrameSource = SimulatorCameraSession(host: "127.0.0.1", port: 9876)

    // If you want finer-grained control (e.g. to observe state changes) you
    // can instead use SimulatorCameraSession directly in Simulator builds.
    private let visionQueue = DispatchQueue(label: "com.sampleapp.vision", qos: .userInitiated)
    private var pendingPreview: CVPixelBuffer?
    var previewCallback: ((CVPixelBuffer) -> Void)?

    private var frameTimestamps: [CFAbsoluteTime] = []

    func start() {
        statusText = "Connecting…"
        source.delegate = self
        source.start()
    }

    func stop() {
        source.stop()
        statusText = "Stopped"
        isConnected = false
    }

    private func handleFrame(pixelBuffer: CVPixelBuffer, time: CMTime) {
        // Update preview on main thread
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isConnected = true
            self.statusText = "Streaming"
            self.updateFPS()
            self.previewCallback?(pixelBuffer)
        }

        // Run Vision off the main thread
        visionQueue.async { [weak self] in
            self?.runRectangleDetection(on: pixelBuffer)
        }
    }

    private func updateFPS() {
        let now = CFAbsoluteTimeGetCurrent()
        frameTimestamps.append(now)
        frameTimestamps = frameTimestamps.filter { now - $0 < 1.0 }
        framesPerSecond = Double(frameTimestamps.count)
    }

    // MARK: - Vision

    private func runRectangleDetection(on pixelBuffer: CVPixelBuffer) {
        let request = VNDetectRectanglesRequest { [weak self] request, _ in
            let observations = (request.results as? [VNRectangleObservation]) ?? []
            DispatchQueue.main.async {
                self?.detectedRectangles = observations
            }
        }
        request.maximumObservations = 5
        request.minimumConfidence = 0.7
        request.minimumAspectRatio = 0.2

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
        try? handler.perform([request])
    }

}

// MARK: - Preview view (UIViewRepresentable wrapping SimulatorCameraPreviewView)

struct PreviewViewRepresentable: UIViewRepresentable {
    
    @ObservedObject var viewModel: CameraDemoViewModel
    private let previewModel = SimulatorCameraPreviewModel()
    
    func makeCoordinator() -> Coordinator {
        Coordinator(viewModel: viewModel)
    }

    func makeUIView(context: Context) -> UIView {
        let view = SimulatorCameraPreviewView(model: previewModel)
        let hosting = UIHostingController(
            rootView: view
        )

        context.coordinator.hostingController = hosting

        // Route preview frames into SwiftUI view
        viewModel.previewCallback = { [weak previewModel] pb in
            previewModel?.display(pixelBuffer: pb)
        }

        return hosting.view
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
    class Coordinator {
        var viewModel: CameraDemoViewModel
        var hostingController: UIHostingController<SimulatorCameraPreviewView>?

        init(viewModel: CameraDemoViewModel) {
            self.viewModel = viewModel
        }
    }
    
}

// MARK: - Rectangle overlay

struct RectangleOverlay: View {
    let observation: VNRectangleObservation
    let size: CGSize

    var body: some View {
        // Vision's normalized coords: (0,0) bottom-left. UIKit: (0,0) top-left.
        let path = Path { p in
            let tl = convert(observation.topLeft)
            let tr = convert(observation.topRight)
            let br = convert(observation.bottomRight)
            let bl = convert(observation.bottomLeft)
            p.move(to: tl)
            p.addLine(to: tr)
            p.addLine(to: br)
            p.addLine(to: bl)
            p.closeSubpath()
        }
        return path.stroke(Color.yellow, lineWidth: 2)
    }

    private func convert(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x * size.width, y: (1 - point.y) * size.height)
    }
}
