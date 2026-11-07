import SwiftUI
import Observation
import M2DCore
import M2DRig
import M2DEditor

/// Translates pointer input (Pencil or finger) into editor operations for the active tool.
@Observable
final class CanvasToolController {
    let session: EditorSession
    let viewport: CanvasViewport

    var hoverVertex: (ObjectID, Int)?
    var lassoPath: [Vec2] = []
    /// Soft-selection radius for the deform tool, in canvas units (0 = off).
    var falloffRadius: Float = 0

    @ObservationIgnored var drag: Drag = .none
    @ObservationIgnored var startPoint: Vec2 = .zero
    @ObservationIgnored var lastPoint: Vec2 = .zero
    @ObservationIgnored var moved = false
    @ObservationIgnored var extendSelection = false

    enum Drag {
        case none
        case translateSelection
        case vertices(ObjectID, Set<Int>, rest: Bool)
        case controlPoints(ObjectID, Set<Int>)
        case rotateHandle(ObjectID)
        case pivot(ObjectID)
        case lasso
        case pendingAddVertex(ObjectID)
        case pan
    }

    init(session: EditorSession, viewport: CanvasViewport) { self.session = session; self.viewport = viewport }

    /// Hit radius in canvas units for a given on-screen radius.
    func radius(_ points: CGFloat) -> Float { Float(points / viewport.scale) }

    // MARK: Pointer events (canvas coordinates)

    func began(_ p: Vec2, isPencil: Bool, shift: Bool) {
        startPoint = p; lastPoint = p; moved = false; extendSelection = shift
        let r = radius(isPencil ? 14 : 24)
        let s = session
        drag = .none
        switch s.tool {
        case .hand:
            drag = .pan
        case .select:
            if let (id, isPivot) = s.hitTestRotationHandle(p, radius: r) {
                s.select(id)
                drag = isPivot && s.mode == .rig ? .pivot(id) : .rotateHandle(id)
            } else if let did = s.selectedDeformerID, s.rig.deformer(did)?.isWarp == true,
                      let (wid, pt) = s.hitTestControlPoint(p, radius: r), wid == did {
                let pts = (s.selection.controlPoints[wid]?.contains(pt) ?? false) ? s.selection.controlPoints[wid]! : [pt]
                s.selection.controlPoints[wid] = pts
                drag = .controlPoints(wid, pts)
            } else if let mesh = s.hitTestMesh(p) {
                let partOrMesh = owningSelectable(mesh)
                if !s.selection.contains(partOrMesh) || shift { s.select(partOrMesh, extend: shift) }
                drag = .translateSelection
            } else {
                if !shift { s.select(nil) }
                drag = .lasso; lassoPath = [p]
            }
        case .deform:
            if let did = s.selectedDeformerID, s.rig.deformer(did)?.isWarp == true,
               let (wid, pt) = s.hitTestControlPoint(p, radius: r), wid == did {
                var sel = s.selection.controlPoints[wid] ?? []
                if shift { sel.formSymmetricDifference([pt]) } else if !sel.contains(pt) { sel = [pt] }
                s.selection.controlPoints[wid] = sel
                drag = .controlPoints(wid, sel)
            } else if let (mid, v) = nearestSelectedVertex(p, radius: r) {
                var sel = s.selection.vertices[mid] ?? []
                if shift { sel.formSymmetricDifference([v]) } else if !sel.contains(v) { sel = [v] }
                s.selection.vertices[mid] = sel
                drag = .vertices(mid, sel, rest: false)
            } else if let mesh = s.hitTestMesh(p), !s.selectedMeshIDs.contains(mesh) {
                s.select(mesh, extend: shift)
            } else {
                drag = .lasso; lassoPath = [p]
            }
        case .meshEdit:
            if let (mid, v) = nearestSelectedVertex(p, radius: r) {
                var sel = s.selection.vertices[mid] ?? []
                if shift { sel.formSymmetricDifference([v]) } else if !sel.contains(v) { sel = [v] }
                s.selection.vertices[mid] = sel
                drag = .vertices(mid, sel, rest: true)
            } else if let mid = s.selectedMeshIDs.first(where: { s.rig.mesh($0) != nil }) {
                drag = .pendingAddVertex(mid)
            } else if let mesh = s.hitTestMesh(p) {
                s.select(mesh)
            }
        case .triangle:
            if let (mid, v) = nearestSelectedVertex(p, radius: r) {
                s.pickTriangleVertex(mid, v)
            } else if let mid = s.selectedMeshIDs.first {
                s.deleteTriangle(mid, atCanvas: p)
            } else if let mesh = s.hitTestMesh(p) {
                s.select(mesh)
            }
        case .lasso:
            drag = .lasso; lassoPath = [p]
        case .rotate:
            if let id = s.selectedDeformerID, s.rig.deformer(id)?.rotation != nil {
                drag = .rotateHandle(id)
            } else if let (id, _) = s.hitTestRotationHandle(p, radius: r) {
                s.select(id); drag = .rotateHandle(id)
            } else {
                s.notice = "Select a rotation deformer to rotate."
            }
        }
        switch drag {
        case .translateSelection, .vertices, .controlPoints, .rotateHandle, .pivot:
            s.beginGesture("Drag")
        default: break
        }
    }

    func moved(_ p: Vec2, viewDelta: CGSize) {
        let s = session
        let d = p - lastPoint
        if (p - startPoint).length > radius(4) { moved = true }
        defer { lastPoint = p }
        switch drag {
        case .none, .pendingAddVertex: break
        case .pan: viewport.pan(by: viewDelta)
        case .translateSelection:
            guard moved else { return }
            for id in s.selection.objects {
                if let def = s.rig.deformer(id) {
                    if def.isWarp { s.translateWarp(id, byCanvasDelta: d) } else { s.translateRotationDeformer(id, byCanvasDelta: d) }
                }
            }
            s.translateMeshes(s.selectedMeshIDs, byCanvasDelta: d)
        case let .vertices(mid, set, rest):
            guard moved else { return }
            if rest { s.moveRestVertices(mid, set, byCanvasDelta: d) }
            else { s.deformVertices(mid, set, byCanvasDelta: d, falloffRadius: falloffRadius) }
        case let .controlPoints(id, set):
            guard moved else { return }
            s.moveControlPoints(id, set, byCanvasDelta: d)
        case let .rotateHandle(id):
            guard let o = s.pose.deformers[id]?.origin else { return }
            let a0 = atan2(lastPoint.y - o.y, lastPoint.x - o.x), a1 = atan2(p.y - o.y, p.x - o.x)
            var delta = radiansToDegrees(a1 - a0)
            if delta > 180 { delta -= 360 } else if delta < -180 { delta += 360 }
            s.rotateDeformer(id, byDegrees: delta)
        case let .pivot(id):
            s.movePivot(id, toCanvas: p)
        case .lasso:
            lassoPath.append(p)
        }
    }

    func ended(_ p: Vec2) {
        let s = session
        switch drag {
        case let .pendingAddVertex(mid):
            if !moved { s.addVertex(mid, atCanvas: p) }
        case .lasso:
            finishLasso()
        default: break
        }
        if case .none = drag {} else { s.endGesture() }
        drag = .none
        lassoPath = []
    }

    func cancelled() {
        session.cancelGesture()
        drag = .none
        lassoPath = []
    }

    func hover(_ p: Vec2?) {
        guard let p, [.deform, .meshEdit, .triangle].contains(session.tool) else { hoverVertex = nil; return }
        hoverVertex = nearestSelectedVertex(p, radius: radius(14))
    }

    // MARK: Helpers

    /// Selecting a mesh inside a locked/collapsed part selects the mesh itself.
    func owningSelectable(_ meshID: ObjectID) -> ObjectID { meshID }

    func nearestSelectedVertex(_ p: Vec2, radius: Float) -> (ObjectID, Int)? {
        var best: (ObjectID, Int)?, bestD = radius
        for id in session.selectedMeshIDs {
            guard let mp = session.pose.meshes[id] else { continue }
            for (i, q) in mp.positions.enumerated() {
                let d = (q - p).length
                if d <= bestD { bestD = d; best = (id, i) }
            }
        }
        return best
    }

    func finishLasso() {
        let s = session
        guard lassoPath.count > 2 else { return }
        let poly = lassoPath
        if s.tool == .select {
            // Select meshes whose centre lies inside the lasso.
            var ids: [ObjectID] = extendSelection ? s.selection.objects : []
            for (id, mp) in s.pose.meshes where mp.visible {
                let c = mp.positions.reduce(Vec2.zero, +) / Float(max(1, mp.positions.count))
                if Geometry.pointInPolygon(c, poly) && !ids.contains(id) { ids.append(id) }
            }
            s.selection.objects = ids
            return
        }
        if let did = s.selectedDeformerID, let dp = s.pose.deformers[did], !dp.latticePoints.isEmpty {
            let inside = Set(dp.latticePoints.indices.filter { Geometry.pointInPolygon(dp.latticePoints[$0], poly) })
            if !inside.isEmpty {
                s.selection.controlPoints[did] = extendSelection ? (s.selection.controlPoints[did] ?? []).union(inside) : inside
                return
            }
        }
        for id in s.selectedMeshIDs {
            guard let mp = s.pose.meshes[id] else { continue }
            let inside = Set(mp.positions.indices.filter { Geometry.pointInPolygon(mp.positions[$0], poly) })
            s.selection.vertices[id] = extendSelection ? (s.selection.vertices[id] ?? []).union(inside) : inside
        }
    }
}
