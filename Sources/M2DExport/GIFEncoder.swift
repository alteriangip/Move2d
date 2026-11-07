import Foundation
import M2DCore

/// Animated GIF encoder with per-frame median-cut palettes and 1-bit
/// transparency (GIF cannot store partial alpha; pixels under `alphaThreshold`
/// become transparent, the rest are composited onto `matte`).
public struct GIFEncoder {
    public var width: Int
    public var height: Int
    /// Delay per frame in seconds (stored in 1/100 s units).
    public var frameDelay: Double
    public var loopCount: Int = 0
    public var alphaThreshold: UInt8 = 128
    /// Background colour used for semi-transparent edges.
    public var matte: (UInt8, UInt8, UInt8) = (255, 255, 255)
    var out = ByteWriter(bigEndian: false)
    var started = false

    public init(width: Int, height: Int, frameDelay: Double) {
        self.width = width; self.height = height; self.frameDelay = frameDelay
    }

    mutating func header() {
        out.ascii("GIF89a")
        out.u16(UInt16(width)); out.u16(UInt16(height))
        out.u8(0x70) // no global colour table, 8-bit colour resolution
        out.u8(0); out.u8(0)
        // NETSCAPE2.0 looping extension
        out.append([0x21, 0xFF, 0x0B]); out.ascii("NETSCAPE2.0")
        out.append([0x03, 0x01]); out.u16(UInt16(loopCount)); out.u8(0)
        started = true
    }

    public mutating func addFrame(_ image: RGBAImage) {
        if !started { header() }
        let img = image.toStraight()
        let n = width * height
        // Composite partial alpha onto matte, mark transparency.
        var rgb = [SIMD3<UInt8>](repeating: .zero, count: n)
        var transparent = [Bool](repeating: false, count: n)
        for i in 0..<n {
            let a = img.pixels[i * 4 + 3]
            if a < alphaThreshold { transparent[i] = true; continue }
            let af = UInt16(a), ia = 255 - af
            rgb[i] = SIMD3(UInt8((UInt16(img.pixels[i * 4]) * af + UInt16(matte.0) * ia) / 255),
                           UInt8((UInt16(img.pixels[i * 4 + 1]) * af + UInt16(matte.1) * ia) / 255),
                           UInt8((UInt16(img.pixels[i * 4 + 2]) * af + UInt16(matte.2) * ia) / 255))
        }
        let opaque = (0..<n).filter { !transparent[$0] }.map { rgb[$0] }
        let palette = Self.medianCut(opaque, maxColors: 255)
        // Index 0 is transparent.
        var cache: [UInt32: UInt8] = [:]
        var indices = [UInt8](repeating: 0, count: n)
        for i in 0..<n where !transparent[i] {
            let c = rgb[i]
            let key = UInt32(c.x) << 16 | UInt32(c.y) << 8 | UInt32(c.z)
            if let idx = cache[key] { indices[i] = idx; continue }
            var best = 0, bestD = Int.max
            for (pi, p) in palette.enumerated() {
                let dr = Int(p.x) - Int(c.x), dg = Int(p.y) - Int(c.y), db = Int(p.z) - Int(c.z)
                let d = dr * dr * 2 + dg * dg * 4 + db * db * 3
                if d < bestD { bestD = d; best = pi; if d == 0 { break } }
            }
            let idx = UInt8(best + 1)
            cache[key] = idx; indices[i] = idx
        }
        // Graphic control extension: disposal 2 (restore to background), transparency on.
        out.append([0x21, 0xF9, 0x04, 0x09])
        out.u16(UInt16(max(1, (frameDelay * 100).rounded())))
        out.u8(0); out.u8(0)
        // Image descriptor with local colour table (256 entries).
        out.u8(0x2C); out.u16(0); out.u16(0); out.u16(UInt16(width)); out.u16(UInt16(height))
        out.u8(0x87)
        out.append([0, 0, 0])
        for p in palette { out.append([p.x, p.y, p.z]) }
        for _ in palette.count..<255 { out.append([0, 0, 0]) }
        // LZW image data.
        out.u8(8)
        let lzw = Self.lzw(indices, minCodeSize: 8)
        var o = 0
        while o < lzw.count {
            let len = min(255, lzw.count - o)
            out.u8(UInt8(len)); out.append(lzw[o..<o + len]); o += len
        }
        out.u8(0)
    }

    public mutating func finish() -> Data {
        if !started { header() }
        out.u8(0x3B)
        return out.data
    }

    // MARK: Quantisation

    static func medianCut(_ colors: [SIMD3<UInt8>], maxColors: Int) -> [SIMD3<UInt8>] {
        guard !colors.isEmpty else { return [SIMD3(0, 0, 0)] }
        // Histogram at 5 bits per channel keeps the work bounded.
        var hist: [UInt16: (count: Int, sum: SIMD3<Int>)] = [:]
        for c in colors {
            let k = UInt16(c.x >> 3) << 10 | UInt16(c.y >> 3) << 5 | UInt16(c.z >> 3)
            let e = hist[k] ?? (0, .zero)
            hist[k] = (e.count + 1, e.sum &+ SIMD3(Int(c.x), Int(c.y), Int(c.z)))
        }
        struct Entry { var color: SIMD3<Int>; var count: Int }
        let entries = hist.values.map { Entry(color: $0.sum / $0.count, count: $0.count) }
        var boxes: [[Entry]] = [entries]
        while boxes.count < maxColors {
            // Split the box with the largest range * population.
            var bestBox = -1, bestScore = 0, bestAxis = 0
            for (bi, box) in boxes.enumerated() where box.count > 1 {
                var lo = SIMD3<Int>(repeating: 255), hi = SIMD3<Int>(repeating: 0)
                var pop = 0
                for e in box { lo = pointwiseMin(lo, e.color); hi = pointwiseMax(hi, e.color); pop += e.count }
                let r = hi &- lo
                let axis = r.x >= r.y && r.x >= r.z ? 0 : (r.y >= r.z ? 1 : 2)
                let score = r[axis] * Int(Double(pop).squareRoot())
                if score > bestScore { bestScore = score; bestBox = bi; bestAxis = axis }
            }
            guard bestBox >= 0 else { break }
            var box = boxes[bestBox]
            box.sort { $0.color[bestAxis] < $1.color[bestAxis] }
            let total = box.reduce(0) { $0 + $1.count }
            var acc = 0, split = 1
            for (i, e) in box.enumerated() { acc += e.count; if acc * 2 >= total { split = max(1, min(box.count - 1, i + 1)); break } }
            boxes[bestBox] = Array(box[..<split]); boxes.append(Array(box[split...]))
        }
        return boxes.map { box in
            let total = box.reduce(0) { $0 + $1.count }
            var s = SIMD3<Int>.zero
            for e in box { s &+= e.color &* e.count }
            let c = s / max(total, 1)
            return SIMD3(UInt8(clamp(c.x, 0, 255)), UInt8(clamp(c.y, 0, 255)), UInt8(clamp(c.z, 0, 255)))
        }
    }

    // MARK: LZW

    static func lzw(_ data: [UInt8], minCodeSize: Int) -> [UInt8] {
        let clear = 1 << minCodeSize, eoi = clear + 1
        var out: [UInt8] = []
        var bitBuf: UInt32 = 0, bitCnt: UInt32 = 0
        var codeSize = minCodeSize + 1
        func emit(_ code: Int) {
            bitBuf |= UInt32(code) << bitCnt; bitCnt += UInt32(codeSize)
            while bitCnt >= 8 { out.append(UInt8(bitBuf & 0xff)); bitBuf >>= 8; bitCnt -= 8 }
        }
        var dict: [Int: Int] = [:] // (prefix << 8 | byte) -> code
        var next = eoi + 1
        emit(clear)
        guard !data.isEmpty else { emit(eoi); if bitCnt > 0 { out.append(UInt8(bitBuf & 0xff)) }; return out }
        var prefix = Int(data[0])
        for i in 1..<data.count {
            let k = Int(data[i])
            let key = prefix << 8 | k
            if let c = dict[key] { prefix = c; continue }
            emit(prefix)
            if next < 4096 {
                dict[key] = next; next += 1
                if next > (1 << codeSize) && codeSize < 12 { codeSize += 1 }
            } else {
                emit(clear)
                dict.removeAll(keepingCapacity: true); next = eoi + 1; codeSize = minCodeSize + 1
            }
            prefix = k
        }
        emit(prefix)
        emit(eoi)
        if bitCnt > 0 { out.append(UInt8(bitBuf & 0xff)) }
        return out
    }
}

public enum GIFExporter {
    public static func export(_ renderer: FrameRenderer, progress: ((Double) -> Void)? = nil) -> Data {
        var enc = GIFEncoder(width: renderer.settings.width, height: renderer.settings.height,
                             frameDelay: 1 / renderer.settings.frameRate)
        var i = 0
        while let f = renderer.renderNext() {
            enc.addFrame(f); i += 1
            progress?(Double(i) / Double(renderer.frameCount))
        }
        return enc.finish()
    }
}
