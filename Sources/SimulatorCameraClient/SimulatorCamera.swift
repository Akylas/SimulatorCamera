//
//  SimulatorCamera.swift
//  SimulatorCameraClient
//
//  Top-level facade. Call `SimulatorCamera.configure(host:port:)` once
//  (typically in your app delegate) and the shim types — SimulatorCaptureSession,
//  SimulatorCameraOutput, SimulatorCameraPreviewView — will stream frames
//  from the Mac companion app.
//
//  On real devices every method is a no-op so you can leave this code in
//  your production build unguarded.
//

import Foundation

public enum SimulatorCamera {

    /// Point the shim at a specific host/port. Defaults: 127.0.0.1:9876.
    /// Safe to call before or after `start()`; takes effect on the next start.
    public static func configure(host: String = "127.0.0.1", port: UInt16 = 9876) {
        _Router.shared.host = host
        _Router.shared.port = port
    }

    /// Begin streaming. Ref-counted against `stop()` — every `start()` must
    /// be balanced by a `stop()` for the connection to tear down.
    public static func start() {
        #if targetEnvironment(simulator)
        _Router.shared.start()
        #endif
    }

    public static func stop() {
        #if targetEnvironment(simulator)
        _Router.shared.stop()
        #endif
    }

    /// Convenience: whether we're in a context where the shim actually does anything.
    public static var isActive: Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        return false
        #endif
    }
}
