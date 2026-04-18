//
//  ShimTests.swift
//  SimulatorCameraClientTests
//
//  Thin coverage of the v0.2.0 AVCaptureSession drop-in shim and the
//  internal router. These are structural tests — they don't exercise the
//  network path (that requires the Mac companion app).
//

import XCTest
import AVFoundation
import CoreMedia
import CoreVideo
@testable import SimulatorCameraClient

final class ShimTests: XCTestCase {

    // MARK: SimulatorCaptureDevice

    func test_defaultDevice_returnsVideoStub() {
        let device = SimulatorCaptureDevice.default(for: .video)
        XCTAssertNotNil(device, "video should resolve to a stub in the shim")
        XCTAssertEqual(device?.mediaType, .video)
    }

    func test_defaultDevice_returnsNilForAudio() {
        // Audio is not plumbed through the shim until v0.3; promise the
        // same "no device" signal AVFoundation would give on hardware
        // without a mic.
        XCTAssertNil(SimulatorCaptureDevice.default(for: .audio),
                     "audio should NOT resolve — the shim has no audio track yet")
    }

    // MARK: SimulatorCaptureSession

    func test_session_addInputAddOutput_tracksCorrectly() throws {
        let session = SimulatorCaptureSession()
        let device = try XCTUnwrap(SimulatorCaptureDevice.default(for: .video))
        let input  = try SimulatorCaptureDeviceInput(device: device)
        let output = SimulatorCameraOutput()

        session.addInput(input)
        session.addOutput(output)

        XCTAssertEqual(session.inputs.count,  1)
        XCTAssertEqual(session.outputs.count, 1)
        XCTAssertFalse(session.isRunning)
    }

    func test_session_startStop_togglesFlag() throws {
        let session = SimulatorCaptureSession()
        session.startRunning()
        XCTAssertTrue(session.isRunning)
        session.stopRunning()
        XCTAssertFalse(session.isRunning)
    }

    // MARK: SimulatorCameraOutput

    func test_output_isAVCaptureVideoDataOutputSubclass() {
        // The whole point: `self` on the delegate callback has to be a
        // real AVCaptureVideoDataOutput so consumer code that checks the
        // type or reads properties doesn't blow up.
        let output = SimulatorCameraOutput()
        XCTAssertTrue(output is AVCaptureVideoDataOutput)
    }

    func test_output_deliversFrame_toDelegate() throws {
        let output = SimulatorCameraOutput()
        let expect = expectation(description: "delegate called")
        let stub = DelegateStub { _, sample, _ in
            XCTAssertNotNil(CMSampleBufferGetImageBuffer(sample))
            expect.fulfill()
        }
        output.setSampleBufferDelegate(stub, queue: .main)

        let pb = try Self.makePixelBuffer(width: 16, height: 16)
        output.deliver(pb, at: CMTime(seconds: 0, preferredTimescale: 1_000))

        wait(for: [expect], timeout: 1.0)
    }

    // MARK: _Router

    func test_router_subscribeReceivesAndUnsubscribeStops() throws {
        let router = _Router.shared
        var received = 0
        let token = router.subscribe { _, _ in received += 1 }

        let pb = try Self.makePixelBuffer(width: 8, height: 8)
        // Drive the router directly as though it were the SimulatorCameraSession.
        router.frameSource(DummySource(), didOutput: pb, at: .zero)
        XCTAssertEqual(received, 1)

        router.unsubscribe(token)
        router.frameSource(DummySource(), didOutput: pb, at: .zero)
        XCTAssertEqual(received, 1, "unsubscribed sink must not receive further frames")
    }

    // MARK: Helpers

    private static func makePixelBuffer(width: Int, height: Int) throws -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        let attrs: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [:]]
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, width, height,
            kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pb
        )
        guard status == kCVReturnSuccess, let buf = pb else {
            throw NSError(domain: "ShimTests", code: Int(status))
        }
        return buf
    }
}

// MARK: Test doubles

private final class DelegateStub: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let onFrame: (AVCaptureOutput, CMSampleBuffer, AVCaptureConnection) -> Void
    init(onFrame: @escaping (AVCaptureOutput, CMSampleBuffer, AVCaptureConnection) -> Void) {
        self.onFrame = onFrame
    }
    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        onFrame(output, sampleBuffer, connection)
    }
}

private final class DummySource: FrameSource {
    var delegate: FrameSourceDelegate?
    var state: FrameSourceState = .streaming
    func start() {}
    func stop()  {}
}
