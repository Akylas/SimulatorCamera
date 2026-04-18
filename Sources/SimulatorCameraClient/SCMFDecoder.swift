//
//  SCMFDecoder.swift
//  SimulatorCameraClient
//
//  Decodes the wire format:
//
//    +--------+---------------+------------------+--------+---------+----------+
//    | magic  | payloadLength | timestamp        | width  | height  | jpegData |
//    | 4 B    | 4 B LE        | 8 B Float64 LE   | 4 B LE | 4 B LE  | N bytes  |
//    +--------+---------------+------------------+--------+---------+----------+
//
//  All multi-byte integers are little-endian. `payloadLength` counts
//  (timestamp + width + height + jpegData) = 16 + jpegData.count.
//

import CoreVideo
import Foundation
import ImageIO

public struct SCMFFrame {
    public let timestamp: Double
    public let width: Int
    public let height: Int
    public let jpegData: Data
}

public enum SCMFError: Error, CustomStringConvertible {
    case invalidMagic
    case truncated
    case jpegDecodeFailed
    case pixelBufferCreateFailed

    public var description: String {
        switch self {
        case .invalidMagic: return "SCMF: invalid magic number"
        case .truncated: return "SCMF: truncated frame"
        case .jpegDecodeFailed: return "SCMF: JPEG decode failed"
        case .pixelBufferCreateFailed: return "SCMF: CVPixelBuffer creation failed"
        }
    }
}

/// Stream-oriented SCMF decoder. Feed it bytes with `append(_:)` and drain
/// complete frames with `nextFrame()`.
public final class SCMFStreamDecoder {

    public static let magic: UInt32 = 0x53434D46 // "SCMF"
    private static let headerSize = 8            // magic + payloadLength
    private static let payloadMetaSize = 16      // timestamp + width + height

    private var buffer = Data()

    public init() {}

    public func append(_ data: Data) {
        buffer.append(data)
    }

    public func nextFrame() throws -> SCMFFrame? {
        guard buffer.count >= Self.headerSize else { return nil }

        let (magic, payloadLen) = buffer.withUnsafeBytes { raw -> (UInt32, UInt32) in
            let m = raw.loadUnaligned(fromByteOffset: 0, as: UInt32.self).littleEndian
            let l = raw.loadUnaligned(fromByteOffset: 4, as: UInt32.self).littleEndian
            return (m, l)
        }
        guard magic == Self.magic else { throw SCMFError.invalidMagic }

        let totalFrameSize = Self.headerSize + Int(payloadLen)
        guard buffer.count >= totalFrameSize else { return nil }
        guard payloadLen >= UInt32(Self.payloadMetaSize) else { throw SCMFError.truncated }

        let base = buffer.startIndex
        let tsOffset = Self.headerSize
        let wOffset = tsOffset + 8
        let hOffset = wOffset + 4
        let jpegStart = hOffset + 4
        let jpegLength = Int(payloadLen) - Self.payloadMetaSize

        let (tsBits, width, height) = buffer.withUnsafeBytes { raw -> (UInt64, UInt32, UInt32) in
            let t = raw.loadUnaligned(fromByteOffset: tsOffset, as: UInt64.self).littleEndian
            let w = raw.loadUnaligned(fromByteOffset: wOffset, as: UInt32.self).littleEndian
            let h = raw.loadUnaligned(fromByteOffset: hOffset, as: UInt32.self).littleEndian
            return (t, w, h)
        }

        let timestamp = Double(bitPattern: tsBits)
        let jpegData = buffer.subdata(in: (base + jpegStart)..<(base + jpegStart + jpegLength))
        buffer.removeFirst(totalFrameSize)

        return SCMFFrame(
            timestamp: timestamp,
            width: Int(width),
            height: Int(height),
            jpegData: jpegData
        )
    }
}

/// One-shot helpers to pack / unpack SCMF frames (useful for tests).
public enum SCMFCodec {

    public static func encode(_ frame: SCMFFrame) -> Data {
        var out = Data()
        out.reserveCapacity(8 + 16 + frame.jpegData.count)

        var magic = SCMFStreamDecoder.magic.littleEndian
        var payloadLen = UInt32(16 + frame.jpegData.count).littleEndian
        var ts = frame.timestamp.bitPattern.littleEndian
        var w = UInt32(frame.width).littleEndian
        var h = UInt32(frame.height).littleEndian

        withUnsafeBytes(of: &magic) { out.append(contentsOf: $0) }
        withUnsafeBytes(of: &payloadLen) { out.append(contentsOf: $0) }
        withUnsafeBytes(of: &ts) { out.append(contentsOf: $0) }
        withUnsafeBytes(of: &w) { out.append(contentsOf: $0) }
        withUnsafeBytes(of: &h) { out.append(contentsOf: $0) }
        out.append(frame.jpegData)
        return out
    }

    /// Decode a JPEG payload into a `CVPixelBuffer` (32BGRA).
    public static func pixelBuffer(from jpeg: Data, width: Int, height: Int) throws -> CVPixelBuffer {
        guard let src = CGImageSourceCreateWithData(jpeg as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(src, 0, nil)
        else {
            throw SCMFError.jpegDecodeFailed
        }

        var pb: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as [CFString: Any]
        ]
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width, height,
            kCVPixelFormatType_32BGRA,
            attrs as CFDictionary,
            &pb
        )
        guard status == kCVReturnSuccess, let pixelBuffer = pb else {
            throw SCMFError.pixelBufferCreateFailed
        }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        guard let ctx = CGContext(
            data: CVPixelBufferGetBaseAddress(pixelBuffer),
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
        ) else {
            throw SCMFError.pixelBufferCreateFailed
        }
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        return pixelBuffer
    }
}
