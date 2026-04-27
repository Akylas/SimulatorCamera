// FrameStreamer.swift
// macOS Companion App — TCP server + frame encoding
// Streams JPEG-compressed frames over localhost using the SCMF protocol.

import Foundation
import Network
import CoreImage
import AppKit
import UniformTypeIdentifiers

/// Encodes a single SCMF frame message (header + JPEG payload).
enum SCMFEncoder {

    /// Magic bytes: "SCMF" = 0x53434D46
    static let magic: UInt32 = 0x53434D46

    /// Encode a CGImage into an SCMF message using CGImageDestination
    /// (hardware-accelerated on Apple Silicon, faster than NSBitmapImageRep).
    /// - Parameters:
    ///   - image: The source frame.
    ///   - timestamp: Presentation timestamp in seconds.
    ///   - jpegQuality: 0.0–1.0 (default 0.7).
    /// - Returns: Raw bytes ready to send, or nil on failure.
    static func encode(
        image: CGImage,
        timestamp: Double,
        jpegQuality: CGFloat = 0.7
    ) -> Data? {
        // Encode to JPEG via CGImageDestination (hardware-accelerated via Image I/O).
        let jpegMutable = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            jpegMutable,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else { return nil }
        let destOptions: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: jpegQuality
        ]
        CGImageDestinationAddImage(dest, image, destOptions as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        let jpegData = jpegMutable as Data

        let width  = UInt32(image.width)
        let height = UInt32(image.height)
        // payloadLength = 8 (timestamp) + 4 (width) + 4 (height) + jpegData.count
        let payloadLength = UInt32(16 + jpegData.count)

        var message = Data(capacity: 24 + jpegData.count)

        // Header
        var m = magic.littleEndian;            message.append(Data(bytes: &m, count: 4))
        var p = payloadLength.littleEndian;     message.append(Data(bytes: &p, count: 4))

        // Payload header
        var t = timestamp.bitPattern.littleEndian; message.append(Data(bytes: &t, count: 8))
        var w = width.littleEndian;             message.append(Data(bytes: &w, count: 4))
        var h = height.littleEndian;            message.append(Data(bytes: &h, count: 4))

        // JPEG bytes
        message.append(jpegData)

        return message
    }
}


// MARK: - TCP Server

/// A simple TCP server that accepts one client at a time and streams SCMF frames.
///
/// Threading model
/// ---------------
///   networkQueue  (serial, userInitiated)
///     • NWListener and NWConnection callbacks run here.
///     • `activeConnection` is read/written only on this queue.
///
///   encodeQueue   (serial, userInitiated)
///     • JPEG encoding + NW send happen here so the main thread is never
///       blocked by CPU-heavy frame encoding (~2–5 ms per frame at 720 p).
///
///   Main queue / @Published
///     • All @Published mutations dispatch to the main queue so SwiftUI
///       observes them correctly.
final class FrameStreamer: ObservableObject, @unchecked Sendable {

    @Published var isListening = false
    @Published var isClientConnected = false
    @Published var currentFPS: Double = 0
    @Published var framesSent: UInt64 = 0

    private var listener: NWListener?

    // `_activeConnection` is protected by `connectionLock` so it can be
    // safely read from `encodeQueue` and written from `networkQueue`.
    private let connectionLock = NSLock()
    private var _activeConnection: NWConnection?
    private var activeConnection: NWConnection? {
        get { connectionLock.withLock { _activeConnection } }
        set { connectionLock.withLock { _activeConnection = newValue } }
    }

    var port: UInt16

    // Dedicated queues — keep NW I/O and JPEG encoding off the main thread.
    private let networkQueue = DispatchQueue(
        label: "com.simulatorcamera.server.network",
        qos: .userInitiated
    )
    private let encodeQueue = DispatchQueue(
        label: "com.simulatorcamera.server.encode",
        qos: .userInitiated
    )

    // FPS tracking — accessed only on encodeQueue.
    private var fpsTimestamps: [CFAbsoluteTime] = []

    init(port: UInt16 = 9876) {
        self.port = port
    }

    // MARK: - Start / Stop

    func startServer() {
        guard listener == nil else { return }

        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true

        do {
            listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
        } catch {
            print("[FrameStreamer] Failed to create listener: \(error)")
            return
        }

        listener?.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                DispatchQueue.main.async { self.isListening = true }
                print("[FrameStreamer] Listening on port \(self.port)")
            case .failed(let error):
                print("[FrameStreamer] Listener failed: \(error)")
                DispatchQueue.main.async { self.isListening = false }
            default:
                break
            }
        }

        listener?.newConnectionHandler = { [weak self] connection in
            self?.handleNewConnection(connection)
        }

        // NW callbacks run on networkQueue, keeping them off the main thread.
        listener?.start(queue: networkQueue)
    }

    func stopServer() {
        networkQueue.async { [weak self] in
            guard let self else { return }
            self.activeConnection?.cancel()
            self.activeConnection = nil
        }
        listener?.cancel()
        listener = nil
        DispatchQueue.main.async { [weak self] in
            self?.isListening = false
            self?.isClientConnected = false
        }
    }

    // MARK: - Connection handling (runs on networkQueue)

    private func handleNewConnection(_ connection: NWConnection) {
        // Only one client at a time — cancel any previous connection.
        activeConnection?.cancel()
        activeConnection = connection

        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                DispatchQueue.main.async { self.isClientConnected = true }
                print("[FrameStreamer] Client connected")
            case .failed, .cancelled:
                DispatchQueue.main.async { self.isClientConnected = false }
                print("[FrameStreamer] Client disconnected")
            default:
                break
            }
        }

        connection.start(queue: networkQueue)
    }

    // MARK: - Send frame
    //
    // Can be called from any thread (including background frame-delivery queues).
    // JPEG encoding and NW send are dispatched to encodeQueue so callers
    // are never blocked by the encoding work.

    func sendFrame(image: CGImage, timestamp: Double) {
        // Dispatch encoding to encodeQueue; capture a strong reference to the
        // connection under the lock so we don't hold the lock during encode.
        encodeQueue.async { [weak self] in
            guard let self else { return }

            // activeConnection is protected by connectionLock — safe to read here.
            guard let connection = self.activeConnection,
                  connection.state == .ready,
                  let data = SCMFEncoder.encode(image: image, timestamp: timestamp)
            else { return }

            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    print("[FrameStreamer] Send error: \(error)")
                }
            })

            self.recordFrameSent()
        }
    }

    // MARK: - Stats (runs on encodeQueue)

    private func recordFrameSent() {
        let now = CFAbsoluteTimeGetCurrent()
        fpsTimestamps.append(now)
        fpsTimestamps.removeAll { now - $0 >= 1.0 }
        let fps = Double(fpsTimestamps.count)

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.framesSent += 1
            self.currentFPS = fps
        }
    }
}
