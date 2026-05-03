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

final class AppLogger {
    private let subsystem: String
    private let category: String

    @available(iOS 14.0, *)
    private var logger: Logger {
        Logger(subsystem: subsystem, category: category)
    }

    init(subsystem: String, category: String) {
        self.subsystem = subsystem
        self.category = category
    }

    func debug(_ message: String) {
        if #available(iOS 14.0, *) {
            logger.debug("\(message, privacy: .public)")
        } else {
            os_log("%{public}@", log: OSLog(subsystem: subsystem, category: category), type: .debug, message)
        }
    }
    func info(_ message: String) {
        if #available(iOS 14.0, *) {
            logger.info("\(message, privacy: .public)")
        } else {
            os_log("%{public}@", log: OSLog(subsystem: subsystem, category: category), type: .info, message)
        }
    }

    func error(_ message: String) {
        if #available(iOS 14.0, *) {
            logger.error("\(message, privacy: .public)")
        } else {
            os_log("%{public}@", log: OSLog(subsystem: subsystem, category: category), type: .error, message)
        }
    }
}

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
    private var generation: Int = 0
    
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
            self.generation += 1
            let currentGen = self.generation
            self.explicitlyStopped = false
            self.connect(generation: currentGen)
        }
        #else
        log.info("SimulatorCameraSession.start(): on-device no-op")
        state = .stopped
        #endif
    }

    public func stop() {
        #if targetEnvironment(simulator)
        queue.sync { [weak self] in
            guard let self else { return }
            self.generation += 1   // invalidates all in-flight work
            self.explicitlyStopped = true
            self.cancelReconnect()
            self.cancelConnection()
            // Set state on queue — same thread that all other state mutations use.
            self.state = .stopped
        }
        #else
        state = .stopped
        #endif
    }

    // MARK: Internals

    private let queue = DispatchQueue(label: "com.simulatorcamera.client.network")
    private let decoder = SCMFStreamDecoder()
    private var connection: NWConnection?
    private let log = AppLogger(subsystem: "com.simulatorcamera.client", category: "session")

    // Reconnection state — accessed exclusively on `queue`.
    private var explicitlyStopped = false
    private var isReconnecting = false
    private var reconnectWorkItem: DispatchWorkItem?
    private var timeoutWorkItem: DispatchWorkItem?

    #if targetEnvironment(simulator)

    // MARK: - Connection lifecycle (runs on `queue`)

    private func connect(generation: Int) {
        // Cancel any previous connection first.
        cancelConnection()

        guard generation == self.generation else { return }
        
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
            guard generation == self.generation else { return }
            self.log.info("Connection timeout — scheduling reconnect")
            self.cancelConnection()
            self.scheduleReconnect(generation: generation)
        }
        timeoutWorkItem = timeout
        queue.asyncAfter(deadline: .now() + connectionTimeout, execute: timeout)

        conn.stateUpdateHandler = { [weak self] newState in
            guard let self else { return }
            guard generation == self.generation else { return }
            // All state handling runs on `queue` because that's what we pass
            // to conn.start(queue:) below.
            switch newState {
            case .ready:
                self.timeoutWorkItem?.cancel()
                self.timeoutWorkItem = nil
                self.isReconnecting = false
                self.state = .streaming
                self.receiveLoop(generation: generation)

            case .failed(let err):
                self.timeoutWorkItem?.cancel()
                self.timeoutWorkItem = nil
                self.log.info("Connection failed: \(err.localizedDescription) — scheduling reconnect")
                self.state = .failed(err.localizedDescription)
                self.scheduleReconnect(generation: generation)

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

    private func scheduleReconnect(generation: Int) {
        guard !explicitlyStopped, !isReconnecting else { return }
        guard generation == self.generation else { return }
        isReconnecting = true

        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.explicitlyStopped else { return }
            guard generation == self.generation else { return }
            self.connect(generation: generation)
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

    private func receiveLoop(generation: Int) {
        guard generation == self.generation else { return }
        
        // 256 KB is large enough to receive most frames (1280×720 JPEG ≈ 80–200 KB)
        // in a single read, eliminating extra round-trips through the receive loop.
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            guard generation == self.generation else { return } // 🔴 STOP EARLY
            
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
                self.scheduleReconnect(generation: generation)
                return
            }

            self.receiveLoop(generation: generation)
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
