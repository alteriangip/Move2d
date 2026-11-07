import Foundation
import M2DCore
import M2DRig

extension EditorSession {
    /// Common deformation parent of the given objects, if they all share one.
    func commonDeformerParent(_ ids: [ObjectID]) -> ObjectID? {
        let parents = ids.map { rig.mesh($0)?.deformerID ?? rig.deformer($0)?.parentID }
        guard let first = parents.first else { return nil }
        return parents.allSatisfy { $0 == first } ? first : nil
    }

    /// Objects a new deformer should wrap: selected meshes (parts expanded) and deformers.
    var deformTargets: [ObjectID] {
        selectedMeshIDs + selection.objects.filter { rig.deformer($0) != nil }
    }

    /// Rest-space bounds (in the would-be parent's input space) of the targets.
    func restBounds(_ ids: [ObjectID]) -> Rect {
        var r = Rect.zero
        for id in ids {
            if let m = rig.mesh(id) { r = r.union(Rect.bounding(m.mesh.vertices)) }
            if let d = rig.deformer(id) {
                switch d.kind {
                case let .warp(w): r = r.union(Rect.bounding(w.keyforms.forms[0].points))
                case let .rotation(rot): r = r.union(Rect(origin: rot.restOrigin, size: .zero))
                }
            }
        }
        return r
    }

    /// Wrap the selection in a warp deformer. Returns the new deformer id.
    @discardableResult
    public func createWarpDeformer(name: String? = nil, columns: Int = 4, rows: Int = 4, margin: Float = 0.08) -> ObjectID? {
        let targets = deformTargets
        guard !targets.isEmpty else { notice = "Select layers to wrap in a warp deformer."; return nil }
        var rect = restBounds(targets)
        if rect.isEmpty { rect = rig.canvasRect }
        let pad = max(rect.width, rect.height) * margin
        rect = rect.insetBy(-pad)
        let parent = commonDeformerParent(targets)
        let d = Deformer(name: name ?? "Warp \(rig.deformers.count + 1)", parentID: parent,
                         kind: .warp(WarpDeformer(rect: rect, columns: columns, rows: rows)))
        perform("Create Warp Deformer") { b in
            b.project.rig.deformers.append(d)
            for id in targets { Self.setDeformerParent(id, d.id, &b.project.rig) }
        }
        selection.objects = [d.id]
        return d.id
    }

    /// Wrap the selection in a rotation deformer pivoting at `pivot` (rest canvas space) or the bounds' bottom centre.
    @discardableResult
    public func createRotationDeformer(name: String? = nil, pivot: Vec2? = nil) -> ObjectID? {
        let targets = deformTargets
        guard !targets.isEmpty else { notice = "Select layers to attach to a rotation deformer."; return nil }
        let b0 = restBounds(targets)
        let origin = pivot ?? Vec2(b0.center.x, b0.maxY)
        let parent = commonDeformerParent(targets)
        let d = Deformer(name: name ?? "Rotation \(rig.deformers.count + 1)", parentID: parent,
                         kind: .rotation(RotationDeformer(origin: origin, handleLength: max(60, b0.height * 0.6))))
        perform("Create Rotation Deformer") { b in
            b.project.rig.deformers.append(d)
            for id in targets { Self.setDeformerParent(id, d.id, &b.project.rig) }
        }
        selection.objects = [d.id]
        return d.id
    }

    static func setDeformerParent(_ id: ObjectID, _ parent: ObjectID?, _ r: inout RigModel) {
        if let i = r.meshIndex(id) { r.meshes[i].deformerID = parent }
        if let i = r.deformerIndex(id), id != parent, !r.wouldCreateCycle(deformer: id, parent: parent) {
            r.deformers[i].parentID = parent
        }
    }

    /// Re-parent a mesh or deformer in the deformer tree.
    public func setDeformerParent(_ id: ObjectID, to parent: ObjectID?) {
        if rig.deformer(id) != nil, rig.wouldCreateCycle(deformer: id, parent: parent) || id == parent {
            notice = "A deformer can't be placed inside itself."; return
        }
        perform("Change Deformer Parent") { b in Self.setDeformerParent(id, parent, &b.project.rig) }
    }

    public func deleteDeformer(_ id: ObjectID) {
        perform("Delete Deformer") { b in Self.deleteDeformer(id, &b.project.rig) }
    }

    /// Children (deformers and meshes) of a deformer, nil = canvas root.
    public func deformerChildren(of id: ObjectID?) -> [ObjectID] {
        rig.deformers.filter { $0.parentID == id }.map(\.id) + rig.meshes.filter { $0.deformerID == id }.map(\.id)
    }

    public func setWarpResolution(_ id: ObjectID, columns: Int, rows: Int) {
        perform("Warp Resolution") { b in
            guard let i = b.project.rig.deformerIndex(id), case var .warp(w) = b.project.rig.deformers[i].kind else { return }
            w.resample(columns: clamp(columns, 1, 32), rows: clamp(rows, 1, 32))
            b.project.rig.deformers[i].kind = .warp(w)
        }
        selection.controlPoints[id] = nil
    }

    /// Move warp control points in the current keyform.
    @discardableResult
    public func moveControlPoints(_ id: ObjectID, _ points: Set<Int>, byCanvasDelta d: Vec2) -> Bool {
        guard let def = rig.deformer(id), let w = def.warp, let fi = editableFormIndex(id) else {
            notice = keyformBlocker(id); return false
        }
        perform("Move Control Points") { b in
            guard let i = b.project.rig.deformerIndex(id) else { return }
            var ww = w
            for p in points where p < ww.pointCount {
                let pos = ww.keyforms.forms[fi].points[p]
                ww.keyforms.forms[fi].points[p] += evaluator.canvasDeltaToLocal(d, at: pos, through: def.parentID, values: parameterValues)
            }
            b.project.rig.deformers[i].kind = .warp(ww)
        }
        return true
    }

    /// Move a whole warp (all points) in the current keyform.
    public func translateWarp(_ id: ObjectID, byCanvasDelta d: Vec2) {
        guard let w = rig.deformer(id)?.warp else { return }
        moveControlPoints(id, Set(0..<w.pointCount), byCanvasDelta: d)
    }

    /// Rotate a rotation deformer's current keyform by `degrees`.
    @discardableResult
    public func rotateDeformer(_ id: ObjectID, byDegrees deg: Float) -> Bool {
        guard rig.deformer(id)?.rotation != nil, let fi = editableFormIndex(id) else { notice = keyformBlocker(id); return false }
        perform("Rotate") { b in
            guard let i = b.project.rig.deformerIndex(id), case var .rotation(r) = b.project.rig.deformers[i].kind else { return }
            r.keyforms.forms[fi].angle += deg
            b.project.rig.deformers[i].kind = .rotation(r)
        }
        return true
    }

    public func setRotationForm(_ id: ObjectID, angle: Float? = nil, scale: Float? = nil, opacity: Float? = nil) {
        guard let fi = editableFormIndex(id) else { notice = keyformBlocker(id); return }
        perform("Edit Rotation") { b in
            guard let i = b.project.rig.deformerIndex(id), case var .rotation(r) = b.project.rig.deformers[i].kind else { return }
            if let angle { r.keyforms.forms[fi].angle = angle }
            if let scale { r.keyforms.forms[fi].scale = max(0.01, scale) }
            if let opacity { r.keyforms.forms[fi].opacity = clamp(opacity, 0, 1) }
            b.project.rig.deformers[i].kind = .rotation(r)
        }
    }

    /// Translate the rotation deformer in the current keyform.
    public func translateRotationDeformer(_ id: ObjectID, byCanvasDelta d: Vec2) {
        guard let def = rig.deformer(id), let r = def.rotation, let fi = editableFormIndex(id) else { notice = keyformBlocker(id); return }
        let local = evaluator.canvasDeltaToLocal(d, at: r.keyforms.forms[fi].origin, through: def.parentID, values: parameterValues)
        perform("Move Deformer") { b in
            guard let i = b.project.rig.deformerIndex(id), case var .rotation(rr) = b.project.rig.deformers[i].kind else { return }
            rr.keyforms.forms[fi].origin += local
            b.project.rig.deformers[i].kind = .rotation(rr)
        }
    }

    /// Move the pivot in setup (all keyforms keep their visual result).
    public func movePivot(_ id: ObjectID, toCanvas p: Vec2) {
        guard let def = rig.deformer(id), let r = def.rotation else { return }
        let current = pose.deformers[id]?.origin ?? r.restOrigin
        let local = evaluator.canvasDeltaToLocal(p - current, at: r.restOrigin, through: def.parentID, values: parameterValues)
        perform("Move Pivot") { b in
            guard let i = b.project.rig.deformerIndex(id), case var .rotation(rr) = b.project.rig.deformers[i].kind else { return }
            rr.movePivot(to: rr.restOrigin + local)
            b.project.rig.deformers[i].kind = .rotation(rr)
        }
    }

    public func setDeformerOpacity(_ id: ObjectID, _ opacity: Float) {
        guard let fi = editableFormIndex(id) else { notice = keyformBlocker(id); return }
        perform("Deformer Opacity") { b in
            guard let i = b.project.rig.deformerIndex(id) else { return }
            switch b.project.rig.deformers[i].kind {
            case var .warp(w): w.keyforms.forms[fi].opacity = clamp(opacity, 0, 1); b.project.rig.deformers[i].kind = .warp(w)
            case var .rotation(r): r.keyforms.forms[fi].opacity = clamp(opacity, 0, 1); b.project.rig.deformers[i].kind = .rotation(r)
            }
        }
    }
}
