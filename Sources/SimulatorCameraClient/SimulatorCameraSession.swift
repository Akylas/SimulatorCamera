//
//  SimulatorCameraSession.swift
//  SimulatorCameraClient
//
//  A FrameSource that connects to the SimulatorCamera Mac companion app
//  over TCP on localhost and emits CVPixelBuffer frames.
//
//  On real devices (`!targetEnvironment(simulator)`) the class exists but
//  `start()` is a no-op so you can leave it in your production build.
//
//  Reconnection behaviour
//  ----------------------
//  The session automatically reconnects whenever the server is unreachable or
//  the connection drops, making it resilient to the typical workflow of starting
//  the iOS Simulator before the Mac companion app is running:
//
//    • If the TCP connection fails to reach `.ready` within `connectionTimeout`
//      (default: 5 s), the attempt is cancelled and retried after `reconnectDelay`.
//    • If the server closes the connection or a receive error occurs, the session
//      schedules a reconnect after `reconnectDelay` (default: 2 s).
//    • All retries stop immediately when `stop()` is called.
//

import CoreMedia
import CoreVideo
import Foundation
import Network
import os.log

public final class SimulatorCameraSession: FrameSource, @unchecked Sendable {

    // MARK: Public API

    public weak var delegate: FrameSourceDelegate?
    public private(set) var state: FrameSourceState = .idle {
        didSet {
            let s = state
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.delegate?.frameSource(self, didChangeState: s)
            }
        }
    }

    public let host: String
    public let port: UInt16

    /// Time to wait for a TCP connection to reach `.ready` before giving up
    /// and retrying.  Default: 5 seconds.
    public var connectionTimeout: TimeInterval = 5

    /// Delay between reconnection attempts.  Default: 2 seconds.
    public var reconnectDelay: TimeInterval = 2

    public init(host: String = "127.0.0.1", port: UInt16 = 9876) {
        self.host = host
        self.port = port
    }

    public func start() {
        #if targetEnvironment(simulator)
        queue.async { [weak self] in
            guard let self else { return }
            // Allow (re)start from idle, stopped, or any failed state.
            switch self.state {
            case .connecting, .streaming: return  // already running
            default: break
            }
            self.explicitlyStopped = false
            self.connect()
        }
        #else
        log.info("SimulatorCameraSession.start(): on-device no-op")
        state = .stopped
        #endif
    }

    public func stop() {
        #if targetEnvironment(simulator)
        queue.async { [weak self] in
            guard let self else { return }
            self.explicitlyStopped = true
            self.cancelReconnect()
            self.cancelConnection()
        }
        #endif
        state = .stopped
    }

    // MARK: Internals

    private let queue = DispatchQueue(label: "com.simulatorcamera.client.network")
    private let decoder = SCMFStreamDecoder()
    private var connection: NWConnection?
    private let log = Logger(subsystem: "com.simulatorcamera.client", category: "session")

    // Reconnection state — accessed exclusively on `queue`.
    private var explicitlyStopped = false
    private var isReconnecting = false
    private var reconnectWorkItem: DispatchWorkItem?
    private var timeoutWorkItem: DispatchWorkItem?

    #if targetEnvironment(simulator)

    // MARK: - Connection lifecycle (runs on `queue`)

    private func connect() {
        // Cancel any previous connection first.
        cancelConnection()

        state = .connecting

        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port)!
        )
        let conn = NWConnection(to: endpoint, using: .tcp)
        connection = conn

        // Arm the connection-attempt timeout.
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, self.state == .connecting else { return }
            self.log.info("Connection timeout — scheduling reconnect")
            self.cancelConnection()
            self.scheduleReconnect()
        }
        timeoutWorkItem = timeout
        queue.asyncAfter(deadline: .now() + connectionTimeout, execute: timeout)

        conn.stateUpdateHandler = { [weak self] newState in
            guard let self else { return }
            // All state handling runs on `queue` because that's what we pass
            // to conn.start(queue:) below.
            switch newState {
            case .ready:
                self.timeoutWorkItem?.cancel()
                self.timeoutWorkItem = nil
                self.isReconnecting = false
                self.state = .streaming
                self.receiveLoop()

            case .failed(let err):
                self.timeoutWorkItem?.cancel()
                self.timeoutWorkItem = nil
                self.log.info("Connection failed: \(err.localizedDescription) — scheduling reconnect")
                self.state = .failed(err.localizedDescription)
                self.scheduleReconnect()

            case .cancelled:
                // Triggered both by explicit stop() AND by cancelConnection()
                // called as part of a reconnect cycle.  Only set .stopped if
                // the user asked us to stop.
                if self.explicitlyStopped {
                    self.state = .stopped
                }
                // Otherwise the reconnect is already scheduled — nothing to do.

            default:
                break
            }
        }

        conn.start(queue: queue)
    }

    private func cancelConnection() {
        timeoutWorkItem?.cancel()
        timeoutWorkItem = nil
        connection?.cancel()
        connection = nil
    }

    // MARK: - Reconnection

    private func scheduleReconnect() {
        guard !explicitlyStopped, !isReconnecting else { return }
        isReconnecting = true

        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.explicitlyStopped else { return }
            self.connect()
        }
        reconnectWorkItem = work
        log.info("Reconnecting in \(self.reconnectDelay) s…")
        queue.asyncAfter(deadline: .now() + reconnectDelay, execute: work)
    }

    private func cancelReconnect() {
        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil
        isReconnecting = false
    }

    // MARK: - Receive loop

    private func receiveLoop() {
        // 256 KB is large enough to receive most frames (1280×720 JPEG ≈ 80–200 KB)
        // in a single read, eliminating extra round-trips through the receive loop.
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }

            if let data, !data.isEmpty {
                self.decoder.append(data)
                self.drainFrames()
            }

            if let error {
                self.log.error("Receive error: \(error.localizedDescription) — scheduling reconnect")
                self.state = .failed(error.localizedDescription)
                // The NW framework will also emit .failed on the connection —
                // scheduleReconnect() is called there; nothing more to do here.
                return
            }

            if isComplete {
                // Server closed the connection — reconnect unless stopped.
                self.log.info("Server closed connection — scheduling reconnect")
                self.cancelConnection()
                self.scheduleReconnect()
                return
            }

            self.receiveLoop()
        }
    }

    private func drainFrames() {
        do {
            while let frame = try decoder.nextFrame() {
                let pb = try SCMFCodec.pixelBuffer(
                    from: frame.jpegData,
                    width: frame.width,
                    height: frame.height
                )
                let time = CMTime(seconds: frame.timestamp, preferredTimescale: 1_000_000)
                // Deliver directly on the network queue — no main-thread hop.
                // Downstream sinks (SimulatorCameraOutput.deliver) dispatch to
                // their own registered callback queues, keeping the main queue free.
                delegate?.frameSource(self, didOutput: pb, at: time)
            }
        } catch {
            log.error("decode error: \(String(describing: error))")
            let e = error
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.delegate?.frameSource(self, didFailWith: e)
            }
        }
    }
    #endif
}
