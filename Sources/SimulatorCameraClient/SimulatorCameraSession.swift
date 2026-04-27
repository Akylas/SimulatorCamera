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

    public init(host: String = "127.0.0.1", port: UInt16 = 9876) {
        self.host = host
        self.port = port
    }

    public func start() {
        #if targetEnvironment(simulator)
        guard state == .idle || state == .stopped || (state != .failed("")) else { return }
        connect()
        #else
        log.info("SimulatorCameraSession.start(): on-device no-op")
        state = .stopped
        #endif
    }

    public func stop() {
        queue.async { [weak self] in
            self?.connection?.cancel()
            self?.connection = nil
        }
        state = .stopped
    }

    // MARK: Internals

    private let queue = DispatchQueue(label: "com.simulatorcamera.client.network")
    private let decoder = SCMFStreamDecoder()
    private var connection: NWConnection?
    private let log = Logger(subsystem: "com.simulatorcamera.client", category: "session")

    #if targetEnvironment(simulator)
    private func connect() {
        state = .connecting
        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port)!
        )
        let conn = NWConnection(to: endpoint, using: .tcp)
        connection = conn

        conn.stateUpdateHandler = { [weak self] newState in
            guard let self else { return }
            switch newState {
            case .ready:
                self.state = .streaming
                self.receiveLoop()
            case .failed(let err):
                self.state = .failed(err.localizedDescription)
                let e = err
                DispatchQueue.main.async {
                    self.delegate?.frameSource(self, didFailWith: e)
                }
            case .cancelled:
                if self.state != .stopped { self.state = .stopped }
            default:
                break
            }
        }
        conn.start(queue: queue)
    }

    private func receiveLoop() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.decoder.append(data)
                self.drainFrames()
            }
            if let error {
                self.state = .failed(error.localizedDescription)
                let e = error
                DispatchQueue.main.async {
                    self.delegate?.frameSource(self, didFailWith: e)
                }
                return
            }
            if isComplete {
                self.connection?.cancel()
                self.connection = nil
                self.state = .stopped
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
                let pixelBuffer = pb
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.delegate?.frameSource(self, didOutput: pixelBuffer, at: time)
                }
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
