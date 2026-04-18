//
//  SimulatorCameraRouter.swift
//  SimulatorCameraClient
//
//  Internal fan-out: owns a single SimulatorCameraSession and distributes
//  each decoded frame to any number of subscribed sinks (SimulatorCameraOutput,
//  SimulatorCameraPreviewView, or custom consumers).
//
//  Not part of the public API; `SimulatorCamera` (facade) and
//  `SimulatorCaptureSession` (shim) drive it.
//

import CoreMedia
import CoreVideo
import Foundation

typealias Sink = (CVPixelBuffer, CMTime) -> Void

final class _Router: FrameSourceDelegate, @unchecked Sendable {

    static let shared = _Router()

    // Configuration (read by session on start)
    var host: String = "127.0.0.1"
    var port: UInt16 = 9876

    private let lock = NSLock()
    private var sinks: [Int: Sink] = [:]
    private var nextToken: Int = 0
    private var session: SimulatorCameraSession?
    private var startCount: Int = 0

    /// Register a frame sink. Returns a token to pass back to `unsubscribe(_:)`.
    @discardableResult
    func subscribe(_ sink: @escaping Sink) -> Int {
        lock.lock()
        let token = nextToken
        nextToken += 1
        sinks[token] = sink
        lock.unlock()
        return token
    }

    func unsubscribe(_ token: Int) {
        lock.lock()
        sinks.removeValue(forKey: token)
        lock.unlock()
    }

    /// Increment the start refcount; boot the network session on the first caller.
    func start() {
        lock.lock()
        startCount += 1
        let shouldBoot = (startCount == 1)
        var sessionToStart: SimulatorCameraSession?
        if shouldBoot {
            let s = SimulatorCameraSession(host: host, port: port)
            s.delegate = self
            session = s
            sessionToStart = s
        }
        lock.unlock()

        sessionToStart?.start()  // outside the lock — start() itself does network I/O
    }

    /// Decrement the start refcount; tear down the session when it hits zero.
    func stop() {
        lock.lock()
        startCount = max(0, startCount - 1)
        let shouldTeardown = (startCount == 0)
        var sessionToStop: SimulatorCameraSession?
        if shouldTeardown {
            sessionToStop = session
            session = nil
        }
        lock.unlock()

        sessionToStop?.stop()
    }

    // MARK: FrameSourceDelegate

    func frameSource(_ source: FrameSource, didOutput pixelBuffer: CVPixelBuffer, at time: CMTime) {
        lock.lock()
        let snapshot = Array(sinks.values)
        lock.unlock()
        for sink in snapshot { sink(pixelBuffer, time) }
    }

    func frameSource(_ source: FrameSource, didChangeState state: FrameSourceState) {}
    func frameSource(_ source: FrameSource, didFailWith error: Error) {}
}
