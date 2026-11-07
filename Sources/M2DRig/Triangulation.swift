import Foundation
import M2DCore

/// Bowyer–Watson Delaunay triangulation (double precision predicates).
public enum Delaunay {
    public static func triangulate(_ points: [Vec2]) -> [(Int, Int, Int)] {
        let n = points.count
        guard n >= 3 else { return [] }
        let pts = points.map { SIMD2<Double>(Double($0.x), Double($0.y)) }
        var lo = pts[0], hi = pts[0]
        for p in pts { lo = pointwiseMin(lo, p); hi = pointwiseMax(hi, p) }
        let d = max(hi.x - lo.x, hi.y - lo.y) * 20 + 1
        let mid = (lo + hi) * 0.5
        var all = pts
        all.append(SIMD2(mid.x - d, mid.y - d)); all.append(SIMD2(mid.x + d, mid.y - d)); all.append(SIMD2(mid.x, mid.y + d))

        struct Tri { var a: Int, b: Int, c: Int; var cx: Double, cy: Double, r2: Double }
        func make(_ a: Int, _ b: Int, _ c: Int) -> Tri? {
            let A = all[a], B = all[b], C = all[c]
            let dd = 2 * (A.x * (B.y - C.y) + B.x * (C.y - A.y) + C.x * (A.y - B.y))
            guard abs(dd) > 1e-18 else { return nil }
            let a2 = A.x * A.x + A.y * A.y, b2 = B.x * B.x + B.y * B.y, c2 = C.x * C.x + C.y * C.y
            let ux = (a2 * (B.y - C.y) + b2 * (C.y - A.y) + c2 * (A.y - B.y)) / dd
            let uy = (a2 * (C.x - B.x) + b2 * (A.x - C.x) + c2 * (B.x - A.x)) / dd
            let r2 = (A.x - ux) * (A.x - ux) + (A.y - uy) * (A.y - uy)
            return Tri(a: a, b: b, c: c, cx: ux, cy: uy, r2: r2)
        }
        var tris: [Tri] = [make(n, n + 1, n + 2)!]
        // Insert points in spatially coherent order for speed.
        let order = (0..<n).sorted { (pts[$0].x + pts[$0].y * 0.5) < (pts[$1].x + pts[$1].y * 0.5) }
        var seen = Set<SIMD2<Double>>()
        for i in order {
            let p = all[i]
            guard seen.insert(p).inserted else { continue } // skip duplicates
            var bad: [Int] = []
            for (ti, t) in tris.enumerated() {
                let dx = p.x - t.cx, dy = p.y - t.cy
                if dx * dx + dy * dy < t.r2 * (1 - 1e-12) { bad.append(ti) }
            }
            var edgeCount: [UInt64: Int] = [:]
            var edgeDir: [UInt64: (Int, Int)] = [:]
            for ti in bad {
                let t = tris[ti]
                for (u, v) in [(t.a, t.b), (t.b, t.c), (t.c, t.a)] {
                    let key = UInt64(min(u, v)) << 32 | UInt64(max(u, v))
                    edgeCount[key, default: 0] += 1; edgeDir[key] = (u, v)
                }
            }
            for ti in bad.reversed() { tris.swapAt(ti, tris.count - 1); tris.removeLast() }
            for (key, c) in edgeCount where c == 1 {
                let (u, v) = edgeDir[key]!
                if let t = make(u, v, i) { tris.append(t) }
            }
        }
        var out: [(Int, Int, Int)] = []
        for t in tris where t.a < n && t.b < n && t.c < n {
            // Normalize winding to counter-clockwise (in y-down canvas space this renders consistently).
            let A = all[t.a], B = all[t.b], C = all[t.c]
            let o = (B.x - A.x) * (C.y - A.y) - (B.y - A.y) * (C.x - A.x)
            if abs(o) < 1e-9 { continue }
            out.append(o > 0 ? (t.a, t.b, t.c) : (t.a, t.c, t.b))
        }
        return out
    }
}

/// Builds meshes that follow the opaque area of a layer.
public enum MeshGenerator {
    public struct Settings: Codable, Hashable, Sendable {
        /// Approximate distance between interior vertices, in canvas pixels.
        public var spacing: Float = 40
        /// Distance the outline is pushed outside the artwork, in pixels.
        public var margin: Float = 4
        /// Alpha (0–255) above which a pixel counts as artwork.
        public var alphaThreshold: UInt8 = 8
        /// Outline vertex spacing relative to `spacing`.
        public var outlineDensity: Float = 0.6
        public init(spacing: Float = 40, margin: Float = 4, alphaThreshold: UInt8 = 8) {
            self.spacing = spacing; self.margin = margin; self.alphaThreshold = alphaThreshold
        }
    }

    /// Coverage mask (true = artwork, dilated by margin) at the image's resolution.
    public struct Coverage {
        public let width: Int, height: Int
        public var bits: [Bool]
        public func at(_ x: Int, _ y: Int) -> Bool { x >= 0 && y >= 0 && x < width && y < height && bits[y * width + x] }
    }

    public static func coverage(_ image: RGBAImage, threshold: UInt8, dilate radius: Int) -> Coverage {
        let w = image.width, h = image.height
        var bits = [Bool](repeating: false, count: w * h)
        for i in 0..<(w * h) { bits[i] = image.pixels[i * 4 + 3] > threshold }
        if radius > 0 {
            // Separable square dilation.
            var tmp = bits
            for y in 0..<h {
                var last = -1_000_000
                for x in 0..<w { if bits[y * w + x] { last = x }; if x - last <= radius { tmp[y * w + x] = true } }
                last = 1_000_000
                for x in stride(from: w - 1, through: 0, by: -1) { if bits[y * w + x] { last = x }; if last - x <= radius { tmp[y * w + x] = true } }
            }
            var out = tmp
            for x in 0..<w {
                var last = -1_000_000
                for y in 0..<h { if tmp[y * w + x] { last = y }; if y - last <= radius { out[y * w + x] = true } }
                last = 1_000_000
                for y in stride(from: h - 1, through: 0, by: -1) { if tmp[y * w + x] { last = y }; if last - y <= radius { out[y * w + x] = true } }
            }
            bits = out
        }
        return Coverage(width: w, height: h, bits: bits)
    }

    /// Generate a mesh for a texture placed at `rect` on the canvas.
    /// The image may be larger than `rect` scale-wise; positions are mapped proportionally.
    public static func generate(image: RGBAImage, rect: Rect, settings: Settings = Settings()) -> Mesh {
        let sx = rect.width / Float(max(image.width, 1)), sy = rect.height / Float(max(image.height, 1))
        let pxScale = max(sx, sy)
        let margin = Int((settings.margin / pxScale).rounded())
        let cov = coverage(image, threshold: settings.alphaThreshold, dilate: max(margin, 1))
        let spacingPx = max(4, settings.spacing / pxScale)
        let outlineSpacing = max(2, spacingPx * settings.outlineDensity)

        // Outline samples: coverage pixels with an uncovered 4-neighbour, thinned on a hash grid.
        var points: [SIMD2<Float>] = []
        var boundary: [SIMD2<Float>] = []
        for y in 0..<cov.height {
            for x in 0..<cov.width where cov.at(x, y) {
                if !cov.at(x - 1, y) || !cov.at(x + 1, y) || !cov.at(x, y - 1) || !cov.at(x, y + 1) {
                    // Push the sample to the pixel's outer edge.
                    var off = SIMD2<Float>(0.5, 0.5)
                    if !cov.at(x - 1, y) { off.x = 0 } else if !cov.at(x + 1, y) { off.x = 1 }
                    if !cov.at(x, y - 1) { off.y = 0 } else if !cov.at(x, y + 1) { off.y = 1 }
                    boundary.append(SIMD2(Float(x), Float(y)) + off)
                }
            }
        }
        // Thinning with a spatial hash keyed by outline spacing.
        var hash: [SIMD2<Int32>: [SIMD2<Float>]] = [:]
        func key(_ p: SIMD2<Float>, _ s: Float) -> SIMD2<Int32> { SIMD2(Int32((p.x / s).rounded(.down)), Int32((p.y / s).rounded(.down))) }
        func farEnough(_ p: SIMD2<Float>, _ s: Float) -> Bool {
            let k = key(p, s)
            for dy in -1...1 { for dx in -1...1 {
                if let list = hash[k &+ SIMD2(Int32(dx), Int32(dy))], list.contains(where: { ($0 - p).length < s }) { return false }
            }}
            return true
        }
        for p in boundary where farEnough(p, outlineSpacing) { hash[key(p, outlineSpacing), default: []].append(p); points.append(p) }

        // Interior samples on a staggered grid, kept away from the outline.
        var row = 0
        var y = spacingPx * 0.5
        while y < Float(cov.height) {
            var x = spacingPx * 0.5 + (row % 2 == 1 ? spacingPx * 0.5 : 0)
            while x < Float(cov.width) {
                let p = SIMD2<Float>(x, y)
                if cov.at(Int(x), Int(y)) && farEnough(p, spacingPx * 0.55) {
                    hash[key(p, outlineSpacing), default: []].append(p); points.append(p)
                }
                x += spacingPx
            }
            y += spacingPx * 0.866; row += 1
        }
        guard points.count >= 3 else { return Mesh.quad(rect) }

        let tris = Delaunay.triangulate(points)
        let maxEdge = max(spacingPx, outlineSpacing) * 2.6
        var indices: [UInt32] = []
        for (a, b, c) in tris {
            let pa = points[a], pb = points[b], pc = points[c]
            if (pa - pb).length > maxEdge || (pb - pc).length > maxEdge || (pc - pa).length > maxEdge { continue }
            // Keep triangles whose centroid and edge midpoints lie on artwork coverage.
            let centroid: Vec2 = (pa + pb + pc) / 3
            let probes: [Vec2] = [centroid, (pa + pb) * 0.5, (pb + pc) * 0.5, (pc + pa) * 0.5]
            var inside = 0
            for q in probes where cov.at(Int(q.x), Int(q.y)) { inside += 1 }
            if inside >= 3 { indices += [UInt32(a), UInt32(b), UInt32(c)] }
        }
        // Drop vertices no triangle uses.
        var used = [Bool](repeating: false, count: points.count)
        for i in indices { used[Int(i)] = true }
        var remap = [Int](repeating: -1, count: points.count)
        var verts: [Vec2] = [], uvs: [Vec2] = []
        for i in points.indices where used[i] {
            remap[i] = verts.count
            let p = points[i]
            uvs.append(Vec2(p.x / Float(cov.width), p.y / Float(cov.height)))
            verts.append(Vec2(rect.minX + p.x * sx, rect.minY + p.y * sy))
        }
        guard !verts.isEmpty else { return Mesh.quad(rect) }
        return Mesh(vertices: verts, uvs: uvs, indices: indices.map { UInt32(remap[Int($0)]) })
    }

    /// Regular grid mesh over a rectangle.
    public static func grid(rect: Rect, columns: Int, rows: Int) -> Mesh {
        var v: [Vec2] = [], uv: [Vec2] = [], idx: [UInt32] = []
        for j in 0...rows { for i in 0...columns {
            let u = Float(i) / Float(columns), t = Float(j) / Float(rows)
            v.append(Vec2(rect.minX + u * rect.width, rect.minY + t * rect.height)); uv.append(Vec2(u, t))
        }}
        let stride = columns + 1
        for j in 0..<rows { for i in 0..<columns {
            let a = UInt32(j * stride + i), b = a + 1, c = a + UInt32(stride), d = c + 1
            idx += [a, b, d, a, d, c]
        }}
        return Mesh(vertices: v, uvs: uv, indices: idx)
    }
}
