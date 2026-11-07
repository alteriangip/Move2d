import XCTest
@testable import M2DExport
import M2DProject
import M2DRig
import M2DCore
import Foundation

final class ExportTests: XCTestCase {
    func sample() throws -> ProjectBundle { try PSDImporter.importPSD(SampleCharacter.psdData(size: 128)).bundle }

    func testFrameRendererProducesFrames() throws {
        let b = try sample()
        let r = FrameRenderer(bundle: b, clipID: b.project.animations.first?.id,
                              settings: FrameExportSettings(width: 64, height: 64, frameRate: 10, duration: 0.5))
        let frames = r.renderAll()
        XCTAssertEqual(frames.count, 5)
        XCTAssertNotNil(frames[0].opaqueBounds(), "character is visible")
        XCTAssertEqual(frames[0].pixel(0, 0).3, 0, "background stays transparent")
    }

    func testPNGSequence() throws {
        let b = try sample()
        let r = FrameRenderer(bundle: b, clipID: nil, settings: FrameExportSettings(width: 32, height: 32, frameRate: 4, duration: 0.5))
        let files = PNGSequenceExporter.export(r, baseName: "idle")
        XCTAssertEqual(Set(files.keys), ["idle_0000.png", "idle_0001.png"])
        XCTAssertEqual(try PNG.decode(files["idle_0000.png"]!).width, 32)
    }

    func testGIFStructure() throws {
        var enc = GIFEncoder(width: 8, height: 8, frameDelay: 0.1)
        var img = RGBAImage(width: 8, height: 8, fill: (255, 0, 0, 255))
        img.pixels[3] = 0
        enc.addFrame(img)
        enc.addFrame(RGBAImage(width: 8, height: 8, fill: (0, 255, 0, 255)))
        let data = [UInt8](enc.finish())
        XCTAssertEqual(Array(data[0..<6]), Array("GIF89a".utf8))
        XCTAssertEqual(data.last, 0x3B)
    }

    func testLZWDecodesBack() {
        // Reference LZW decoder to verify the encoder, including dictionary resets.
        var rng = SystemRandomNumberGenerator()
        let input: [UInt8] = (0..<40_000).map { i in i % 97 < 50 ? UInt8(i % 5) : UInt8.random(in: 0...255, using: &rng) }
        let enc = GIFEncoder.lzw(input, minCodeSize: 8)
        XCTAssertEqual(lzwDecode(enc, minCodeSize: 8), input)
    }

    func lzwDecode(_ data: [UInt8], minCodeSize: Int) -> [UInt8] {
        let clear = 1 << minCodeSize, eoi = clear + 1
        var codeSize = minCodeSize + 1
        var dict: [[UInt8]] = []
        func reset() { dict = (0..<clear).map { [UInt8($0)] } + [[], []]; codeSize = minCodeSize + 1 }
        reset()
        var out: [UInt8] = [], prev: [UInt8]? = nil
        var bitPos = 0
        func read() -> Int? {
            guard (bitPos + codeSize + 7) / 8 <= data.count else { return nil }
            var v = 0
            for i in 0..<codeSize { let b = bitPos + i; if data[b / 8] >> (b % 8) & 1 == 1 { v |= 1 << i } }
            bitPos += codeSize; return v
        }
        while let code = read() {
            if code == clear { reset(); prev = nil; continue }
            if code == eoi { break }
            var entry: [UInt8]
            if code < dict.count { entry = dict[code] } else if let p = prev { entry = p + [p[0]] } else { break }
            out += entry
            if let p = prev, dict.count < 4096 { dict.append(p + [entry[0]]) }
            prev = entry
            if dict.count == (1 << codeSize) && codeSize < 12 { codeSize += 1 }
        }
        return out
    }

    func testRuntimeRoundTrip() throws {
        let b = try sample()
        let data = try RuntimeFormat.write(b)
        XCTAssertEqual(String(decoding: data.prefix(4), as: UTF8.self), "M2RT")
        let pkg = try RuntimeFormat.read(data)
        XCTAssertEqual(pkg.document.rig.meshes.count, b.project.rig.meshes.count)
        XCTAssertEqual(pkg.pages.count, pkg.document.rig.textures.count)
        XCTAssertTrue(pkg.document.rig.meshes.allSatisfy { m in m.mesh.uvs.allSatisfy { $0.x >= 0 && $0.x <= 1 && $0.y >= 0 && $0.y <= 1 } })
        // Rendering from the runtime package matches the editor render closely.
        let a = FrameRenderer(bundle: b, clipID: nil, settings: .init(width: 64, height: 64, duration: 0.01)).renderAll()[0]
        let c = FrameRenderer(bundle: pkg.bundle, clipID: nil, settings: .init(width: 64, height: 64, duration: 0.01)).renderAll()[0]
        var diff = 0
        for i in 0..<a.pixels.count { diff = max(diff, abs(Int(a.pixels[i]) - Int(c.pixels[i]))) }
        XCTAssertLessThan(diff, 40)
    }

    func testAtlasPackerNoOverlap() {
        let items: [(ObjectID, Int, Int)] = (0..<40).map { ("t\($0)", 30 + $0 * 7 % 90, 20 + $0 * 13 % 70) }
        let r = AtlasPacker.pack(items, maxSize: 256, padding: 2)
        XCTAssertEqual(r.placements.count, 40)
        let ps = Array(r.placements.values)
        for i in 0..<ps.count { for j in (i + 1)..<ps.count where ps[i].page == ps[j].page {
            let a = ps[i], b = ps[j]
            let overlap = a.x < b.x + b.width && b.x < a.x + a.width && a.y < b.y + b.height && b.y < a.y + a.height
            XCTAssertFalse(overlap)
        }}
        for p in ps { XCTAssertLessThanOrEqual(p.x + p.width, r.pageSizes[p.page].0); XCTAssertLessThanOrEqual(p.y + p.height, r.pageSizes[p.page].1) }
    }
}
