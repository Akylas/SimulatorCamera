// FrameStreamer.swift
// macOS Companion App — TCP server + frame encoding
// Streams JPEG-compressed frames over localhost using the SCMF protocol.

import Foundation
import Network
import CoreImage
import AppKit

/// Encodes a single SCMF frame message (header + JPEG payload).
enum SCMFEncoder {

    /// Magic bytes: "SCMF" = 0x53434D46
    static let magic: UInt32 = 0x53434D46

    /// Encode a CGImage into an SCMF message.
    /// - Parameters:
    ///   - image: The source frame.
    ///   - timestamp: Presentation timestamp in seconds.
    ///   - jpegQuality: 0.0–1.0 (default 0.8).
    /// - Returns: Raw bytes ready to send, or nil on failure.
    static func encode(
        image: CGImage,
        timestamp: Double,
        jpegQuality: CGFloat = 0.8
    ) -> Data? {
        // Convert CGImage → JPEG data via NSBitmapImageRep
        let rep = NSBitmapImageRep(cgImage: image)
        guard let jpegData = rep.representation(
            using: .jpeg,
            properties: [.compressionFactor: jpegQuality]
        ) else { return nil }

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
@MainActor
final class FrameStreamer: ObservableObject {

    @Published var isListening = false
    @Published var isClientConnected = false
    @Published var currentFPS: Double = 0
    @Published var framesSent: UInt64 = 0

    private var listener: NWListener?
    private var activeConnection: NWConnection?
    var port: UInt16

    // FPS tracking
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
            Task { @MainActor in
                switch state {
                case .ready:
                    self?.isListening = true
                    print("[FrameStreamer] Listening on port \(self?.port ?? 0)")
                case .failed(let error):
                    print("[FrameStreamer] Listener failed: \(error)")
                    self?.isListening = false
                default:
                    break
                }
            }
        }

        listener?.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in
                self?.handleNewConnection(connection)
            }
        }

        listener?.start(queue: .main)
    }

    func stopServer() {
        activeConnection?.cancel()
        activeConnection = nil
        listener?.cancel()
        listener = nil
        isListening = false
        isClientConnected = false
    }

    // MARK: - Connection handling

    private func handleNewConnection(_ connection: NWConnection) {
        // Only one client at a time
        activeConnection?.cancel()
        activeConnection = connection

        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                switch state {
                case .ready:
                    self?.isClientConnected = true
                    print("[FrameStreamer] Client connected")
                case .failed, .cancelled:
                    self?.isClientConnected = false
                    print("[FrameStreamer] Client disconnected")
                default:
                    break
                }
            }
        }

        connection.start(queue: .main)
    }

    // MARK: - Send frame

    /// Send a CGImage frame to the connected client.
    /// Call this from the video decoder at the desired frame rate.
    func sendFrame(image: CGImage, timestamp: Double) {
        guard let connection = activeConnection,
              connection.state == .ready,
              let data = SCMFEncoder.encode(image: image, timestamp: timestamp)
        else { return }

        connection.send(content: data, completion: .contentProcessed { error in
            if let error {
                print("[FrameStreamer] Send error: \(error)")
            }
        })

        framesSent += 1
        updateFPS()
    }

    // MARK: - FPS tracking

    private func updateFPS() {
        let now = CFAbsoluteTimeGetCurrent()
        fpsTimestamps.append(now)
        // Keep only timestamps from the last second
        fpsTimestamps = fpsTimestamps.filter { now - $0 < 1.0 }
        currentFPS = Double(fpsTimestamps.count)
    }
}
