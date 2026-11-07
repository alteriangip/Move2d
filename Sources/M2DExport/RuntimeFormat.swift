import Foundation
import M2DCore
import M2DRig
import M2DAnimation
import M2DPhysics
import M2DProject

/// `.m2rt` — compact runtime package for games.
///
/// Layout (little endian):
///
///     magic   "M2RT"
///     u16     version (1)
///     u16     flags (0)
///     chunks: tag[4] u32 length payload[length]
///       "RIG " zlib-compressed compact JSON (`RuntimeDocument`)
///       "ATLS" one per atlas page: u16 page index, then PNG bytes
///     "END " with length 0 terminates the file
///
/// Textures are packed into atlas pages and mesh UVs remapped, so a game can
/// render a whole character with very few texture binds. See docs/runtime-format.md.
public enum RuntimeFormat {
    public static let magic = "M2RT"
    public static let version: UInt16 = 1
    public static let fileExtension = "m2rt"

    public struct RuntimeDocument: Codable, Sendable {
        public var version: Int
        public var rig: RigModel
        public var animations: [AnimationClip]
        public var physics: PhysicsRig
    }

    public struct Package: Sendable {
        public var document: RuntimeDocument
        /// Atlas pages, keyed by the texture id used in `document.rig.textures`.
        public var pages: [ObjectID: RGBAImage]
        public var bundle: ProjectBundle {
            ProjectBundle(project: Project(rig: document.rig, animations: document.animations, physics: document.physics), textures: pages)
        }
    }

    public struct Options: Sendable {
        public var maxAtlasSize = 4096
        public var padding = 2
        /// Uniform texture scale (e.g. 0.5 for a half-resolution runtime build).
        public var textureScale: Float = 1
        public init() {}
    }

    // MARK: Write

    public static func write(_ bundle: ProjectBundle, options: Options = Options()) throws -> Data {
        var rig = bundle.project.rig
        // Strip editor-only state.
        for i in rig.parts.indices { rig.parts[i].locked = false; rig.parts[i].expanded = true }
        for i in rig.meshes.indices { rig.meshes[i].locked = false }
        for i in rig.deformers.indices { rig.deformers[i].showHandles = false }

        // Only textures that are actually used.
        let used = Set(rig.meshes.map(\.textureID))
        var images: [(ObjectID, RGBAImage)] = []
        for t in rig.textures where used.contains(t.id) {
            guard var img = bundle.textures[t.id] else { throw ProjectError.missingTexture(t.name) }
            if options.textureScale != 1 { img = resample(img, scale: options.textureScale) }
            images.append((t.id, img))
        }
        let packing = AtlasPacker.pack(images.map { ($0.0, $0.1.width, $0.1.height) },
                                       maxSize: options.maxAtlasSize, padding: options.padding)
        var pages: [RGBAImage] = packing.pageSizes.map { RGBAImage(width: $0.0, height: $0.1) }
        let imageByID = Dictionary(uniqueKeysWithValues: images)
        for (id, place) in packing.placements {
            guard let img = imageByID[id] else { continue }
            blit(img, into: &pages[place.page], x: place.x, y: place.y)
        }
        let pageIDs = pages.indices.map { "atlas_\($0)" }
        rig.textures = pages.enumerated().map { TextureInfo(id: pageIDs[$0.offset], name: "Atlas \($0.offset)", width: $0.element.width, height: $0.element.height) }
        for i in rig.meshes.indices {
            let m = rig.meshes[i]
            guard let place = packing.placements[m.textureID] else { continue }
            let page = pages[place.page]
            let pw = Float(page.width), ph = Float(page.height)
            let sw = Float(place.width) / pw, sh = Float(place.height) / ph
            let ox = Float(place.x) / pw, oy = Float(place.y) / ph
            rig.meshes[i].mesh.uvs = m.mesh.uvs.map { Vec2(ox + $0.x * sw, oy + $0.y * sh) }
            rig.meshes[i].textureID = pageIDs[place.page]
        }

        let doc = RuntimeDocument(version: Int(version), rig: rig, animations: bundle.project.animations, physics: bundle.project.physics)
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        let json = try enc.encode(doc)

        var w = ByteWriter(bigEndian: false)
        w.ascii(magic); w.u16(version); w.u16(0)
        let z = Deflate.zlib([UInt8](json))
        w.ascii("RIG "); w.u32(UInt32(z.count)); w.append(z)
        for (i, page) in pages.enumerated() {
            let png = [UInt8](PNG.encode(page))
            w.ascii("ATLS"); w.u32(UInt32(png.count + 2)); w.u16(UInt16(i)); w.append(png)
        }
        w.ascii("END "); w.u32(0)
        return w.data
    }

    // MARK: Read

    public static func read(_ data: Data) throws -> Package {
        var r = ByteReader(data, bigEndian: false)
        guard try r.ascii(4) == magic else { throw ProjectError.invalid("not a Move2D runtime file") }
        let v = try r.u16()
        guard v <= version else { throw ProjectError.newerFormat(Int(v)) }
        _ = try r.u16()
        var doc: RuntimeDocument?
        var pages: [Int: RGBAImage] = [:]
        while !r.isAtEnd {
            let tag = try r.ascii(4)
            let len = Int(try r.u32())
            let body = Array(try r.bytes(len))
            switch tag {
            case "RIG ":
                let json = try Inflate.zlib(body)
                doc = try JSONDecoder().decode(RuntimeDocument.self, from: Data(json))
            case "ATLS":
                var br = ByteReader(body, bigEndian: false)
                let idx = Int(try br.u16())
                pages[idx] = try PNG.decode(Data(body[2...]))
            case "END ": break
            default: continue // forward compatible: skip unknown chunks
            }
            if tag == "END " { break }
        }
        guard let doc else { throw ProjectError.invalid("runtime file has no RIG chunk") }
        var byID: [ObjectID: RGBAImage] = [:]
        for (i, img) in pages { byID["atlas_\(i)"] = img }
        return Package(document: doc, pages: byID)
    }

    // MARK: Helpers

    static func blit(_ src: RGBAImage, into dst: inout RGBAImage, x: Int, y: Int) {
        let s = src.toStraight()
        for row in 0..<s.height {
            let dy = y + row
            guard dy >= 0, dy < dst.height else { continue }
            let so = row * s.width * 4, d0 = (dy * dst.width + x) * 4
            let n = min(s.width, dst.width - x) * 4
            guard n > 0 else { continue }
            dst.pixels.replaceSubrange(d0..<d0 + n, with: s.pixels[so..<so + n])
        }
    }

    static func resample(_ img: RGBAImage, scale: Float) -> RGBAImage {
        let w = max(1, Int(Float(img.width) * scale)), h = max(1, Int(Float(img.height) * scale))
        let pm = img.toPremultiplied()
        var px = [UInt8](repeating: 0, count: w * h * 4)
        for y in 0..<h { for x in 0..<w {
            let c = pm.samplePremultiplied(u: (Float(x) + 0.5) / Float(w), v: (Float(y) + 0.5) / Float(h))
            let o = (y * w + x) * 4
            px[o] = UInt8(clamp(c.x * 255, 0, 255)); px[o + 1] = UInt8(clamp(c.y * 255, 0, 255))
            px[o + 2] = UInt8(clamp(c.z * 255, 0, 255)); px[o + 3] = UInt8(clamp(c.w * 255, 0, 255))
        }}
        return RGBAImage(width: w, height: h, pixels: px, premultiplied: true).toStraight()
    }
}

/// Shelf bin packer for texture atlases.
public enum AtlasPacker {
    public struct Placement: Hashable, Sendable { public var page: Int, x: Int, y: Int, width: Int, height: Int }
    public struct Result: Sendable {
        public var placements: [ObjectID: Placement]
        public var pageSizes: [(Int, Int)]
    }

    public static func pack(_ items: [(ObjectID, Int, Int)], maxSize: Int, padding: Int) -> Result {
        let sorted = items.sorted { $0.2 > $1.2 || ($0.2 == $1.2 && $0.1 > $1.1) }
        var placements: [ObjectID: Placement] = [:]
        var pages: [(w: Int, h: Int)] = []
        var page = 0, x = padding, y = padding, shelfH = 0, usedW = 0
        func closePage() { pages.append((nextPow2(max(usedW, 1)), nextPow2(max(y + shelfH + padding, 1)))) }
        for (id, w0, h0) in sorted {
            let w = min(w0, maxSize - 2 * padding), h = min(h0, maxSize - 2 * padding)
            if x + w + padding > maxSize { x = padding; y += shelfH + padding; shelfH = 0 }
            if y + h + padding > maxSize {
                closePage(); page += 1; x = padding; y = padding; shelfH = 0; usedW = 0
            }
            placements[id] = Placement(page: page, x: x, y: y, width: w, height: h)
            x += w + padding; shelfH = max(shelfH, h); usedW = max(usedW, x)
        }
        if !sorted.isEmpty { closePage() }
        return Result(placements: placements, pageSizes: pages.map { (min($0.w, maxSize), min($0.h, maxSize)) })
    }

    static func nextPow2(_ v: Int) -> Int { var p = 1; while p < v { p <<= 1 }; return p }
}
