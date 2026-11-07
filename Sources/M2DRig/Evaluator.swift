import Foundation
import M2DCore

/// Deformed state of one mesh.
public struct MeshPose: Sendable {
    public var positions: [Vec2]
    public var opacity: Float
    public var drawOrder: Float
    public var visible: Bool
}

/// Deformed state of one deformer, already mapped through its ancestors (canvas space).
public struct DeformerPose: Sendable {
    public var opacity: Float
    /// Warp: deformed lattice points.
    public var latticePoints: [Vec2]
    /// Rotation: pivot, total angle (degrees) and scale.
    public var origin: Vec2
    public var angle: Float
    public var scale: Float
}

public struct RigPose: Sendable {
    public var meshes: [ObjectID: MeshPose]
    public var deformers: [ObjectID: DeformerPose]
    /// Mesh ids sorted back to front.
    public var drawOrder: [ObjectID]
}

/// Evaluates a rig for a set of parameter values. Create once per model
/// revision; `evaluate` is cheap enough to run every frame.
public final class RigEvaluator {
    public let model: RigModel
    let deformerIndex: [ObjectID: Int]
    let hierarchyOrder: [ObjectID: Int]
    let partOpacity: [ObjectID: (Float, Bool)]

    public init(model: RigModel) {
        self.model = model
        var di: [ObjectID: Int] = [:]
        for (i, d) in model.deformers.enumerated() { di[d.id] = i }
        deformerIndex = di
        var ho: [ObjectID: Int] = [:]
        for (i, id) in model.meshesBackToFront().enumerated() { ho[id] = i }
        hierarchyOrder = ho
        // Effective part opacity/visibility (multiplied down the tree).
        var po: [ObjectID: (Float, Bool)] = [:]
        func walk(_ ids: [ObjectID], _ op: Float, _ vis: Bool) {
            for id in ids {
                if let p = model.part(id) {
                    let o = op * p.opacity, v = vis && p.visible
                    po[id] = (o, v)
                    walk(p.children, o, v)
                }
            }
        }
        walk(model.rootChildren, 1, true)
        partOpacity = po
    }

    /// Local (unparented) keyform blends for every deformer.
    struct LocalForms {
        var warp: [Int: WarpForm] = [:]
        var rotation: [Int: RotationForm] = [:]
    }

    func localForms(_ values: ParameterValues) -> LocalForms {
        var lf = LocalForms()
        for (i, d) in model.deformers.enumerated() {
            switch d.kind {
            case let .warp(w): lf.warp[i] = w.keyforms.evaluate(values)
            case let .rotation(r): lf.rotation[i] = r.keyforms.evaluate(values)
            }
        }
        return lf
    }

    /// Map a point from a deformer's input space up through all its ancestors.
    @inline(__always) func apply(_ p: Vec2, deformer start: ObjectID?, _ lf: LocalForms) -> Vec2 {
        var q = p
        var cur = start
        var depth = 0
        while let id = cur, let i = deformerIndex[id], depth < 64 {
            let d = model.deformers[i]
            switch d.kind {
            case let .warp(w): q = w.map(q, points: lf.warp[i]!.points)
            case let .rotation(r): q = r.map(q, form: lf.rotation[i]!)
            }
            cur = d.parentID; depth += 1
        }
        return q
    }

    func chainOpacity(_ start: ObjectID?, _ lf: LocalForms) -> Float {
        var o: Float = 1
        var cur = start, depth = 0
        while let id = cur, let i = deformerIndex[id], depth < 64 {
            o *= lf.warp[i]?.opacity ?? lf.rotation[i]?.opacity ?? 1
            cur = model.deformers[i].parentID; depth += 1
        }
        return o
    }

    public func evaluate(_ values: ParameterValues) -> RigPose {
        let lf = localForms(values)
        var meshes: [ObjectID: MeshPose] = [:]
        meshes.reserveCapacity(model.meshes.count)
        for m in model.meshes {
            let form = m.keyforms.evaluate(values)
            var pos = m.mesh.vertices
            let n = min(pos.count, form.offsets.count)
            for i in 0..<n { pos[i] += form.offsets[i] }
            if m.deformerID != nil {
                for i in pos.indices { pos[i] = apply(pos[i], deformer: m.deformerID, lf) }
            }
            let part = m.partID.flatMap { partOpacity[$0] } ?? (1, true)
            let op = max(0, min(1, form.opacity)) * chainOpacity(m.deformerID, lf) * part.0
            meshes[m.id] = MeshPose(positions: pos, opacity: op, drawOrder: form.drawOrder, visible: m.visible && part.1)
        }
        var defs: [ObjectID: DeformerPose] = [:]
        for (i, d) in model.deformers.enumerated() {
            let op = chainOpacity(d.id, lf)
            switch d.kind {
            case .warp:
                let pts = lf.warp[i]!.points.map { apply($0, deformer: d.parentID, lf) }
                defs[d.id] = DeformerPose(opacity: op, latticePoints: pts, origin: .zero, angle: 0, scale: 1)
            case .rotation:
                let f = lf.rotation[i]!
                let o = apply(f.origin, deformer: d.parentID, lf)
                // Ancestors may rotate too: measure how they turn a unit vector.
                let probe = apply(f.origin + Vec2(1, 0).rotated(by: degreesToRadians(f.angle)), deformer: d.parentID, lf) - o
                let total = radiansToDegrees(atan2(probe.y, probe.x))
                defs[d.id] = DeformerPose(opacity: op, latticePoints: [], origin: o, angle: total, scale: f.scale * max(probe.length, 1e-6))
            }
        }
        let order = model.meshes.map(\.id).sorted { a, b in
            let da = meshes[a]!.drawOrder, db = meshes[b]!.drawOrder
            if abs(da - db) > 1e-4 { return da < db }
            return (hierarchyOrder[a] ?? 0) < (hierarchyOrder[b] ?? 0)
        }
        return RigPose(meshes: meshes, deformers: defs, drawOrder: order)
    }

    /// Map a point given in `deformerID`'s input space to canvas space.
    public func mapToCanvas(_ p: Vec2, through deformerID: ObjectID?, values: ParameterValues) -> Vec2 {
        apply(p, deformer: deformerID, localForms(values))
    }

    /// Jacobian of the mapping input-space → canvas at `p` (columns = d/dx, d/dy).
    public func jacobian(at p: Vec2, through deformerID: ObjectID?, values: ParameterValues) -> (Vec2, Vec2) {
        let lf = localForms(values)
        let h: Float = 0.5
        let dx = (apply(p + Vec2(h, 0), deformer: deformerID, lf) - apply(p - Vec2(h, 0), deformer: deformerID, lf)) / (2 * h)
        let dy = (apply(p + Vec2(0, h), deformer: deformerID, lf) - apply(p - Vec2(0, h), deformer: deformerID, lf)) / (2 * h)
        return (dx, dy)
    }

    /// Convert a canvas-space drag into the equivalent displacement in a deformer's input space.
    public func canvasDeltaToLocal(_ delta: Vec2, at p: Vec2, through deformerID: ObjectID?, values: ParameterValues) -> Vec2 {
        guard deformerID != nil else { return delta }
        let (jx, jy) = jacobian(at: p, through: deformerID, values: values)
        let det = jx.x * jy.y - jy.x * jx.y
        guard abs(det) > 1e-8 else { return delta }
        return Vec2((jy.y * delta.x - jy.x * delta.y) / det, (-jx.y * delta.x + jx.x * delta.y) / det)
    }
}
