import Foundation

/// 2D vector used throughout the engine. `SIMD2<Float>` is layout compatible
/// with Metal's `float2`, so vertex buffers can be uploaded without conversion.
public typealias Vec2 = SIMD2<Float>

public extension SIMD2 where Scalar == Float {
    @inlinable var length: Float { (x * x + y * y).squareRoot() }
    @inlinable var lengthSquared: Float { x * x + y * y }
    @inlinable func dot(_ o: Vec2) -> Float { x * o.x + y * o.y }
    @inlinable func cross(_ o: Vec2) -> Float { x * o.y - y * o.x }
    @inlinable var normalized: Vec2 { let l = length; return l > 1e-12 ? self / l : .zero }
    @inlinable var perpendicular: Vec2 { Vec2(-y, x) }
    @inlinable func distance(to o: Vec2) -> Float { (self - o).length }
    @inlinable func rotated(by radians: Float) -> Vec2 {
        let c = cos(radians), s = sin(radians)
        return Vec2(x * c - y * s, x * s + y * c)
    }
    @inlinable static func lerp(_ a: Vec2, _ b: Vec2, _ t: Float) -> Vec2 { a + (b - a) * t }
}

@inlinable public func lerp(_ a: Float, _ b: Float, _ t: Float) -> Float { a + (b - a) * t }
@inlinable public func clamp<T: Comparable>(_ v: T, _ lo: T, _ hi: T) -> T { min(max(v, lo), hi) }
@inlinable public func degreesToRadians(_ d: Float) -> Float { d * .pi / 180 }
@inlinable public func radiansToDegrees(_ r: Float) -> Float { r * 180 / .pi }

/// Axis-aligned rectangle.
public struct Rect: Codable, Hashable, Sendable {
    public var origin: Vec2
    public var size: Vec2

    public init(origin: Vec2, size: Vec2) { self.origin = origin; self.size = size }
    public init(x: Float, y: Float, width: Float, height: Float) {
        origin = Vec2(x, y); size = Vec2(width, height)
    }
    public static let zero = Rect(x: 0, y: 0, width: 0, height: 0)

    public var minX: Float { origin.x }
    public var minY: Float { origin.y }
    public var maxX: Float { origin.x + size.x }
    public var maxY: Float { origin.y + size.y }
    public var width: Float { size.x }
    public var height: Float { size.y }
    public var center: Vec2 { origin + size * 0.5 }
    public var isEmpty: Bool { size.x <= 0 || size.y <= 0 }

    public func contains(_ p: Vec2) -> Bool { p.x >= minX && p.x <= maxX && p.y >= minY && p.y <= maxY }
    public func insetBy(_ d: Float) -> Rect { Rect(x: minX + d, y: minY + d, width: width - 2 * d, height: height - 2 * d) }
    public func union(_ o: Rect) -> Rect {
        if isEmpty { return o }
        if o.isEmpty { return self }
        let x0 = min(minX, o.minX), y0 = min(minY, o.minY)
        return Rect(x: x0, y: y0, width: max(maxX, o.maxX) - x0, height: max(maxY, o.maxY) - y0)
    }
    public func intersects(_ o: Rect) -> Bool {
        !(o.minX > maxX || o.maxX < minX || o.minY > maxY || o.maxY < minY)
    }

    /// Bounding box of a point set (zero rect when empty).
    public static func bounding<S: Sequence>(_ points: S) -> Rect where S.Element == Vec2 {
        var it = points.makeIterator()
        guard let first = it.next() else { return .zero }
        var lo = first, hi = first
        while let p = it.next() { lo = pointwiseMin(lo, p); hi = pointwiseMax(hi, p) }
        return Rect(origin: lo, size: hi - lo)
    }
}


/// 2D affine transform: | a c tx |
///                      | b d ty |
public struct Affine2D: Codable, Hashable, Sendable {
    public var a: Float, b: Float, c: Float, d: Float, tx: Float, ty: Float

    public init(a: Float, b: Float, c: Float, d: Float, tx: Float, ty: Float) {
        self.a = a; self.b = b; self.c = c; self.d = d; self.tx = tx; self.ty = ty
    }
    public static let identity = Affine2D(a: 1, b: 0, c: 0, d: 1, tx: 0, ty: 0)
    public static func translation(_ t: Vec2) -> Affine2D { Affine2D(a: 1, b: 0, c: 0, d: 1, tx: t.x, ty: t.y) }
    public static func scale(_ s: Float) -> Affine2D { Affine2D(a: s, b: 0, c: 0, d: s, tx: 0, ty: 0) }
    public static func rotation(_ r: Float) -> Affine2D {
        let co = cos(r), si = sin(r)
        return Affine2D(a: co, b: si, c: -si, d: co, tx: 0, ty: 0)
    }

    @inlinable public func apply(_ p: Vec2) -> Vec2 { Vec2(a * p.x + c * p.y + tx, b * p.x + d * p.y + ty) }
    @inlinable public func applyVector(_ v: Vec2) -> Vec2 { Vec2(a * v.x + c * v.y, b * v.x + d * v.y) }

    /// `self.concatenating(o)` applies `o` first, then `self`.
    public func concatenating(_ o: Affine2D) -> Affine2D {
        Affine2D(a: a * o.a + c * o.b, b: b * o.a + d * o.b,
                 c: a * o.c + c * o.d, d: b * o.c + d * o.d,
                 tx: a * o.tx + c * o.ty + tx, ty: b * o.tx + d * o.ty + ty)
    }
    public var inverted: Affine2D {
        let det = a * d - b * c
        guard abs(det) > 1e-12 else { return .identity }
        let id = 1 / det
        return Affine2D(a: d * id, b: -b * id, c: -c * id, d: a * id,
                        tx: (c * ty - d * tx) * id, ty: (b * tx - a * ty) * id)
    }
    public var scaleFactor: Float { (abs(a * d - b * c)).squareRoot() }
}

/// Geometry helpers shared by the mesh and deformer code.
public enum Geometry {
    /// Barycentric coordinates of `p` in triangle (a, b, c). Returns nil for degenerate triangles.
    public static func barycentric(_ p: Vec2, _ a: Vec2, _ b: Vec2, _ c: Vec2) -> SIMD3<Float>? {
        let v0 = b - a, v1 = c - a, v2 = p - a
        let den = v0.x * v1.y - v1.x * v0.y
        guard abs(den) > 1e-12 else { return nil }
        let v = (v2.x * v1.y - v1.x * v2.y) / den
        let w = (v0.x * v2.y - v2.x * v0.y) / den
        return SIMD3(1 - v - w, v, w)
    }

    public static func pointInTriangle(_ p: Vec2, _ a: Vec2, _ b: Vec2, _ c: Vec2, epsilon: Float = 1e-5) -> Bool {
        guard let bc = barycentric(p, a, b, c) else { return false }
        return bc.x >= -epsilon && bc.y >= -epsilon && bc.z >= -epsilon
    }

    /// Signed area * 2 (positive when counter-clockwise in a y-up system).
    public static func orient(_ a: Vec2, _ b: Vec2, _ c: Vec2) -> Float { (b - a).cross(c - a) }

    public static func distanceToSegment(_ p: Vec2, _ a: Vec2, _ b: Vec2) -> Float {
        let ab = b - a
        let l2 = ab.lengthSquared
        if l2 < 1e-12 { return p.distance(to: a) }
        let t = clamp((p - a).dot(ab) / l2, 0, 1)
        return p.distance(to: a + ab * t)
    }

    public static func pointInPolygon(_ p: Vec2, _ poly: [Vec2]) -> Bool {
        guard poly.count >= 3 else { return false }
        var inside = false
        var j = poly.count - 1
        for i in 0..<poly.count {
            let pi = poly[i], pj = poly[j]
            if (pi.y > p.y) != (pj.y > p.y),
               p.x < (pj.x - pi.x) * (p.y - pi.y) / (pj.y - pi.y) + pi.x {
                inside.toggle()
            }
            j = i
        }
        return inside
    }
}
