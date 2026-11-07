import Foundation
import M2DCore

/// Independent reader for layered Photoshop documents (.psd and .psb).
///
/// Supports RGB and Grayscale at 8/16/32 bits per channel, raw / RLE / ZIP /
/// ZIP-with-prediction channel compression, layer groups (section dividers),
/// Unicode names, visibility, opacity + fill opacity, blend modes, clipping and
/// pixel layer masks. Adjustment/text/smart-object layers import as their
/// rasterised pixel data, which Photoshop stores alongside them.
public enum PSDParser {
    public struct Options: Sendable {
        /// Skip decoding pixels (fast structure-only read for previews).
        public var decodePixels = true
        /// Apply pixel layer masks to alpha.
        public var applyMasks = true
        public init() {}
    }

    public static func parse(_ bytes: [UInt8], options: Options = Options()) throws -> PSDDocument {
        var r = ByteReader(bytes)
        guard bytes.count >= 26, try r.ascii(4) == "8BPS" else { throw PSDError.notPSD }
        let version = Int(try r.u16())
        guard version == 1 || version == 2 else { throw PSDError.unsupportedVersion(version) }
        let psb = version == 2
        try r.skip(6)
        _ = try r.u16() // channel count of merged image
        let height = Int(try r.u32()), width = Int(try r.u32())
        let depth = Int(try r.u16())
        let mode = Int(try r.u16())
        guard [1, 8, 16, 32].contains(depth) else { throw PSDError.unsupportedDepth(depth) }
        guard mode == 3 || mode == 1 else { throw PSDError.unsupportedColorMode(mode) }
        guard depth != 1 else { throw PSDError.unsupportedDepth(1) }

        try r.skip(Int(try r.u32())) // color mode data
        try r.skip(Int(try r.u32())) // image resources

        var warnings: [String] = []
        let lmLength = psb ? Int(try r.u64()) : Int(try r.u32())
        guard lmLength > 0 else {
            return PSDDocument(width: width, height: height, depth: depth, colorMode: mode, isPSB: psb,
                               layers: [], warnings: ["The document has no layers (flattened image)."])
        }
        let lmEnd = r.offset + lmLength
        guard lmEnd <= bytes.count else { throw PSDError.corrupt("layer section exceeds file size") }

        var records: [Record] = []
        let liLength = psb ? Int(try r.u64()) : Int(try r.u32())
        if liLength > 0 {
            let liEnd = r.offset + liLength
            records = try readLayerInfo(&r, psb: psb, depth: depth, mode: mode, options: options, warnings: &warnings)
            r.offset = liEnd
        } else {
            // 16/32-bit documents store layers in an 'Lr16'/'Lr32' block after the global mask.
            try r.skip(Int(try r.u32())) // global layer mask info
            while r.offset + 12 <= lmEnd {
                guard try r.ascii(4).hasPrefix("8B") else { break }
                let key = try r.ascii(4)
                let len = psb && ["Lr16", "Lr32", "Layr"].contains(key) ? Int(try r.u64()) : Int(try r.u32())
                let start = r.offset
                if ["Lr16", "Lr32", "Layr"].contains(key) {
                    records = try readLayerInfo(&r, psb: psb, depth: depth, mode: mode, options: options, warnings: &warnings)
                }
                r.offset = start + len
                if r.offset % 4 != 0 { r.offset += 4 - r.offset % 4 }
            }
        }

        let tree = buildTree(records, warnings: &warnings)
        return PSDDocument(width: width, height: height, depth: depth, colorMode: mode, isPSB: psb,
                           layers: tree, warnings: warnings)
    }

    // MARK: - Layer records

    struct ChannelInfo { var id: Int; var length: Int }

    struct Record {
        var top = 0, left = 0, bottom = 0, right = 0
        var channels: [ChannelInfo] = []
        var blend: PSDBlendMode = .normal
        var opacity: UInt8 = 255
        var fill: UInt8 = 255
        var clipping = false
        var hidden = false
        var name = ""
        var layerID: Int?
        var section = 0 // 0 normal, 1 open folder, 2 closed folder, 3 divider
        var mask: (top: Int, left: Int, bottom: Int, right: Int, defaultColor: UInt8, disabled: Bool)?
        var image: RGBAImage?
    }

    static func readLayerInfo(_ r: inout ByteReader, psb: Bool, depth: Int, mode: Int,
                              options: Options, warnings: inout [String]) throws -> [Record] {
        let count = abs(Int(try r.i16()))
        var records: [Record] = []
        records.reserveCapacity(count)
        for _ in 0..<count {
            var rec = Record()
            rec.top = Int(try r.i32()); rec.left = Int(try r.i32())
            rec.bottom = Int(try r.i32()); rec.right = Int(try r.i32())
            let nch = Int(try r.u16())
            guard nch <= 56 else { throw PSDError.corrupt("implausible channel count \(nch)") }
            for _ in 0..<nch {
                let id = Int(try r.i16())
                let len = psb ? Int(try r.u64()) : Int(try r.u32())
                rec.channels.append(ChannelInfo(id: id, length: len))
            }
            guard try r.ascii(4) == "8BIM" else { throw PSDError.corrupt("bad blend signature") }
            let key = try r.ascii(4)
            rec.blend = PSDBlendMode(rawValue: key) ?? .normal
            rec.opacity = try r.u8()
            rec.clipping = try r.u8() == 1
            let flags = try r.u8()
            rec.hidden = flags & 0x02 != 0
            _ = try r.u8()
            let extraLen = Int(try r.u32())
            let extraEnd = r.offset + extraLen

            // Layer mask data
            let maskLen = Int(try r.u32())
            let maskStart = r.offset
            if maskLen >= 18 {
                let t = Int(try r.i32()), l = Int(try r.i32()), b = Int(try r.i32()), rt = Int(try r.i32())
                let def = try r.u8()
                let mflags = try r.u8()
                rec.mask = (t, l, b, rt, def, mflags & 0x02 != 0)
            }
            r.offset = maskStart + maskLen
            try r.skip(Int(try r.u32())) // blending ranges
            let nameLen = Int(try r.u8())
            rec.name = decodeMacRoman(Array(try r.bytes(nameLen)))
            let padded = (nameLen + 1 + 3) & ~3
            try r.skip(padded - nameLen - 1)

            // Additional layer information
            while r.offset + 12 <= extraEnd {
                let sig = try r.ascii(4)
                guard sig == "8BIM" || sig == "8B64" else { break }
                let k = try r.ascii(4)
                let longKeys: Set<String> = ["LMsk", "Lr16", "Lr32", "Layr", "Mt16", "Mt32", "Mtrn", "Alph", "FMsk", "lnk2", "FEid", "FXid", "PxSD"]
                let len = psb && longKeys.contains(k) ? Int(try r.u64()) : Int(try r.u32())
                let start = r.offset
                guard start + len <= extraEnd else { break }
                var sub = ByteReader(Array(r.bytes[start..<start + len]))
                switch k {
                case "luni":
                    let n = Int(try sub.u32())
                    var units: [UInt16] = []
                    for _ in 0..<min(n, sub.remaining / 2) { units.append(try sub.u16()) }
                    while units.last == 0 { units.removeLast() }
                    rec.name = String(decoding: units, as: UTF16.self)
                case "lsct", "lsdk":
                    rec.section = Int(try sub.u32())
                    if len >= 12, try sub.ascii(4) == "8BIM" {
                        if let bm = PSDBlendMode(rawValue: try sub.ascii(4)) { rec.blend = bm }
                    }
                case "lyid": rec.layerID = Int(try sub.u32())
                case "iOpa": rec.fill = try sub.u8()
                default: break
                }
                r.offset = start + len
            }
            r.offset = extraEnd
            records.append(rec)
        }

        // Channel image data, in record order.
        for i in records.indices {
            var rec = records[i]
            let w = rec.right - rec.left, h = rec.bottom - rec.top
            var planes: [Int: [UInt8]] = [:]
            for ch in rec.channels {
                let start = r.offset
                defer { r.offset = start + ch.length }
                guard ch.length >= 2, options.decodePixels else { continue }
                var cw = w, chh = h
                if ch.id == -2 || ch.id == -3, let m = rec.mask {
                    cw = m.right - m.left; chh = m.bottom - m.top
                }
                guard cw > 0, chh > 0 else { continue }
                do {
                    planes[ch.id] = try readChannel(r.bytes, start: start, length: ch.length,
                                                    width: cw, height: chh, depth: depth, psb: psb)
                } catch {
                    warnings.append("Layer \"\(rec.name)\": channel \(ch.id) could not be decoded (\(error)).")
                }
            }
            if options.decodePixels, w > 0, h > 0, rec.section == 0 {
                rec.image = compose(planes: planes, width: w, height: h, mode: mode, rec: rec, applyMask: options.applyMasks)
            }
            records[i] = rec
        }
        return records
    }

    /// Decode one channel into 8-bit samples.
    static func readChannel(_ bytes: [UInt8], start: Int, length: Int, width: Int, height: Int,
                            depth: Int, psb: Bool) throws -> [UInt8] {
        var r = ByteReader(bytes, offset: start)
        let compression = Int(try r.u16())
        let bpc = depth / 8
        let rowBytes = width * bpc
        let total = rowBytes * height
        var raw: [UInt8]
        switch compression {
        case 0:
            raw = Array(try r.bytes(min(total, length - 2)))
            if raw.count < total { raw += [UInt8](repeating: 0, count: total - raw.count) }
        case 1:
            var counts: [Int] = []
            counts.reserveCapacity(height)
            for _ in 0..<height { counts.append(psb ? Int(try r.u32()) : Int(try r.u16())) }
            raw = []; raw.reserveCapacity(total)
            for c in counts {
                let rowEnd = r.offset + c
                var row = PackBits.decode(r.bytes, from: r.offset, to: min(rowEnd, r.bytes.count), expected: rowBytes)
                if row.count < rowBytes { row += [UInt8](repeating: 0, count: rowBytes - row.count) }
                raw += row.prefix(rowBytes)
                r.offset = rowEnd
            }
        case 2, 3:
            raw = try Inflate.zlib(r.bytes[r.offset..<min(start + length, r.bytes.count)], expectedSize: total)
            if raw.count < total { raw += [UInt8](repeating: 0, count: total - raw.count) }
            if compression == 3 { unpredict(&raw, width: width, height: height, depth: depth) }
        default:
            throw PSDError.corrupt("unknown compression \(compression)")
        }
        // Reduce to 8 bits.
        switch depth {
        case 8: return raw
        case 16:
            var out = [UInt8](repeating: 0, count: width * height)
            for i in 0..<out.count { out[i] = raw[i * 2] }
            return out
        default:
            var out = [UInt8](repeating: 0, count: width * height)
            for i in 0..<out.count {
                let b = UInt32(raw[i * 4]) << 24 | UInt32(raw[i * 4 + 1]) << 16 | UInt32(raw[i * 4 + 2]) << 8 | UInt32(raw[i * 4 + 3])
                let f = Float(bitPattern: b)
                // 32-bit documents are linear; convert to sRGB-ish gamma.
                let g: Float = pow(max(f, 0), 1 / 2.2) * 255 + 0.5
                out[i] = UInt8(clamp(g, 0, 255))
            }
            return out
        }
    }

    /// Undo ZIP-with-prediction delta encoding.
    static func unpredict(_ data: inout [UInt8], width: Int, height: Int, depth: Int) {
        switch depth {
        case 8:
            for y in 0..<height { let o = y * width; for x in 1..<max(width, 1) { data[o + x] = data[o + x] &+ data[o + x - 1] } }
        case 16:
            for y in 0..<height {
                let o = y * width * 2
                for x in 1..<max(width, 1) {
                    let p = UInt16(data[o + (x - 1) * 2]) << 8 | UInt16(data[o + (x - 1) * 2 + 1])
                    let c = UInt16(data[o + x * 2]) << 8 | UInt16(data[o + x * 2 + 1])
                    let v = c &+ p
                    data[o + x * 2] = UInt8(v >> 8); data[o + x * 2 + 1] = UInt8(v & 0xff)
                }
            }
        default:
            // 32-bit: bytes are delta-encoded across the row, then split into byte planes.
            let rowBytes = width * 4
            var row = [UInt8](repeating: 0, count: rowBytes)
            for y in 0..<height {
                let o = y * rowBytes
                for i in 1..<max(rowBytes, 1) { data[o + i] = data[o + i] &+ data[o + i - 1] }
                for x in 0..<width {
                    for b in 0..<4 { row[x * 4 + b] = data[o + b * width + x] }
                }
                for i in 0..<rowBytes { data[o + i] = row[i] }
            }
        }
    }

    static func compose(planes: [Int: [UInt8]], width w: Int, height h: Int, mode: Int, rec: Record, applyMask: Bool) -> RGBAImage {
        var px = [UInt8](repeating: 0, count: w * h * 4)
        let n = w * h
        let r = planes[0], g = mode == 1 ? planes[0] : planes[1], b = mode == 1 ? planes[0] : planes[2]
        let a = planes[-1]
        for i in 0..<n {
            px[i * 4] = r?[i] ?? 0
            px[i * 4 + 1] = g?[i] ?? 0
            px[i * 4 + 2] = b?[i] ?? 0
            px[i * 4 + 3] = a?[i] ?? 255
        }
        if applyMask, let m = rec.mask, !m.disabled, let maskPlane = planes[-2] {
            let mw = m.right - m.left
            for y in 0..<h {
                for x in 0..<w {
                    let dx = rec.left + x - m.left, dy = rec.top + y - m.top
                    let mv: UInt8
                    if dx >= 0, dy >= 0, dx < mw, dy < m.bottom - m.top { mv = maskPlane[dy * mw + dx] } else { mv = m.defaultColor }
                    let idx = (y * w + x) * 4 + 3
                    px[idx] = UInt8((UInt16(px[idx]) * UInt16(mv) + 127) / 255)
                }
            }
        }
        return RGBAImage(width: w, height: h, pixels: px)
    }

    // MARK: - Tree

    static func buildTree(_ records: [Record], warnings: inout [String]) -> [PSDLayer] {
        // Records run bottom-to-top. A divider (3) opens a group whose header
        // record (1 or 2) appears after all its children.
        var stack: [[PSDLayer]] = [[]]
        for rec in records {
            switch rec.section {
            case 3:
                stack.append([])
            case 1, 2:
                let children = stack.count > 1 ? stack.removeLast() : []
                if stack.isEmpty { stack = [[]] }
                let group = PSDLayer(kind: .group, name: rec.name, layerID: rec.layerID, visible: !rec.hidden,
                                     opacity: Float(rec.opacity) / 255 * Float(rec.fill) / 255,
                                     blendMode: rec.blend, clipped: rec.clipping, collapsed: rec.section == 2,
                                     children: children.reversed())
                stack[stack.count - 1].append(group)
            default:
                let w = max(0, rec.right - rec.left), h = max(0, rec.bottom - rec.top)
                let layer = PSDLayer(kind: .pixel, name: rec.name, layerID: rec.layerID, visible: !rec.hidden,
                                     opacity: Float(rec.opacity) / 255 * Float(rec.fill) / 255,
                                     blendMode: rec.blend, clipped: rec.clipping,
                                     left: rec.left, top: rec.top, width: w, height: h, image: rec.image)
                stack[stack.count - 1].append(layer)
            }
        }
        if stack.count > 1 {
            warnings.append("Unbalanced layer groups; unclosed groups were flattened into the root.")
            while stack.count > 1 { let c = stack.removeLast(); stack[stack.count - 1] += c }
        }
        return stack[0].reversed()
    }

    static func decodeMacRoman(_ bytes: [UInt8]) -> String {
        // ASCII range is identical; non-ASCII Pascal names are superseded by 'luni' in practice.
        String(decoding: bytes.map { $0 < 128 ? $0 : 63 }, as: UTF8.self)
    }
}

/// PackBits run-length codec used by PSD RLE channels.
public enum PackBits {
    public static func decode(_ bytes: [UInt8], from: Int, to: Int, expected: Int) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(expected)
        var i = from
        while i < to, out.count < expected {
            let n = Int(Int8(bitPattern: bytes[i])); i += 1
            if n >= 0 {
                let end = min(i + n + 1, to)
                out += bytes[i..<end]; i = end
            } else if n != -128 {
                guard i < to else { break }
                out += [UInt8](repeating: bytes[i], count: 1 - n); i += 1
            }
        }
        return out
    }

    public static func encode(_ row: ArraySlice<UInt8>) -> [UInt8] {
        let b = Array(row)
        var out: [UInt8] = []
        var i = 0
        while i < b.count {
            var run = 1
            while i + run < b.count, run < 128, b[i + run] == b[i] { run += 1 }
            if run >= 2 {
                out.append(UInt8(bitPattern: Int8(1 - run))); out.append(b[i]); i += run
            } else {
                var j = i
                while j < b.count, j - i < 128, !(j + 1 < b.count && b[j] == b[j + 1]) { j += 1 }
                if j == i { j = i + 1 }
                out.append(UInt8(j - i - 1)); out += b[i..<j]; i = j
            }
        }
        return out
    }
}
