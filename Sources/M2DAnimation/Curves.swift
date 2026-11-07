import Foundation
import M2DCore

/// How a keyframe interpolates towards the next one.
public enum Interpolation: String, Codable, Hashable, Sendable, CaseIterable {
    case constant, linear, bezier, easeIn, easeOut, easeInOut

    public var displayName: String {
        switch self {
        case .constant: return "Step"
        case .linear: return "Linear"
        case .bezier: return "Bezier"
        case .easeIn: return "Ease In"
        case .easeOut: return "Ease Out"
        case .easeInOut: return "Ease In-Out"
        }
    }
}

/// Bezier handle relative to its keyframe: `x` is a fraction (0–1) of the
/// segment duration, `y` a value offset.
public struct CurveHandle: Codable, Hashable, Sendable {
    public var x: Float
    public var y: Float
    public init(x: Float = 1.0 / 3, y: Float = 0) { self.x = x; self.y = y }
}

public struct Keyframe: Codable, Hashable, Sendable, Identifiable {
    public var id: ObjectID
    public var time: Double
    public var value: Float
    /// Interpolation from this key to the next one.
    public var interpolation: Interpolation
    public var outHandle: CurveHandle
    public var inHandle: CurveHandle

    public init(id: ObjectID = IDGenerator.make("key"), time: Double, value: Float, interpolation: Interpolation = .easeInOut,
                outHandle: CurveHandle = CurveHandle(), inHandle: CurveHandle = CurveHandle()) {
        self.id = id; self.time = time; self.value = value; self.interpolation = interpolation
        self.outHandle = outHandle; self.inHandle = inHandle
    }
}

public enum CurveMath {
    /// Evaluate the segment between two keys at absolute time `t`.
    public static func segment(_ k0: Keyframe, _ k1: Keyframe, at t: Double) -> Float {
        let dt = k1.time - k0.time
        guard dt > 1e-9 else { return k1.value }
        let u = Float(clamp((t - k0.time) / dt, 0, 1))
        let dv = k1.value - k0.value
        switch k0.interpolation {
        case .constant: return u >= 1 ? k1.value : k0.value
        case .linear: return k0.value + dv * u
        case .easeIn: return k0.value + dv * bezierY(u, 0.42, 0, 1, 1)
        case .easeOut: return k0.value + dv * bezierY(u, 0, 0, 0.58, 1)
        case .easeInOut: return k0.value + dv * bezierY(u, 0.42, 0, 0.58, 1)
        case .bezier:
            // Handles in normalized time, absolute value offsets.
            let x1 = clamp(k0.outHandle.x, 0, 1), x2 = 1 - clamp(k1.inHandle.x, 0, 1)
            let s = solveBezierX(u, x1, x2)
            let y0 = k0.value, y1 = k0.value + k0.outHandle.y, y2 = k1.value + k1.inHandle.y, y3 = k1.value
            let m = 1 - s
            return m * m * m * y0 + 3 * m * m * s * y1 + 3 * m * s * s * y2 + s * s * s * y3
        }
    }

    /// CSS-style cubic bezier easing from (0,0) to (1,1).
    public static func bezierY(_ x: Float, _ x1: Float, _ y1: Float, _ x2: Float, _ y2: Float) -> Float {
        let s = solveBezierX(x, x1, x2)
        let m = 1 - s
        return 3 * m * m * s * y1 + 3 * m * s * s * y2 + s * s * s
    }

    /// Parameter s at which the bezier x(s) with control x's (0, x1, x2, 1) equals x.
    public static func solveBezierX(_ x: Float, _ x1: Float, _ x2: Float) -> Float {
        func bx(_ s: Float) -> Float { let m = 1 - s; return 3 * m * m * s * x1 + 3 * m * s * s * x2 + s * s * s }
        func dbx(_ s: Float) -> Float { let m = 1 - s; return 3 * m * m * x1 + 6 * m * s * (x2 - x1) + 3 * s * s * (1 - x2) }
        var s = x
        for _ in 0..<8 {
            let e = bx(s) - x
            if abs(e) < 1e-6 { return s }
            let d = dbx(s)
            if abs(d) < 1e-6 { break }
            s = clamp(s - e / d, 0, 1)
        }
        var lo: Float = 0, hi: Float = 1
        s = x
        for _ in 0..<40 {
            let v = bx(s)
            if abs(v - x) < 1e-6 { break }
            if v < x { lo = s } else { hi = s }
            s = (lo + hi) / 2
        }
        return s
    }
}
