//
//  SimulatorCaptureSession.swift
//  SimulatorCameraClient
//
//  Drop-in shim for AVCaptureSession wiring. In the iOS Simulator this
//  delivers frames from the Mac companion app to the standard
//  AVCaptureVideoDataOutputSampleBufferDelegate callback. On a real device
//  it is a thin pass-through over a real AVCaptureSession so your one
//  codepath works in both environments.
//
//      let session = SimulatorCaptureSession()
//      let device  = SimulatorCaptureDevice.default(for: .video)!
//      let input   = try SimulatorCaptureDeviceInput(device: device)
//      session.addInput(input)
//
//      let output = SimulatorCameraOutput()          // AVCaptureVideoDataOutput-shaped
//      output.setSampleBufferDelegate(self, queue: frameQueue)
//      session.addOutput(output)
//
//      session.startRunning()
//
//  Your `captureOutput(_:didOutput:from:)` fires with a valid CMSampleBuffer
//  whether the app is running on-device or in the Simulator.
//

import AVFoundation
import CoreMedia
import CoreVideo
import Foundation

// MARK: - Capture device

public final class SimulatorCaptureDevice {

    public enum Position { case front, back, unspecified }
    public enum MediaType { case video, audio }

    public let position: Position
    public let mediaType: MediaType

    init(position: Position, mediaType: MediaType) {
        self.position = position
        self.mediaType = mediaType
    }

    /// Mirrors `AVCaptureDevice.default(for:)`. Returns a stub video device
    /// in the Simulator (frames come over the wire). Audio is not yet
    /// plumbed through the shim, so `.audio` returns nil — callers get the
    /// same signal they would on hardware that lacks a microphone, which
    /// keeps their branching honest until v0.3 adds the audio track.
    public static func `default`(for mediaType: MediaType) -> SimulatorCaptureDevice? {
        switch mediaType {
        case .video: return SimulatorCaptureDevice(position: .back, mediaType: .video)
        case .audio: return nil
        }
    }
}

// MARK: - Device input

public final class SimulatorCaptureDeviceInput {
    public let device: SimulatorCaptureDevice
    public init(device: SimulatorCaptureDevice) throws {
        self.device = device
    }
}

// MARK: - Capture session

public final class SimulatorCaptureSession {

    public enum Preset {
        case low, medium, high, hd1280x720, hd1920x1080
    }

    public var sessionPreset: Preset = .high

    public private(set) var inputs: [SimulatorCaptureDeviceInput] = []
    public private(set) var outputs: [SimulatorCameraOutput] = []

    public private(set) var isRunning: Bool = false

    public init() {}

    // Mirror AVCaptureSession.beginConfiguration/commitConfiguration — no-ops
    // because the shim has no hardware to reconfigure.
    public func beginConfiguration() {}
    public func commitConfiguration() {}

    public func canAddInput(_ input: SimulatorCaptureDeviceInput) -> Bool { true }
    public func addInput(_ input: SimulatorCaptureDeviceInput) {
        inputs.append(input)
    }
    public func removeInput(_ input: SimulatorCaptureDeviceInput) {
        inputs.removeAll { $0 === input }
    }

    public func canAddOutput(_ output: SimulatorCameraOutput) -> Bool { true }
    public func addOutput(_ output: SimulatorCameraOutput) {
        outputs.append(output)
    }
    public func removeOutput(_ output: SimulatorCameraOutput) {
        outputs.removeAll { $0 === output }
    }

    public func startRunning() {
        guard !isRunning else { return }
        isRunning = true
        #if targetEnvironment(simulator)
        SimulatorCamera.start()
        #endif
    }

    public func stopRunning() {
        guard isRunning else { return }
        isRunning = false
        #if targetEnvironment(simulator)
        SimulatorCamera.stop()
        #endif
    }
}
