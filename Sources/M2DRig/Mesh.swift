import M2DCore

/// Triangle mesh in canvas (rest) space with texture coordinates.
public struct Mesh: Codable, Hashable, Sendable {
    public var vertices: [Vec2]
    public var uvs: [Vec2]
    /// Triangle vertex indices, three per triangle.
    public var indices: [UInt32]

    public init(vertices: [Vec2] = [], uvs: [Vec2] = [], indices: [UInt32] = []) {
        self.vertices = vertices; self.uvs = uvs; self.indices = indices
    }

    public var vertexCount: Int { vertices.count }
    public var triangleCount: Int { indices.count / 3 }

    public func triangle(_ t: Int) -> (Int, Int, Int) {
        (Int(indices[t * 3]), Int(indices[t * 3 + 1]), Int(indices[t * 3 + 2]))
    }

    /// Rectangle quad (two triangles) covering `rect`, mapping the full texture.
    public static func quad(_ rect: Rect) -> Mesh {
        Mesh(vertices: [rect.origin, Vec2(rect.maxX, rect.minY), Vec2(rect.maxX, rect.maxY), Vec2(rect.minX, rect.maxY)],
             uvs: [Vec2(0, 0), Vec2(1, 0), Vec2(1, 1), Vec2(0, 1)],
             indices: [0, 1, 2, 0, 2, 3])
    }

    /// Unique undirected edges.
    public var edges: [(Int, Int)] {
        var seen = Set<UInt64>(), out: [(Int, Int)] = []
        for t in 0..<triangleCount {
            let (a, b, c) = triangle(t)
            for (p, q) in [(a, b), (b, c), (c, a)] {
                let lo = min(p, q), hi = max(p, q)
                if seen.insert(UInt64(lo) << 32 | UInt64(hi)).inserted { out.append((lo, hi)) }
            }
        }
        return out
    }

    /// Edges used by exactly one triangle (the mesh outline).
    public var boundaryEdges: [(Int, Int)] {
        var count: [UInt64: Int] = [:], dir: [UInt64: (Int, Int)] = [:]
        for t in 0..<triangleCount {
            let (a, b, c) = triangle(t)
            for (p, q) in [(a, b), (b, c), (c, a)] {
                let key = UInt64(min(p, q)) << 32 | UInt64(max(p, q))
                count[key, default: 0] += 1; dir[key] = (p, q)
            }
        }
        return count.filter { $0.value == 1 }.compactMap { dir[$0.key] }
    }

    /// UV for a canvas position given where the texture is placed on the canvas.
    public static func uv(for p: Vec2, textureRect r: Rect) -> Vec2 {
        Vec2(r.width > 0 ? (p.x - r.minX) / r.width : 0, r.height > 0 ? (p.y - r.minY) / r.height : 0)
    }

    public mutating func recomputeUVs(textureRect: Rect) {
        uvs = vertices.map { Mesh.uv(for: $0, textureRect: textureRect) }
    }

    // MARK: Queries

    public func nearestVertex(to p: Vec2, positions: [Vec2]? = nil, within radius: Float) -> Int? {
        let pts = positions ?? vertices
        var best: Int?, bestD = radius * radius
        for (i, v) in pts.enumerated() {
            let d = (v - p).lengthSquared
            if d <= bestD { bestD = d; best = i }
        }
        return best
    }

    public func triangle(containing p: Vec2, positions: [Vec2]? = nil) -> Int? {
        let pts = positions ?? vertices
        for t in 0..<triangleCount {
            let (a, b, c) = triangle(t)
            if Geometry.pointInTriangle(p, pts[a], pts[b], pts[c]) { return t }
        }
        return nil
    }

    public func vertices(inPolygon poly: [Vec2], positions: [Vec2]? = nil) -> Set<Int> {
        let pts = positions ?? vertices
        return Set(pts.indices.filter { Geometry.pointInPolygon(pts[$0], poly) })
    }

    public func vertices(inRect r: Rect, positions: [Vec2]? = nil) -> Set<Int> {
        let pts = positions ?? vertices
        return Set(pts.indices.filter { r.contains(pts[$0]) })
    }

    // MARK: Editing. Each operation reports how vertices changed so keyforms can follow.

    /// Describes how to derive per-vertex data (e.g. keyform offsets) after an edit.
    public enum VertexSource: Hashable, Sendable {
        case existing(Int)
        /// New vertex as a weighted combination of old vertices.
        case interpolated([Int], [Float])
        case new
    }

    /// Insert a vertex. Inside a triangle it splits that triangle in three;
    /// otherwise it is attached to the nearest outline edge.
    @discardableResult
    public mutating func addVertex(_ p: Vec2, textureRect: Rect) -> (index: Int, source: VertexSource) {
        let idx = vertices.count
        if let t = triangle(containing: p) {
            let (a, b, c) = triangle(t)
            let bc = Geometry.barycentric(p, vertices[a], vertices[b], vertices[c]) ?? SIMD3(1, 0, 0)
            vertices.append(p); uvs.append(Mesh.uv(for: p, textureRect: textureRect))
            let i = UInt32(idx)
            indices.replaceSubrange(t * 3..<t * 3 + 3, with: [UInt32(a), UInt32(b), i])
            indices += [UInt32(b), UInt32(c), i, UInt32(c), UInt32(a), i]
            return (idx, .interpolated([a, b, c], [bc.x, bc.y, bc.z]))
        }
        vertices.append(p); uvs.append(Mesh.uv(for: p, textureRect: textureRect))
        var best: (Int, Int)?, bestD = Float.greatestFiniteMagnitude
        for (a, b) in boundaryEdges {
            let d = Geometry.distanceToSegment(p, vertices[a], vertices[b])
            if d < bestD { bestD = d; best = (a, b) }
        }
        if let (a, b) = best {
            indices += [UInt32(a), UInt32(idx), UInt32(b)]
            let ab = vertices[b] - vertices[a]
            let t = ab.lengthSquared > 0 ? clamp((p - vertices[a]).dot(ab) / ab.lengthSquared, 0, 1) : 0
            return (idx, .interpolated([a, b], [1 - t, t]))
        }
        return (idx, .new)
    }

    /// Remove vertices and fill the holes left behind. Returns the old index of each remaining vertex.
    @discardableResult
    public mutating func removeVertices(_ remove: Set<Int>) -> [Int] {
        guard !remove.isEmpty else { return Array(vertices.indices) }
        var kept: [UInt32] = [], dropped: [(Int, Int, Int)] = []
        for t in 0..<triangleCount {
            let tri = triangle(t)
            if remove.contains(tri.0) || remove.contains(tri.1) || remove.contains(tri.2) { dropped.append(tri) }
            else { kept += [UInt32(tri.0), UInt32(tri.1), UInt32(tri.2)] }
        }
        // Holes: boundary loops of the dropped region that avoid removed vertices.
        var edgeCount: [UInt64: Int] = [:]
        var directed: [(Int, Int)] = []
        for (a, b, c) in dropped {
            for (p, q) in [(a, b), (b, c), (c, a)] {
                directed.append((p, q))
                edgeCount[UInt64(min(p, q)) << 32 | UInt64(max(p, q)), default: 0] += 1
            }
        }
        // Closed loops of dropped-region edges that avoid removed vertices are interior
        // holes (removed vertex was surrounded); re-triangulate those. Open chains mean
        // the vertex was on the outline, so the outline simply moves inwards.
        var next: [Int: Int] = [:]
        for (p, q) in directed where !remove.contains(p) && !remove.contains(q) {
            let key = UInt64(min(p, q)) << 32 | UInt64(max(p, q))
            if edgeCount[key] == 1 { next[p] = q }
        }
        var visited = Set<Int>()
        for start in next.keys where !visited.contains(start) {
            var loop: [Int] = [], cur = start
            while let n = next[cur], !visited.contains(cur) {
                visited.insert(cur); loop.append(cur); cur = n
            }
            if cur == start, loop.count >= 3 {
                kept += Mesh.earClip(loop, vertices).flatMap { [UInt32($0.0), UInt32($0.1), UInt32($0.2)] }
            }
        }
        // Compact vertex arrays.
        var map = [Int](repeating: -1, count: vertices.count)
        var oldIndex: [Int] = []
        var nv: [Vec2] = [], nuv: [Vec2] = []
        for i in vertices.indices where !remove.contains(i) {
            map[i] = nv.count; oldIndex.append(i); nv.append(vertices[i]); nuv.append(uvs[i])
        }
        vertices = nv; uvs = nuv
        indices = kept.map { UInt32(map[Int($0)]) }
        return oldIndex
    }

    public mutating func addTriangle(_ a: Int, _ b: Int, _ c: Int) {
        guard a != b, b != c, a != c, [a, b, c].allSatisfy({ $0 < vertices.count }) else { return }
        let key = Set([a, b, c])
        for t in 0..<triangleCount { let tr = triangle(t); if Set([tr.0, tr.1, tr.2]) == key { return } }
        // Keep consistent winding with the rest of the mesh.
        if Geometry.orient(vertices[a], vertices[b], vertices[c]) < 0 { indices += [UInt32(a), UInt32(c), UInt32(b)] }
        else { indices += [UInt32(a), UInt32(b), UInt32(c)] }
    }

    public mutating func removeTriangles(_ ts: Set<Int>) {
        var out: [UInt32] = []
        for t in 0..<triangleCount where !ts.contains(t) { out += indices[t * 3..<t * 3 + 3] }
        indices = out
    }

    /// Split each selected triangle into four (midpoint subdivision). Neighbouring
    /// triangles are split as needed so the mesh stays watertight.
    @discardableResult
    public mutating func subdivide(_ ts: Set<Int>? = nil, textureRect: Rect) -> [VertexSource] {
        var targets = ts ?? Set(0..<triangleCount)
        func key(_ a: Int, _ b: Int) -> UInt64 { UInt64(min(a, b)) << 32 | UInt64(max(a, b)) }
        // Promote triangles with two or more split edges until stable.
        var changed = true
        while changed {
            changed = false
            var split = Set<UInt64>()
            for t in targets { let (a, b, c) = triangle(t); split.formUnion([key(a, b), key(b, c), key(c, a)]) }
            for t in 0..<triangleCount where !targets.contains(t) {
                let (a, b, c) = triangle(t)
                let n = [key(a, b), key(b, c), key(c, a)].filter(split.contains).count
                if n >= 2 { targets.insert(t); changed = true }
            }
        }
        var sources: [VertexSource] = vertices.indices.map { .existing($0) }
        var mids: [UInt64: Int] = [:]
        func mid(_ a: Int, _ b: Int) -> Int {
            if let m = mids[key(a, b)] { return m }
            let p = (vertices[a] + vertices[b]) * 0.5
            vertices.append(p); uvs.append(Mesh.uv(for: p, textureRect: textureRect))
            sources.append(.interpolated([a, b], [0.5, 0.5]))
            mids[key(a, b)] = vertices.count - 1
            return vertices.count - 1
        }
        for t in targets { let (a, b, c) = triangle(t); _ = mid(a, b); _ = mid(b, c); _ = mid(c, a) }
        var out: [UInt32] = []
        for t in 0..<triangleCount {
            let (a, b, c) = triangle(t)
            if targets.contains(t) {
                let ab = mid(a, b), bc = mid(b, c), ca = mid(c, a)
                out += [a, ab, ca, ab, b, bc, ca, bc, c, ab, bc, ca].map { UInt32($0) }
            } else if let (p, q, r) = [(a, b, c), (b, c, a), (c, a, b)].first(where: { mids[key($0.0, $0.1)] != nil }) {
                let m = mids[key(p, q)]!
                out += [p, m, r, m, q, r].map { UInt32($0) }
            } else {
                out += [UInt32(a), UInt32(b), UInt32(c)]
            }
        }
        indices = out
        return sources
    }

    /// Rebuild triangles with a Delaunay triangulation of the current vertices,
    /// keeping only triangles accepted by `keep` (e.g. inside the artwork).
    public mutating func retriangulate(keep: ((Vec2, Vec2, Vec2) -> Bool)? = nil) {
        let tris = Delaunay.triangulate(vertices)
        var out: [UInt32] = []
        for (a, b, c) in tris where keep?(vertices[a], vertices[b], vertices[c]) ?? true {
            out += [UInt32(a), UInt32(b), UInt32(c)]
        }
        indices = out
    }

    /// Ear-clipping triangulation of a simple polygon given as vertex indices.
    static func earClip(_ loop: [Int], _ pts: [Vec2]) -> [(Int, Int, Int)] {
        var poly = loop
        var area: Float = 0
        for i in poly.indices { let a = pts[poly[i]], b = pts[poly[(i + 1) % poly.count]]; area += a.cross(b) }
        let ccw = area > 0
        var out: [(Int, Int, Int)] = []
        var guardCount = 0
        while poly.count > 3, guardCount < 10_000 {
            guardCount += 1
            var clipped = false
            for i in poly.indices {
                let ia = poly[(i + poly.count - 1) % poly.count], ib = poly[i], ic = poly[(i + 1) % poly.count]
                let o = Geometry.orient(pts[ia], pts[ib], pts[ic])
                guard ccw ? o > 0 : o < 0 else { continue }
                var contains = false
                for j in poly where j != ia && j != ib && j != ic {
                    if Geometry.pointInTriangle(pts[j], pts[ia], pts[ib], pts[ic], epsilon: -1e-6) { contains = true; break }
                }
                if contains { continue }
                out.append((ia, ib, ic)); poly.remove(at: i); clipped = true; break
            }
            if !clipped { break }
        }
        if poly.count == 3 { out.append((poly[0], poly[1], poly[2])) }
        return out
    }
}
