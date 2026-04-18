import XCTest
@testable import SimulatorCameraClient

final class SCMFCodecTests: XCTestCase {

    func testRoundTrip() throws {
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xD9]) // not a real JPEG; codec just carries bytes
        let frame = SCMFFrame(timestamp: 1.234, width: 640, height: 480, jpegData: jpeg)
        let packed = SCMFCodec.encode(frame)

        let decoder = SCMFStreamDecoder()
        decoder.append(packed)
        let got = try XCTUnwrap(try decoder.nextFrame())

        XCTAssertEqual(got.timestamp, 1.234, accuracy: 1e-9)
        XCTAssertEqual(got.width, 640)
        XCTAssertEqual(got.height, 480)
        XCTAssertEqual(got.jpegData, jpeg)
    }

    func testPartialAppendDoesNotReturnFrame() throws {
        let frame = SCMFFrame(timestamp: 0, width: 1, height: 1, jpegData: Data(repeating: 0, count: 32))
        let packed = SCMFCodec.encode(frame)
        let decoder = SCMFStreamDecoder()
        decoder.append(packed.prefix(10))
        XCTAssertNil(try decoder.nextFrame())
        decoder.append(packed.suffix(from: 10))
        XCTAssertNotNil(try decoder.nextFrame())
    }

    func testInvalidMagicThrows() {
        var bogus = Data([0x00, 0x00, 0x00, 0x00]) // wrong magic
        bogus.append(Data(repeating: 0, count: 20))
        let decoder = SCMFStreamDecoder()
        decoder.append(bogus)
        XCTAssertThrowsError(try decoder.nextFrame()) { err in
            XCTAssertTrue(err is SCMFError)
        }
    }

    func testTwoFramesInOneBuffer() throws {
        let jpeg = Data(repeating: 0xAB, count: 10)
        let f1 = SCMFFrame(timestamp: 1, width: 2, height: 2, jpegData: jpeg)
        let f2 = SCMFFrame(timestamp: 2, width: 4, height: 4, jpegData: jpeg)
        var buf = SCMFCodec.encode(f1)
        buf.append(SCMFCodec.encode(f2))

        let decoder = SCMFStreamDecoder()
        decoder.append(buf)
        XCTAssertEqual(try decoder.nextFrame()?.width, 2)
        XCTAssertEqual(try decoder.nextFrame()?.width, 4)
        XCTAssertNil(try decoder.nextFrame())
    }
}
