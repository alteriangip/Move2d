import XCTest
@testable import M2DPSD
import M2DCore

final class PSDTests: XCTestCase {
    func solid(_ w: Int, _ h: Int, _ c: (UInt8, UInt8, UInt8, UInt8)) -> RGBAImage { RGBAImage(width: w, height: h, fill: c) }

    func makeDoc() -> PSDDocument {
        var eye = PSDLayer(kind: .pixel, name: "Eye ✨", layerID: 7, left: 10, top: 12, width: 8, height: 6, image: solid(8, 6, (10, 20, 30, 255)))
        eye.clipped = true
        let white = PSDLayer(kind: .pixel, name: "Eye White", layerID: 8, opacity: 0.5, left: 8, top: 10, width: 12, height: 10, image: solid(12, 10, (250, 250, 250, 200)))
        let group = PSDLayer(kind: .group, name: "Head", visible: false, collapsed: true, children: [eye, white])
        let body = PSDLayer(kind: .pixel, name: "Body", blendMode: .multiply, left: 0, top: 30, width: 40, height: 10, image: solid(40, 10, (200, 0, 0, 255)))
        return PSDDocument(width: 40, height: 40, layers: [group, body])
    }

    func testRoundTripStructure() throws {
        let bytes = PSDWriter.write(makeDoc())
        let doc = try PSDParser.parse(bytes)
        XCTAssertEqual(doc.width, 40); XCTAssertEqual(doc.height, 40)
        XCTAssertEqual(doc.layers.map(\.name), ["Head", "Body"])
        let head = doc.layers[0]
        XCTAssertEqual(head.kind, .group)
        XCTAssertFalse(head.visible)
        XCTAssertTrue(head.collapsed)
        XCTAssertEqual(head.children.map(\.name), ["Eye ✨", "Eye White"])
        XCTAssertTrue(head.children[0].clipped)
        XCTAssertEqual(head.children[0].layerID, 7)
        XCTAssertEqual(head.children[1].opacity, 128.0 / 255, accuracy: 0.01)
        XCTAssertEqual(doc.layers[1].blendMode, .multiply)
    }

    func testRoundTripPixels() throws {
        let doc = try PSDParser.parse(PSDWriter.write(makeDoc()))
        let eye = doc.layers[0].children[0]
        XCTAssertEqual(eye.left, 10); XCTAssertEqual(eye.top, 12); XCTAssertEqual(eye.width, 8); XCTAssertEqual(eye.height, 6)
        let px = eye.image!.pixel(3, 3)
        XCTAssertEqual(px.0, 10); XCTAssertEqual(px.1, 20); XCTAssertEqual(px.2, 30); XCTAssertEqual(px.3, 255)
        XCTAssertEqual(doc.layers[0].children[1].image!.pixel(0, 0).3, 200)
    }

    func testRejectsNonPSD() {
        XCTAssertThrowsError(try PSDParser.parse(Array("not a psd file at all, sorry!".utf8)))
    }

    func testPackBitsRoundTrip() {
        let rows: [[UInt8]] = [[], [1], [1, 1, 1, 1, 2, 3, 4, 4, 5], [UInt8](repeating: 9, count: 300), (0..<300).map { UInt8($0 % 7) }]
        for r in rows {
            let enc = PackBits.encode(r[...])
            XCTAssertEqual(PackBits.decode(enc, from: 0, to: enc.count, expected: r.count), r)
        }
    }

    func testZipPredictionChannel() throws {
        // Build a ZIP-with-prediction channel by hand: deltas per row.
        let w = 5, h = 2
        let raw: [UInt8] = [10, 12, 15, 15, 20, 1, 2, 3, 4, 5]
        var delta = raw
        for y in 0..<h { for x in stride(from: w - 1, through: 1, by: -1) { delta[y * w + x] = raw[y * w + x] &- raw[y * w + x - 1] } }
        var bytes: [UInt8] = [0, 3]
        bytes += Deflate.zlib(delta)
        let out = try PSDParser.readChannel(bytes, start: 0, length: bytes.count, width: w, height: h, depth: 8, psb: false)
        XCTAssertEqual(out, raw)
    }
}
