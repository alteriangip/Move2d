import XCTest
@testable import M2DCore

final class CodecTests: XCTestCase {
    func testDeflateRoundTrip() throws {
        var rng = SystemRandomNumberGenerator()
        let inputs: [[UInt8]] = [
            [],
            Array("hello hello hello hello world".utf8),
            [UInt8](repeating: 7, count: 100_000),
            (0..<50_000).map { _ in UInt8.random(in: 0...255, using: &rng) },
            (0..<70_000).map { UInt8($0 % 13) },
        ]
        for input in inputs {
            let z = Deflate.zlib(input)
            XCTAssertEqual(try Inflate.zlib(z), input)
        }
        // Compression actually happens for repetitive data.
        XCTAssertLessThan(Deflate.zlib([UInt8](repeating: 7, count: 100_000)).count, 2_000)
    }

    func testInflateKnownZlibStream() throws {
        // zlib.compress(b"Move2D") produced by CPython (dynamic/fixed block from real zlib).
        let z: [UInt8] = [0x78, 0x9c, 0xf3, 0xcd, 0x2f, 0x4b, 0x35, 0x72, 0x01, 0x00, 0x07, 0xae, 0x02, 0x0e]
        XCTAssertEqual(String(decoding: try Inflate.zlib(z), as: UTF8.self), "Move2D")
    }

    func testPNGRoundTrip() throws {
        var img = RGBAImage(width: 37, height: 23)
        for y in 0..<23 { for x in 0..<37 {
            let i = (y * 37 + x) * 4
            img.pixels[i] = UInt8(x * 6); img.pixels[i + 1] = UInt8(y * 11); img.pixels[i + 2] = UInt8((x * y) % 256)
            img.pixels[i + 3] = UInt8((x + y) * 4 % 256)
        }}
        let decoded = try PNG.decode(PNG.encode(img))
        XCTAssertEqual(decoded, img)
    }

    func testCRC() {
        XCTAssertEqual(CRC32.checksum(Array("123456789".utf8)), 0xCBF4_3926)
        XCTAssertEqual(Adler32.checksum(Array("Wikipedia".utf8)), 0x11E6_0398)
    }

    func testAffineInverse() {
        let m = Affine2D.translation(Vec2(10, -4)).concatenating(.rotation(0.7)).concatenating(.scale(2.5))
        let p = Vec2(3, 9)
        let q = m.inverted.apply(m.apply(p))
        XCTAssertEqual(q.x, p.x, accuracy: 1e-4); XCTAssertEqual(q.y, p.y, accuracy: 1e-4)
    }

    func testPremultiplyRoundTrip() {
        let img = RGBAImage(width: 1, height: 1, pixels: [200, 100, 50, 128])
        let back = img.toPremultiplied().toStraight()
        XCTAssertEqual(Int(back.pixels[0]), 200, accuracy: 2)
        XCTAssertEqual(back.pixels[3], 128)
    }
}
