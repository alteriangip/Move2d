import Foundation

public enum PNGError: Error, CustomStringConvertible {
    case notPNG, unsupported(String), corrupt(String)
    public var description: String {
        switch self {
        case .notPNG: return "Not a PNG file"
        case let .unsupported(m): return "Unsupported PNG: \(m)"
        case let .corrupt(m): return "Corrupt PNG: \(m)"
        }
    }
}

/// Self-contained PNG codec (RGBA8 output). Decodes greyscale, RGB, palette,
/// grey+alpha and RGBA at 1–16 bits, including Adam7 interlacing.
public enum PNG {
    static let signature: [UInt8] = [137, 80, 78, 71, 13, 10, 26, 10]

    // MARK: Encode

    /// Encode a straight-alpha RGBA image. Premultiplied input is converted first.
    public static func encode(_ image: RGBAImage) -> Data {
        let img = image.toStraight()
        var w = ByteWriter()
        w.append(signature)
        var ihdr = ByteWriter()
        ihdr.u32(UInt32(img.width)); ihdr.u32(UInt32(img.height))
        ihdr.append([8, 6, 0, 0, 0])
        chunk(&w, "IHDR", ihdr.bytes)

        let stride = img.width * 4
        var raw = [UInt8](); raw.reserveCapacity((stride + 1) * img.height)
        var prevRow = [UInt8](repeating: 0, count: stride)
        var candidates = [[UInt8]](repeating: [UInt8](repeating: 0, count: stride), count: 5)
        for y in 0..<img.height {
            let row = Array(img.pixels[y * stride..<(y + 1) * stride])
            // Adaptive filter choice: minimum sum of absolute differences.
            var best = 0, bestScore = Int.max
            for f in 0..<5 {
                var score = 0
                for x in 0..<stride {
                    let a = x >= 4 ? Int(row[x - 4]) : 0, b = Int(prevRow[x]), c = x >= 4 ? Int(prevRow[x - 4]) : 0
                    let v: Int
                    switch f {
                    case 0: v = Int(row[x])
                    case 1: v = Int(row[x]) - a
                    case 2: v = Int(row[x]) - b
                    case 3: v = Int(row[x]) - (a + b) / 2
                    default: v = Int(row[x]) - paeth(a, b, c)
                    }
                    let byte = UInt8(truncatingIfNeeded: v)
                    candidates[f][x] = byte
                    score += Int(Int(Int8(bitPattern: byte)).magnitude)
                }
                if score < bestScore { bestScore = score; best = f }
            }
            raw.append(UInt8(best)); raw += candidates[best]
            prevRow = row
        }
        chunk(&w, "IDAT", Deflate.zlib(raw))
        chunk(&w, "IEND", [])
        return w.data
    }

    static func chunk(_ w: inout ByteWriter, _ type: String, _ data: [UInt8]) {
        w.u32(UInt32(data.count))
        let t = Array(type.utf8)
        w.append(t); w.append(data)
        w.u32(CRC32.update(CRC32.checksum(t), data))
    }

    @inline(__always) static func paeth(_ a: Int, _ b: Int, _ c: Int) -> Int {
        let p = a + b - c
        let pa = abs(p - a), pb = abs(p - b), pc = abs(p - c)
        if pa <= pb && pa <= pc { return a }
        return pb <= pc ? b : c
    }

    // MARK: Decode

    public static func decode(_ data: Data) throws -> RGBAImage {
        let bytes = [UInt8](data)
        guard bytes.count > 8, Array(bytes[0..<8]) == signature else { throw PNGError.notPNG }
        var r = ByteReader(bytes, offset: 8)
        var width = 0, height = 0, depth = 0, colorType = 0, interlace = 0
        var palette: [UInt8] = [], trns: [UInt8] = []
        var idat: [UInt8] = []
        while !r.isAtEnd {
            let len = Int(try r.u32())
            let type = try r.ascii(4)
            let body = Array(try r.bytes(len))
            _ = try r.u32()
            switch type {
            case "IHDR":
                var h = ByteReader(body)
                width = Int(try h.u32()); height = Int(try h.u32())
                depth = Int(try h.u8()); colorType = Int(try h.u8())
                _ = try h.u8(); _ = try h.u8(); interlace = Int(try h.u8())
            case "PLTE": palette = body
            case "tRNS": trns = body
            case "IDAT": idat += body
            case "IEND": break
            default: continue
            }
            if type == "IEND" { break }
        }
        guard width > 0, height > 0 else { throw PNGError.corrupt("missing IHDR") }
        let channels: Int
        switch colorType {
        case 0: channels = 1
        case 2: channels = 3
        case 3: channels = 1
        case 4: channels = 2
        case 6: channels = 4
        default: throw PNGError.unsupported("color type \(colorType)")
        }
        guard [1, 2, 4, 8, 16].contains(depth) else { throw PNGError.unsupported("bit depth \(depth)") }
        let raw = try Inflate.zlib(idat)
        var out = [UInt8](repeating: 0, count: width * height * 4)
        let bpp = max(1, channels * depth / 8)

        func unfilter(_ w: Int, _ h: Int, _ start: inout Int, _ emit: (Int, Int, [UInt8]) -> Void) throws {
            let stride = (w * channels * depth + 7) / 8
            var prev = [UInt8](repeating: 0, count: stride)
            for y in 0..<h {
                guard start + 1 + stride <= raw.count else { throw PNGError.corrupt("truncated image data") }
                let f = raw[start]
                var row = Array(raw[start + 1..<start + 1 + stride])
                start += 1 + stride
                for x in 0..<stride {
                    let a = x >= bpp ? Int(row[x - bpp]) : 0, b = Int(prev[x]), c = x >= bpp ? Int(prev[x - bpp]) : 0
                    let add: Int
                    switch f {
                    case 0: add = 0
                    case 1: add = a
                    case 2: add = b
                    case 3: add = (a + b) / 2
                    case 4: add = paeth(a, b, c)
                    default: throw PNGError.corrupt("bad filter \(f)")
                    }
                    row[x] = UInt8(truncatingIfNeeded: Int(row[x]) + add)
                }
                emit(y, w, row)
                prev = row
            }
        }

        func sample(_ row: [UInt8], _ i: Int) -> Int {
            switch depth {
            case 16: return Int(row[i * 2])
            case 8: return Int(row[i])
            default:
                let bitPos = i * depth
                let byte = Int(row[bitPos / 8])
                let shift = 8 - depth - bitPos % 8
                return (byte >> shift) & ((1 << depth) - 1)
            }
        }
        func scaled(_ v: Int) -> UInt8 {
            switch depth {
            case 1: return v != 0 ? 255 : 0
            case 2: return UInt8(v * 85)
            case 4: return UInt8(v * 17)
            default: return UInt8(v)
            }
        }
        let trnsGray = trns.count >= 2 ? Int(trns[0]) << 8 | Int(trns[1]) : -1
        let trnsRGB: (Int, Int, Int)? = trns.count >= 6
            ? (Int(trns[0]) << 8 | Int(trns[1]), Int(trns[2]) << 8 | Int(trns[3]), Int(trns[4]) << 8 | Int(trns[5])) : nil
        func rawSample16(_ row: [UInt8], _ i: Int) -> Int {
            depth == 16 ? Int(row[i * 2]) << 8 | Int(row[i * 2 + 1]) : sample(row, i)
        }

        func writePixel(_ x: Int, _ y: Int, _ row: [UInt8], _ col: Int) {
            let o = (y * width + x) * 4
            switch colorType {
            case 0:
                let v = scaled(sample(row, col))
                out[o] = v; out[o + 1] = v; out[o + 2] = v
                out[o + 3] = rawSample16(row, col) == trnsGray ? 0 : 255
            case 2:
                out[o] = scaled(sample(row, col * 3)); out[o + 1] = scaled(sample(row, col * 3 + 1)); out[o + 2] = scaled(sample(row, col * 3 + 2))
                if let t = trnsRGB, rawSample16(row, col * 3) == t.0, rawSample16(row, col * 3 + 1) == t.1, rawSample16(row, col * 3 + 2) == t.2 {
                    out[o + 3] = 0
                } else { out[o + 3] = 255 }
            case 3:
                let idx = sample(row, col)
                if idx * 3 + 2 < palette.count {
                    out[o] = palette[idx * 3]; out[o + 1] = palette[idx * 3 + 1]; out[o + 2] = palette[idx * 3 + 2]
                }
                out[o + 3] = idx < trns.count ? trns[idx] : 255
            case 4:
                let v = scaled(sample(row, col * 2))
                out[o] = v; out[o + 1] = v; out[o + 2] = v; out[o + 3] = scaled(sample(row, col * 2 + 1))
            default:
                out[o] = scaled(sample(row, col * 4)); out[o + 1] = scaled(sample(row, col * 4 + 1))
                out[o + 2] = scaled(sample(row, col * 4 + 2)); out[o + 3] = scaled(sample(row, col * 4 + 3))
            }
        }

        var pos = 0
        if interlace == 0 {
            try unfilter(width, height, &pos) { y, w, row in for x in 0..<w { writePixel(x, y, row, x) } }
        } else {
            let passes = [(0, 0, 8, 8), (4, 0, 8, 8), (0, 4, 4, 8), (2, 0, 4, 4), (0, 2, 2, 4), (1, 0, 2, 2), (0, 1, 1, 2)]
            for (x0, y0, dx, dy) in passes {
                let pw = (width - x0 + dx - 1) / dx, ph = (height - y0 + dy - 1) / dy
                guard pw > 0, ph > 0 else { continue }
                try unfilter(pw, ph, &pos) { y, w, row in
                    for x in 0..<w { writePixel(x0 + x * dx, y0 + y * dy, row, x) }
                }
            }
        }
        return RGBAImage(width: width, height: height, pixels: out)
    }
}
