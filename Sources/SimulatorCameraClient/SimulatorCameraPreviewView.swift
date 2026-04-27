//
//  SimulatorCameraPreviewView.swift
//  SimulatorCameraClient
//
//  Drop-in SwiftUI preview that renders frames from a SimulatorCameraSession.
//
//  Rendering strategy
//  ------------------
//  Instead of converting CVPixelBuffer → CIImage → CGImage → UIImage (slow,
//  involves a GPU blit to CPU memory and a SwiftUI diff on every frame), frames
//  are wrapped in a CMSampleBuffer and enqueued directly to an
//  AVSampleBufferDisplayLayer.  The GPU compositor handles display entirely in
//  hardware with zero CPU involvement and without going through the SwiftUI
//  update cycle for the video content.
//
//  The model's @Published properties (fps, state) update at most 4 times/s so
//  the overlay badges re-render cheaply without affecting video throughput.
//

#if canImport(AVFoundation) && canImport(SwiftUI) && canImport(UIKit)
import AVFoundation
import CoreMedia
import CoreVideo
import SwiftUI
import UIKit

// MARK: - Thread-safe layer holder

/// Holds an `AVSampleBufferDisplayLayer` reference so that the
/// `@MainActor`-isolated `SimulatorCameraPreviewModel` can have its layer
/// safely accessed from the background network-delivery queue without an
/// actor hop.
///
/// Strong reference — cleared by `SimulatorCameraLayerView` when the view
/// is torn down.
private final class _LayerHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var layer: AVSampleBufferDisplayLayer?

    func set(_ layer: AVSampleBufferDisplayLayer?) {
        lock.withLock { self.layer = layer }
    }

    /// Enqueue directly from any thread.
    func enqueue(_ sample: CMSampleBuffer) {
        lock.withLock { layer }?.enqueue(sample)
    }

    /// Flush any queued frames (call when the session reconnects).
    func flush() {
        lock.withLock { layer }?.flush()
    }
}

// MARK: - Model

@MainActor
public final class SimulatorCameraPreviewModel: ObservableObject, FrameSourceDelegate {
    @Published public private(set) var fps: Double = 0
    @Published public private(set) var state: FrameSourceState = .idle

    public let session: SimulatorCameraSession

    // Owned by this model; set by SimulatorCameraLayerView when the view appears.
    private let layerHolder = _LayerHolder()

    // FPS throttling — only publish up to 4 updates/s so that SwiftUI only
    // re-renders the small overlay badges, not the full video.
    private var frameTimestamps: [CFTimeInterval] = []
    private var lastFPSUpdate: CFTimeInterval = 0

    nonisolated public init(session: SimulatorCameraSession = .init()) {
        self.session = session
        session.delegate = self
    }

    public func start() { session.start() }
    public func stop()  { session.stop() }

    // Called by SimulatorCameraLayerView when its UIView is created/destroyed.
    func setDisplayLayer(_ layer: AVSampleBufferDisplayLayer?) {
        layerHolder.set(layer)
    }

    // Called by the session when it reconnects — flush stale frames from the layer.
    func flushDisplayLayer() {
        layerHolder.flush()
    }

    // MARK: FrameSourceDelegate

    nonisolated public func frameSource(_ source: FrameSource, didOutput pixelBuffer: CVPixelBuffer, at time: CMTime) {
        enqueuePixelBuffer(pixelBuffer, at: time)
    }

    /// Push a `CVPixelBuffer` directly to the display layer.
    /// Safe to call from any thread (used by `CameraController` in the demo app).
    nonisolated public func display(pixelBuffer: CVPixelBuffer) {
        let time = CMTime(
            value: CMTimeValue(CACurrentMediaTime() * 1_000_000),
            timescale: 1_000_000
        )
        enqueuePixelBuffer(pixelBuffer, at: time)
    }

    nonisolated public func frameSource(_ source: FrameSource, didChangeState newState: FrameSourceState) {
        Task { @MainActor in self.state = newState }
    }

    // MARK: Private

    nonisolated private func enqueuePixelBuffer(_ pixelBuffer: CVPixelBuffer, at time: CMTime) {
        guard let sample = Self.makeSampleBuffer(pixelBuffer: pixelBuffer, time: time) else { return }

        // Direct hardware-compositor enqueue — zero CPU rendering cost.
        // AVSampleBufferDisplayLayer.enqueue() is safe to call from any thread.
        layerHolder.enqueue(sample)

        // Update FPS on the main actor, throttled to ≤4 updates/s.
        let now = CACurrentMediaTime()
        Task { @MainActor in
            self.frameTimestamps.append(now)
            self.frameTimestamps.removeAll { now - $0 > 1.0 }
            if now - self.lastFPSUpdate >= 0.25 {
                self.fps = Double(self.frameTimestamps.count)
                self.lastFPSUpdate = now
            }
        }
    }

    nonisolated private static func makeSampleBuffer(pixelBuffer: CVPixelBuffer, time: CMTime) -> CMSampleBuffer? {
        var formatDesc: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &formatDesc
        ) == noErr, let fd = formatDesc else { return nil }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 30),
            presentationTimeStamp: time,
            decodeTimeStamp: .invalid
        )

        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: fd,
            sampleTiming: &timing,
            sampleBufferOut: &sample
        ) == noErr else { return nil }
        return sample
    }
}

// MARK: - UIView backed by AVSampleBufferDisplayLayer

/// A `UIView` subclass that uses `AVSampleBufferDisplayLayer` as its backing
/// layer so that the Core Animation compositor renders video frames directly
/// on the GPU without any CPU involvement.
public final class SimulatorCameraDisplayView: UIView {
    override public class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }

    public var sampleBufferDisplayLayer: AVSampleBufferDisplayLayer {
        layer as! AVSampleBufferDisplayLayer
    }
}

// MARK: - UIViewRepresentable

/// A hardware-accelerated video preview backed by `AVSampleBufferDisplayLayer`.
///
/// Frames are enqueued directly from the network-delivery queue — no `UIImage`
/// conversion, no SwiftUI diff for video content.
///
/// Use this when you want to compose the preview yourself (add your own overlays,
/// etc.). For a batteries-included view with connection-state and FPS badges, use
/// `SimulatorCameraPreviewView` instead.
public struct SimulatorCameraLayerView: UIViewRepresentable {
    public let model: SimulatorCameraPreviewModel
    public var videoGravity: AVLayerVideoGravity

    public init(
        model: SimulatorCameraPreviewModel,
        videoGravity: AVLayerVideoGravity = .resizeAspectFill
    ) {
        self.model = model
        self.videoGravity = videoGravity
    }

    public func makeCoordinator() -> SimulatorCameraPreviewModel { model }

    public func makeUIView(context: Context) -> SimulatorCameraDisplayView {
        let view = SimulatorCameraDisplayView()
        view.backgroundColor = .black
        view.sampleBufferDisplayLayer.videoGravity = videoGravity
        // Register the layer with the model so frame delivery can enqueue
        // directly to it from any thread.
        model.setDisplayLayer(view.sampleBufferDisplayLayer)
        return view
    }

    public func updateUIView(_ uiView: SimulatorCameraDisplayView, context: Context) {
        uiView.sampleBufferDisplayLayer.videoGravity = videoGravity
    }

    public static func dismantleUIView(_ uiView: SimulatorCameraDisplayView, coordinator: SimulatorCameraPreviewModel) {
        // Detach the layer so the model stops enqueueing to a deallocated view.
        coordinator.setDisplayLayer(nil)
    }
}

// MARK: - Batteries-included SwiftUI wrapper

/// Drop-in SwiftUI camera preview with connection-state and FPS badges.
///
/// - `videoGravity` controls how the video fills the view (default: `.resizeAspectFill`).
/// - Pass a pre-created `SimulatorCameraPreviewModel` to share the session with other
///   parts of your UI; if you omit it a fresh session is created automatically.
public struct SimulatorCameraPreviewView: View {
    @StateObject public var model: SimulatorCameraPreviewModel
    public var videoGravity: AVLayerVideoGravity

    nonisolated public init(
        model: SimulatorCameraPreviewModel = .init(),
        videoGravity: AVLayerVideoGravity = .resizeAspectFill
    ) {
        _model = StateObject(wrappedValue: model)
        self.videoGravity = videoGravity
    }

    public var body: some View {
        SimulatorCameraLayerView(model: model, videoGravity: videoGravity)
            .overlay(alignment: .topLeading) { badge }
            .overlay(alignment: .topTrailing) { fpsBadge }
            .onAppear { model.start() }
            .onDisappear { model.stop() }
    }

    private var badge: some View {
        let (txt, color): (String, Color) = {
            switch model.state {
            case .streaming:     return ("Streaming",         .green)
            case .connecting:    return ("Connecting",        .yellow)
            case .failed(let m): return ("Error: \(m)",       .red)
            case .stopped:       return ("Stopped",           .gray)
            case .idle:          return ("Idle",              .gray)
            }
        }()
        return Label(txt, systemImage: "circle.fill")
            .labelStyle(.titleAndIcon)
            .font(.caption.bold())
            .foregroundStyle(color)
            .padding(8)
            .background(.thinMaterial, in: Capsule())
            .padding(8)
    }

    private var fpsBadge: some View {
        Text(String(format: "%.1f FPS", model.fps))
            .font(.caption.monospacedDigit())
            .padding(8)
            .background(.thinMaterial, in: Capsule())
            .padding(8)
    }
}
#endif
