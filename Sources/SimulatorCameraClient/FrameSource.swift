//
//  FrameSource.swift
//  SimulatorCameraClient
//
//  AVCaptureSession-shaped API so your app doesn't care whether frames
//  come from a real camera on device or from SimulatorCamera in the Simulator.
//

import CoreMedia
import CoreVideo
import Foundation

/// Receives decoded frames from a `FrameSource`.
public protocol FrameSourceDelegate: AnyObject {
    func frameSource(_ source: FrameSource, didOutput pixelBuffer: CVPixelBuffer, at time: CMTime)
    func frameSource(_ source: FrameSource, didChangeState state: FrameSourceState)
    func frameSource(_ source: FrameSource, didFailWith error: Error)
}

public extension FrameSourceDelegate {
    func frameSource(_ source: FrameSource, didChangeState state: FrameSourceState) {}
    func frameSource(_ source: FrameSource, didFailWith error: Error) {}
}

/// Lifecycle state of a `FrameSource`.
public enum FrameSourceState: Equatable {
    case idle
    case connecting
    case streaming
    case stopped
    case failed(String)
}

/// Anything that can produce `CVPixelBuffer` frames over time.
public protocol FrameSource: AnyObject {
    var delegate: FrameSourceDelegate? { get set }
    var state: FrameSourceState { get }
    func start()
    func stop()
}
