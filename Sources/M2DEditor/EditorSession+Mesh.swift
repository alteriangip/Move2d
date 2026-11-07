import Foundation
import M2DCore
import M2DRig

extension EditorSession {
    // MARK: Mesh generation

    /// Rebuild a mesh that follows the artwork outline. Keyforms are reset.
    public func autoMesh(_ meshIDs: [ObjectID]? = nil, spacing: Float? = nil, margin: Float = 4) {
        let ids = meshIDs ?? selectedMeshIDs
        guard !ids.isEmpty else { return }
        let s = spacing ?? meshSpacing
        perform("Auto Mesh") { b in
            for id in ids {
                guard let i = b.project.rig.meshIndex(id), let tex = b.textures[b.project.rig.meshes[i].textureID] else { continue }
                let rect = b.project.rig.meshes[i].textureRect
                let m = MeshGenerator.generate(image: tex, rect: rect, settings: .init(spacing: s, margin: margin))
                b.project.rig.meshes[i].setMesh(m, sources: nil)
            }
        }
        for id in ids { selection.vertices[id] = nil }
        notice = "Generated meshes for \(ids.count) layer\(ids.count == 1 ? "" : "s"). Keyforms were reset."
    }

    public func gridMesh(_ meshID: ObjectID, columns: Int, rows: Int) {
        perform("Grid Mesh") { b in
            guard let i = b.project.rig.meshIndex(meshID) else { return }
            let m = MeshGenerator.grid(rect: b.project.rig.meshes[i].textureRect, columns: max(1, columns), rows: max(1, rows))
            b.project.rig.meshes[i].setMesh(m, sources: nil)
        }
    }

    public func resetToQuad(_ meshID: ObjectID) {
        perform("Reset Mesh") { b in
            guard let i = b.project.rig.meshIndex(meshID) else { return }
            b.project.rig.meshes[i].setMesh(.quad(b.project.rig.meshes[i].textureRect), sources: nil)
        }
    }

    // MARK: Topology edits (rest pose)

    /// Convert a canvas point under the current pose to the mesh's rest space
    /// using the inverse of the triangle it falls in.
    public func restPoint(forCanvas p: Vec2, mesh meshID: ObjectID) -> Vec2 {
        guard let m = rig.mesh(meshID), let mp = pose.meshes[meshID] else { return p }
        let posed = mp.positions
        for t in 0..<m.mesh.triangleCount {
            let (a, b, c) = m.mesh.triangle(t)
            if let bc = Geometry.barycentric(p, posed[a], posed[b], posed[c]), bc.x >= -1e-4, bc.y >= -1e-4, bc.z >= -1e-4 {
                return m.mesh.vertices[a] * bc.x + m.mesh.vertices[b] * bc.y + m.mesh.vertices[c] * bc.z
            }
        }
        // Outside the mesh: invert the deformer chain locally around the nearest vertex.
        guard let n = m.mesh.nearestVertex(to: p, positions: posed, within: .greatestFiniteMagnitude) else { return p }
        let local = evaluator.canvasDeltaToLocal(p - posed[n], at: m.mesh.vertices[n], through: m.deformerID, values: parameterValues)
        return m.mesh.vertices[n] + local
    }

    @discardableResult
    public func addVertex(_ meshID: ObjectID, atCanvas p: Vec2) -> Int? {
        guard rig.mesh(meshID) != nil else { return nil }
        let rest = restPoint(forCanvas: p, mesh: meshID)
        var newIndex: Int?
        perform("Add Vertex") { b in
            guard let i = b.project.rig.meshIndex(meshID) else { return }
            var art = b.project.rig.meshes[i]
            var mesh = art.mesh
            let n = mesh.vertexCount
            let (idx, src) = mesh.addVertex(rest, textureRect: art.textureRect)
            art.setMesh(mesh, sources: (0..<n).map { .existing($0) } + [src])
            b.project.rig.meshes[i] = art
            newIndex = idx
        }
        if let newIndex { selection.vertices[meshID] = [newIndex] }
        return newIndex
    }

    public func removeSelectedVertices() {
        let targets = selection.vertices.filter { !$0.value.isEmpty }
        guard !targets.isEmpty else { return }
        perform("Delete Vertices") { b in
            for (meshID, verts) in targets {
                guard let i = b.project.rig.meshIndex(meshID) else { continue }
                var art = b.project.rig.meshes[i]
                var mesh = art.mesh
                guard mesh.vertexCount - verts.count >= 3 else { continue }
                let old = mesh.removeVertices(verts)
                art.setMesh(mesh, sources: old.map { .existing($0) })
                b.project.rig.meshes[i] = art
            }
        }
        for k in targets.keys { selection.vertices[k] = [] }
    }

    /// Move vertices in the rest pose (sliding over the texture: UVs follow).
    public func moveRestVertices(_ meshID: ObjectID, _ indices: Set<Int>, byCanvasDelta d: Vec2) {
        perform("Move Vertices") { b in
            guard let i = b.project.rig.meshIndex(meshID) else { return }
            var art = b.project.rig.meshes[i]
            for v in indices where v < art.mesh.vertexCount {
                let local = evaluator.canvasDeltaToLocal(d, at: art.mesh.vertices[v], through: art.deformerID, values: parameterValues)
                art.mesh.vertices[v] += local
                art.mesh.uvs[v] = Mesh.uv(for: art.mesh.vertices[v], textureRect: art.textureRect)
            }
            b.project.rig.meshes[i] = art
        }
    }

    /// Triangle tool: pick vertices; every third pick creates a triangle.
    public func pickTriangleVertex(_ meshID: ObjectID, _ v: Int) {
        if !selection.trianglePick.contains(v) { selection.trianglePick.append(v) }
        guard selection.trianglePick.count == 3 else { return }
        let (a, b, c) = (selection.trianglePick[0], selection.trianglePick[1], selection.trianglePick[2])
        selection.trianglePick = []
        perform("Add Triangle") { bn in
            guard let i = bn.project.rig.meshIndex(meshID) else { return }
            bn.project.rig.meshes[i].mesh.addTriangle(a, b, c)
        }
    }

    public func deleteTriangle(_ meshID: ObjectID, atCanvas p: Vec2) {
        guard let m = rig.mesh(meshID), let mp = pose.meshes[meshID],
              let t = m.mesh.triangle(containing: p, positions: mp.positions) else { return }
        perform("Delete Triangle") { b in
            guard let i = b.project.rig.meshIndex(meshID) else { return }
            b.project.rig.meshes[i].mesh.removeTriangles([t])
        }
    }

    /// Increase density: subdivide triangles touching selected vertices (or all).
    public func subdivide(_ meshID: ObjectID) {
        guard let m = rig.mesh(meshID) else { return }
        let sel = selection.vertices[meshID] ?? []
        var tris: Set<Int>? = nil
        if !sel.isEmpty {
            tris = Set((0..<m.mesh.triangleCount).filter { t in let (a, b, c) = m.mesh.triangle(t); return sel.contains(a) || sel.contains(b) || sel.contains(c) })
        }
        perform("Subdivide") { b in
            guard let i = b.project.rig.meshIndex(meshID) else { return }
            var art = b.project.rig.meshes[i]
            var mesh = art.mesh
            let sources = mesh.subdivide(tris, textureRect: art.textureRect)
            art.setMesh(mesh, sources: sources)
            b.project.rig.meshes[i] = art
        }
    }

    /// Re-run Delaunay over existing vertices, keeping triangles on the artwork.
    public func retriangulate(_ meshID: ObjectID) {
        guard let m = rig.mesh(meshID) else { return }
        let tex = bundle.textures[m.textureID]
        let cov = tex.map { MeshGenerator.coverage($0, threshold: 8, dilate: 3) }
        perform("Retriangulate") { b in
            guard let i = b.project.rig.meshIndex(meshID) else { return }
            let r = b.project.rig.meshes[i].textureRect
            b.project.rig.meshes[i].mesh.retriangulate { pa, pb, pc in
                guard let cov else { return true }
                let c = (pa + pb + pc) / 3
                let u = Mesh.uv(for: c, textureRect: r)
                return cov.at(Int(u.x * Float(cov.width)), Int(u.y * Float(cov.height)))
            }
        }
    }

    // MARK: Keyform deformation

    /// Index of the keyform being edited for `objectID` at the current parameter values.
    public func editableFormIndex(_ objectID: ObjectID) -> Int? {
        if let m = rig.mesh(objectID) { return m.keyforms.exactFormIndex(parameterValues) }
        if let d = rig.deformer(objectID) {
            switch d.kind {
            case let .warp(w): return w.keyforms.exactFormIndex(parameterValues)
            case let .rotation(r): return r.keyforms.exactFormIndex(parameterValues)
            }
        }
        return nil
    }

    /// Explains why an object can't be deformed right now, if so.
    public func keyformBlocker(_ objectID: ObjectID) -> String? {
        guard editableFormIndex(objectID) == nil else { return nil }
        let bindings = rig.mesh(objectID)?.keyforms.bindings ?? rig.deformer(objectID)?.bindings ?? []
        let off = bindings.filter { b in !b.keys.contains { abs($0 - (parameterValues[b.parameterID] ?? 0)) < 1e-4 } }
        let names = off.compactMap { rig.parameter($0.parameterID)?.name }.joined(separator: ", ")
        return "Move \(names) onto a key (or add a key) to edit this shape."
    }

    /// Displace vertices of the current mesh keyform by a canvas-space delta.
    @discardableResult
    public func deformVertices(_ meshID: ObjectID, _ indices: Set<Int>, byCanvasDelta d: Vec2, falloffRadius: Float = 0) -> Bool {
        guard let m = rig.mesh(meshID), let fi = editableFormIndex(meshID) else {
            notice = keyformBlocker(meshID); return false
        }
        // Soft selection: neighbours within the radius move with smooth falloff.
        var weights: [Int: Float] = [:]
        for v in indices { weights[v] = 1 }
        if falloffRadius > 0, let mp = pose.meshes[meshID] {
            for v in 0..<m.mesh.vertexCount where weights[v] == nil {
                let dist = indices.map { (mp.positions[$0] - mp.positions[v]).length }.min() ?? .greatestFiniteMagnitude
                if dist < falloffRadius { let t = 1 - dist / falloffRadius; weights[v] = t * t * (3 - 2 * t) }
            }
        }
        let form = m.keyforms.forms[fi]
        perform("Deform") { b in
            guard let i = b.project.rig.meshIndex(meshID) else { return }
            var f = form
            for (v, w) in weights where v < f.offsets.count {
                let restPos = m.mesh.vertices[v] + f.offsets[v]
                f.offsets[v] += evaluator.canvasDeltaToLocal(d * w, at: restPos, through: m.deformerID, values: parameterValues)
            }
            b.project.rig.meshes[i].keyforms.forms[fi] = f
        }
        return true
    }

    /// Move whole selected meshes in the current keyform.
    public func translateMeshes(_ ids: [ObjectID], byCanvasDelta d: Vec2) {
        for id in ids {
            guard let m = rig.mesh(id) else { continue }
            deformVertices(id, Set(0..<m.mesh.vertexCount), byCanvasDelta: d)
        }
    }

    public func resetKeyformShape(_ objectID: ObjectID) {
        guard let fi = editableFormIndex(objectID) else { notice = keyformBlocker(objectID); return }
        perform("Reset Shape") { b in
            if let i = b.project.rig.meshIndex(objectID) {
                let n = b.project.rig.meshes[i].mesh.vertexCount
                b.project.rig.meshes[i].keyforms.forms[fi].offsets = [Vec2](repeating: .zero, count: n)
            } else if let i = b.project.rig.deformerIndex(objectID) {
                switch b.project.rig.deformers[i].kind {
                case var .warp(w): w.keyforms.forms[fi].points = w.restPoints; b.project.rig.deformers[i].kind = .warp(w)
                case var .rotation(r):
                    r.keyforms.forms[fi].origin = r.restOrigin; r.keyforms.forms[fi].angle = 0; r.keyforms.forms[fi].scale = 1
                    b.project.rig.deformers[i].kind = .rotation(r)
                }
            }
        }
    }

    /// Mirror the current keyform of one object horizontally around its rest centre
    /// into the keyform at the opposite parameter value (e.g. Angle X +30 → −30).
    public func mirrorKeyform(_ objectID: ObjectID, parameterID: ObjectID) {
        guard let p = rig.parameter(parameterID), let fi = editableFormIndex(objectID) else { return }
        let v = parameterValues[parameterID] ?? p.defaultValue
        let mirrored = p.defaultValue - (v - p.defaultValue)
        var target = parameterValues
        target[parameterID] = mirrored
        perform("Mirror Keyform") { b in
            if let i = b.project.rig.meshIndex(objectID) {
                var k = b.project.rig.meshes[i].keyforms
                guard let ti = k.exactFormIndex(target) else { return }
                k.forms[ti].offsets = k.forms[fi].offsets.map { Vec2(-$0.x, $0.y) }
                k.forms[ti].opacity = k.forms[fi].opacity
                b.project.rig.meshes[i].keyforms = k
            } else if let i = b.project.rig.deformerIndex(objectID) {
                switch b.project.rig.deformers[i].kind {
                case var .warp(w):
                    guard let ti = w.keyforms.exactFormIndex(target) else { return }
                    let rest = w.restPoints
                    // Mirror offsets and swap columns.
                    let s = w.columns + 1
                    var pts = w.keyforms.forms[ti].points
                    for j in 0...w.rows { for c in 0...w.columns {
                        let src = j * s + (w.columns - c), dst = j * s + c
                        let off = w.keyforms.forms[fi].points[src] - rest[src]
                        pts[dst] = rest[dst] + Vec2(-off.x, off.y)
                    }}
                    w.keyforms.forms[ti].points = pts
                    b.project.rig.deformers[i].kind = .warp(w)
                case var .rotation(r):
                    guard let ti = r.keyforms.exactFormIndex(target) else { return }
                    let f = r.keyforms.forms[fi]
                    r.keyforms.forms[ti].angle = -f.angle
                    r.keyforms.forms[ti].origin = r.restOrigin + Vec2(-(f.origin.x - r.restOrigin.x), f.origin.y - r.restOrigin.y)
                    b.project.rig.deformers[i].kind = .rotation(r)
                }
            }
        }
    }
}
