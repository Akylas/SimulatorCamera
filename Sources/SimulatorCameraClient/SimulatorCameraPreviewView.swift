//
//  SimulatorCameraPreviewView.swift
//  SimulatorCameraClient
//
//  Drop-in SwiftUI preview that renders frames from a SimulatorCameraSession.
//

#if canImport(SwiftUI) && canImport(UIKit)
import CoreMedia
import CoreVideo
import SwiftUI
import UIKit

@MainActor
public final class SimulatorCameraPreviewModel: ObservableObject, FrameSourceDelegate {
    @Published public private(set) var image: UIImage?
    @Published public private(set) var fps: Double = 0
    @Published public private(set) var state: FrameSourceState = .idle

    private var frameTimestamps: [CFTimeInterval] = []
    public let session: SimulatorCameraSession

    public init(session: SimulatorCameraSession = .init()) {
        self.session = session
        session.delegate = self
    }

    public func start() { session.start() }
    public func stop()  { session.stop() }

    nonisolated public func frameSource(_ source: FrameSource, didOutput pixelBuffer: CVPixelBuffer, at time: CMTime) {
        let ui = Self.uiImage(from: pixelBuffer)
        Task { @MainActor in
            self.image = ui
            let now = CACurrentMediaTime()
            self.frameTimestamps.append(now)
            self.frameTimestamps.removeAll { now - $0 > 1.0 }
            self.fps = Double(self.frameTimestamps.count)
        }
    }

    nonisolated public func frameSource(_ source: FrameSource, didChangeState state: FrameSourceState) {
        Task { @MainActor in self.state = state }
    }

    private static func uiImage(from pb: CVPixelBuffer) -> UIImage? {
        let ci = CIImage(cvPixelBuffer: pb)
        let ctx = CIContext()
        guard let cg = ctx.createCGImage(ci, from: ci.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}

public struct SimulatorCameraPreviewView: View {
    @StateObject private var model: SimulatorCameraPreviewModel

    public init(model: SimulatorCameraPreviewModel = .init()) {
        _model = StateObject(wrappedValue: model)
    }

    public var body: some View {
        ZStack {
            if let img = model.image {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFill()
            } else {
                Color.black
                ProgressView("Waiting for SimulatorCamera…")
                    .tint(.white)
                    .foregroundStyle(.white)
            }
        }
        .overlay(alignment: .topLeading) { badge }
        .overlay(alignment: .topTrailing) { fpsBadge }
        .onAppear { model.start() }
        .onDisappear { model.stop() }
    }

    private var badge: some View {
        let (txt, color): (String, Color) = {
            switch model.state {
            case .streaming:   return ("Streaming", .green)
            case .connecting:  return ("Connecting", .yellow)
            case .failed(let m): return ("Error: \(m)", .red)
            case .stopped:     return ("Stopped", .gray)
            case .idle:        return ("Idle", .gray)
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
