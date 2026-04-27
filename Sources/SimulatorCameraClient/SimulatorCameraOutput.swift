//
//  SimulatorCameraOutput.swift
//  SimulatorCameraClient
//
//  Drop-in replacement for `AVCaptureVideoDataOutput`. Your existing
//  `AVCaptureVideoDataOutputSampleBufferDelegate` code works unchanged:
//
//      #if targetEnvironment(simulator)
//      let out = SimulatorCameraOutput()
//      out.setSampleBufferDelegate(myDelegate, queue: myQueue)
//      SimulatorCamera.start()
//      #else
//      let out = AVCaptureVideoDataOutput()
//      out.setSampleBufferDelegate(myDelegate, queue: myQueue)
//      session.addOutput(out)
//      #endif
//
//  Same selector signature, same `CMSampleBuffer`, no branching inside the
//  delegate. `SimulatorCameraOutput` is an `AVCaptureVideoDataOutput`
//  subclass, so the first argument of `captureOutput(_:didOutput:from:)` is
//  a genuine AV output object — no synthesized stand-ins. The
//  `AVCaptureConnection` passed to the delegate is an unattached placeholder
//  cached on this instance; delegates that only read `sampleBuffer` work
//  unchanged, delegates that inspect connection orientation will need a
//  simulator-side fallback.
//

import AVFoundation
import CoreMedia
import CoreVideo
import Foundation

/// Analogue of `AVCaptureVideoDataOutput` that receives frames from the
/// SimulatorCamera companion app and invokes the standard
/// `AVCaptureVideoDataOutputSampleBufferDelegate` methods.
///
/// Implemented as a subclass so `self` can be passed as-is to the delegate
/// — we don't allocate a throwaway `AVCaptureVideoDataOutput` per frame.
public final class SimulatorCameraOutput: AVCaptureVideoDataOutput {

    // Shadowed storage (the AV base class keeps its own pair, but we don't
    // invoke any AV machinery so we manage these independently).
    // Protected by `shimLock` so `deliver` — called from the network queue
    // after drainFrames removed the main-thread hop — can safely read them.
    private let shimLock = NSLock()
    private weak var _shimDelegate: AVCaptureVideoDataOutputSampleBufferDelegate?
    private var _shimQueue: DispatchQueue?

    /// Router subscription token; released in `deinit`.
    fileprivate var routerToken: Int?

    /// Cached, unattached connection reused for every delivered frame.
    /// Delegates that only read `sampleBuffer` ignore it; delegates that
    /// inspect orientation/rotation get a stable object instead of a
    /// per-frame allocation.
    private lazy var shimConnection: AVCaptureConnection =
        AVCaptureConnection(inputPorts: [], output: self)

    public override init() {
        super.init()
        _Router.shared.subscribeOutput(self)
    }

    deinit {
        _Router.shared.unsubscribeOutput(self)
    }

    /// Same signature as `AVCaptureVideoDataOutput.setSampleBufferDelegate(_:queue:)`.
    /// Intentionally overrides the base class so the delegate we invoke is
    /// the one stored here (not the one AV would hold for a real capture
    /// pipeline that never runs in the Simulator).
    public override func setSampleBufferDelegate(
        _ sampleBufferDelegate: AVCaptureVideoDataOutputSampleBufferDelegate?,
        queue sampleBufferCallbackQueue: DispatchQueue?
    ) {
        shimLock.withLock {
            self._shimDelegate = sampleBufferDelegate
            self._shimQueue = sampleBufferCallbackQueue
        }
        super.setSampleBufferDelegate(sampleBufferDelegate, queue: sampleBufferCallbackQueue)
    }

    /// Called by the router to hand a frame to the delegate as a
    /// `CMSampleBuffer` on the registered callback queue.
    /// Safe to call from any queue (protected by `shimLock`).
    func deliver(_ pixelBuffer: CVPixelBuffer, at time: CMTime) {
        let (delegate, queue) = shimLock.withLock { (_shimDelegate, _shimQueue) }
        guard let delegate, let queue else { return }

        queue.async { [weak self] in
            guard let self else { return }
            guard let sample = Self.makeSampleBuffer(pixelBuffer: pixelBuffer, time: time) else { return }
            // `self` is a real AVCaptureVideoDataOutput subclass; pass it
            // directly and pass nil for the connection — the most common
            // delegate pattern (reading `sampleBuffer` and ignoring
            // `connection`) works unchanged, and delegates that DO inspect
            // the connection can feature-detect nil.
            delegate.captureOutput?(
                self,
                didOutput: sample,
                from: self.shimConnection
            )
        }
    }

    private static func makeSampleBuffer(pixelBuffer: CVPixelBuffer, time: CMTime) -> CMSampleBuffer? {
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
        let status = CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: fd,
            sampleTiming: &timing,
            sampleBufferOut: &sample
        )
        guard status == noErr else { return nil }
        return sample
    }
}

// MARK: - Router hook-up

extension _Router {
    func subscribeOutput(_ output: SimulatorCameraOutput) {
        let sink: Sink = { [weak output] pb, t in
            output?.deliver(pb, at: t)
        }
        output.routerToken = subscribe(sink)
    }

    func unsubscribeOutput(_ output: SimulatorCameraOutput) {
        if let token = output.routerToken {
            unsubscribe(token)
            output.routerToken = nil
        }
    }
}
