import Foundation
import M2DCore

/// Lattice deformer: a (columns+1) x (rows+1) grid of control points over a
/// rest rectangle. Children are mapped through bilinear interpolation of the
/// deformed lattice cell they fall in (linear extrapolation outside).
public struct WarpDeformer: Codable, Hashable, Sendable {
    public var rect: Rect
    public var columns: Int
    public var rows: Int
    public var keyforms: KeyformGrid<WarpForm>

    public init(rect: Rect, columns: Int = 4, rows: Int = 4) {
        self.rect = rect; self.columns = max(1, columns); self.rows = max(1, rows)
        keyforms = KeyformGrid(rest: WarpForm(points: WarpDeformer.restPoints(rect: rect, columns: self.columns, rows: self.rows)))
    }

    public var pointCount: Int { (columns + 1) * (rows + 1) }
    public var restPoints: [Vec2] { Self.restPoints(rect: rect, columns: columns, rows: rows) }

    public static func restPoints(rect: Rect, columns: Int, rows: Int) -> [Vec2] {
        var pts: [Vec2] = []
        pts.reserveCapacity((columns + 1) * (rows + 1))
        for j in 0...rows { for i in 0...columns {
            pts.append(Vec2(rect.minX + rect.width * Float(i) / Float(columns), rect.minY + rect.height * Float(j) / Float(rows)))
        }}
        return pts
    }

    /// Map a rest-space point through a lattice.
    @inlinable public func map(_ p: Vec2, points: [Vec2]) -> Vec2 {
        let u = rect.width > 0 ? (p.x - rect.minX) / rect.width * Float(columns) : 0
        let v = rect.height > 0 ? (p.y - rect.minY) / rect.height * Float(rows) : 0
        let i = min(max(Int(u.rounded(.down)), 0), columns - 1)
        let j = min(max(Int(v.rounded(.down)), 0), rows - 1)
        let fu = u - Float(i), fv = v - Float(j)
        let s = columns + 1
        let p00 = points[j * s + i], p10 = points[j * s + i + 1]
        let p01 = points[(j + 1) * s + i], p11 = points[(j + 1) * s + i + 1]
        let top = p00 + (p10 - p00) * fu
        let bottom = p01 + (p11 - p01) * fu
        return top + (bottom - top) * fv
    }

    /// Change lattice resolution, resampling every keyform so the deformation is preserved.
    public mutating func resample(columns newC: Int, rows newR: Int) {
        let c = max(1, newC), r = max(1, newR)
        let newRest = Self.restPoints(rect: rect, columns: c, rows: r)
        let old = self
        keyforms.mapForms { form in
            form.points = newRest.map { old.map($0, points: form.points) }
        }
        columns = c; rows = r
    }
}

/// Rigid deformer: rotates and scales its children about a pivot.
public struct RotationDeformer: Codable, Hashable, Sendable {
    /// Pivot in the parent's rest space. Children are bound relative to it.
    public var restOrigin: Vec2
    /// Visual length of the rotation handle in the editor.
    public var handleLength: Float
    public var keyforms: KeyformGrid<RotationForm>

    public init(origin: Vec2, handleLength: Float = 120) {
        restOrigin = origin; self.handleLength = handleLength
        keyforms = KeyformGrid(rest: RotationForm(origin: origin))
    }

    @inlinable public func map(_ p: Vec2, form: RotationForm) -> Vec2 {
        form.origin + (p - restOrigin).rotated(by: degreesToRadians(form.angle)) * form.scale
    }

    /// Move the pivot without changing how children currently look.
    public mutating func movePivot(to p: Vec2) {
        let d = p - restOrigin
        restOrigin = p
        keyforms.mapForms { f in
            // Keep children fixed: new origin is where the old transform sends the new pivot.
            f.origin += d.rotated(by: degreesToRadians(f.angle)) * f.scale
        }
    }
}

public struct Deformer: Codable, Hashable, Identifiable, Sendable {
    public enum Kind: Hashable, Sendable {
        case warp(WarpDeformer)
        case rotation(RotationDeformer)
    }

    public var id: ObjectID
    public var name: String
    /// Parent deformer; nil means the canvas.
    public var parentID: ObjectID?
    public var kind: Kind
    /// Editor-only: show handles on the canvas.
    public var showHandles: Bool

    public init(id: ObjectID = IDGenerator.make("def"), name: String, parentID: ObjectID? = nil, kind: Kind) {
        self.id = id; self.name = name; self.parentID = parentID; self.kind = kind; showHandles = true
    }

    public var isWarp: Bool { if case .warp = kind { return true }; return false }
    public var warp: WarpDeformer? { if case let .warp(w) = kind { return w }; return nil }
    public var rotation: RotationDeformer? { if case let .rotation(r) = kind { return r }; return nil }

    public var bindings: [ParameterBinding] {
        switch kind {
        case let .warp(w): return w.keyforms.bindings
        case let .rotation(r): return r.keyforms.bindings
        }
    }

    enum CodingKeys: String, CodingKey { case id, name, parentID, type, warp, rotation, showHandles }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(ObjectID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        parentID = try c.decodeIfPresent(ObjectID.self, forKey: .parentID)
        showHandles = try c.decodeIfPresent(Bool.self, forKey: .showHandles) ?? true
        switch try c.decode(String.self, forKey: .type) {
        case "warp": kind = .warp(try c.decode(WarpDeformer.self, forKey: .warp))
        case "rotation": kind = .rotation(try c.decode(RotationDeformer.self, forKey: .rotation))
        case let t: throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "Unknown deformer type \(t)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encodeIfPresent(parentID, forKey: .parentID)
        try c.encode(showHandles, forKey: .showHandles)
        switch kind {
        case let .warp(w): try c.encode("warp", forKey: .type); try c.encode(w, forKey: .warp)
        case let .rotation(r): try c.encode("rotation", forKey: .type); try c.encode(r, forKey: .rotation)
        }
    }
}
