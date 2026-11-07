import Foundation
import M2DCore
import M2DRig
import M2DProject

/// Kinds of objects that appear in the hierarchy panels.
public enum ObjectKind: Sendable { case part, mesh, warp, rotation }

extension EditorSession {
    public func kind(of id: ObjectID) -> ObjectKind? {
        if rig.isPart(id) { return .part }
        if rig.meshIndex(id) != nil { return .mesh }
        if let d = rig.deformer(id) { return d.isWarp ? .warp : .rotation }
        return nil
    }

    public func name(of id: ObjectID) -> String {
        rig.part(id)?.name ?? rig.mesh(id)?.name ?? rig.deformer(id)?.name ?? rig.parameter(id)?.name ?? id
    }

    // MARK: Selection

    public func select(_ id: ObjectID?, extend: Bool = false) {
        guard let id else { if !extend { selection = Selection() }; return }
        if extend {
            if let i = selection.objects.firstIndex(of: id) { selection.objects.remove(at: i) } else { selection.objects.append(id) }
        } else {
            selection.objects = [id]
            selection.vertices = [:]; selection.controlPoints = [:]
        }
        selection.trianglePick = []
    }

    public func selectAllVertices(of meshID: ObjectID) {
        guard let m = rig.mesh(meshID) else { return }
        selection.vertices[meshID] = Set(0..<m.mesh.vertexCount)
    }

    /// Meshes affected by the selection (parts expand to their meshes).
    public var selectedMeshIDs: [ObjectID] {
        var out: [ObjectID] = []
        for id in selection.objects {
            if rig.meshIndex(id) != nil { out.append(id) } else if rig.isPart(id) { out += rig.meshes(inPart: id) }
        }
        var seen = Set<ObjectID>()
        return out.filter { seen.insert($0).inserted }
    }

    public var selectedDeformerID: ObjectID? { selection.objects.last { rig.deformer($0) != nil } }

    // MARK: Hit testing (canvas space, current pose)

    /// Top-most visible mesh with opaque artwork under `p`.
    public func hitTestMesh(_ p: Vec2, alphaThreshold: Float = 0.1) -> ObjectID? {
        for id in pose.drawOrder.reversed() {
            guard let m = rig.mesh(id), let mp = pose.meshes[id], mp.visible, mp.opacity > 0.01, !isLocked(id) else { continue }
            let pts = mp.positions
            for t in 0..<m.mesh.triangleCount {
                let (a, b, c) = m.mesh.triangle(t)
                guard let bc = Geometry.barycentric(p, pts[a], pts[b], pts[c]), bc.x >= 0, bc.y >= 0, bc.z >= 0 else { continue }
                let uv = m.mesh.uvs[a] * bc.x + m.mesh.uvs[b] * bc.y + m.mesh.uvs[c] * bc.z
                if let tex = bundle.textures[m.textureID] {
                    let x = min(max(Int(uv.x * Float(tex.width)), 0), tex.width - 1)
                    let y = min(max(Int(uv.y * Float(tex.height)), 0), tex.height - 1)
                    if Float(tex.alpha(x, y)) / 255 >= alphaThreshold { return id }
                } else { return id }
            }
        }
        return nil
    }

    /// Nearest vertex of `meshID` (current pose) within `radius` canvas units.
    public func hitTestVertex(_ meshID: ObjectID, _ p: Vec2, radius: Float) -> Int? {
        guard let m = rig.mesh(meshID), let mp = pose.meshes[meshID] else { return nil }
        return m.mesh.nearestVertex(to: p, positions: mp.positions, within: radius)
    }

    /// Nearest warp control point within radius, searching selected deformers first.
    public func hitTestControlPoint(_ p: Vec2, radius: Float) -> (ObjectID, Int)? {
        let ids = selection.objects.filter { rig.deformer($0)?.isWarp == true } + rig.deformers.filter(\.isWarp).map(\.id)
        for id in ids {
            guard let dp = pose.deformers[id] else { continue }
            var best: Int?, bestD = radius * radius
            for (i, q) in dp.latticePoints.enumerated() { let d = (q - p).lengthSquared; if d <= bestD { bestD = d; best = i } }
            if let best { return (id, best) }
        }
        return nil
    }

    /// Rotation deformer whose pivot or handle tip is near `p`.
    public func hitTestRotationHandle(_ p: Vec2, radius: Float) -> (ObjectID, isPivot: Bool)? {
        for d in rig.deformers {
            guard let r = d.rotation, let dp = pose.deformers[d.id] else { continue }
            if (dp.origin - p).length <= radius { return (d.id, true) }
            let tip = dp.origin + Vec2(0, -r.handleLength * dp.scale).rotated(by: degreesToRadians(dp.angle))
            if (tip - p).length <= radius { return (d.id, false) }
        }
        return nil
    }

    func isLocked(_ meshID: ObjectID) -> Bool {
        guard let m = rig.mesh(meshID) else { return true }
        if m.locked { return true }
        var cur = m.partID
        while let c = cur, let p = rig.part(c) { if p.locked { return true }; cur = p.parentID }
        return false
    }

    // MARK: Hierarchy edits

    public func rename(_ id: ObjectID, to newName: String) {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        perform("Rename") { b in
            if let i = b.project.rig.partIndex(id) { b.project.rig.parts[i].name = name }
            else if let i = b.project.rig.meshIndex(id) { b.project.rig.meshes[i].name = name }
            else if let i = b.project.rig.deformerIndex(id) { b.project.rig.deformers[i].name = name }
            else if let i = b.project.rig.parameterIndex(id) { b.project.rig.parameters[i].name = name }
            else if let i = b.project.animations.firstIndex(where: { $0.id == id }) { b.project.animations[i].name = name }
            else if let i = b.project.physics.groups.firstIndex(where: { $0.id == id }) { b.project.physics.groups[i].name = name }
        }
    }

    public func setVisible(_ id: ObjectID, _ visible: Bool) {
        perform(visible ? "Show" : "Hide") { b in
            if let i = b.project.rig.partIndex(id) { b.project.rig.parts[i].visible = visible }
            else if let i = b.project.rig.meshIndex(id) { b.project.rig.meshes[i].visible = visible }
        }
    }

    public func isVisible(_ id: ObjectID) -> Bool { rig.part(id)?.visible ?? rig.mesh(id)?.visible ?? true }
    public func isLockedFlag(_ id: ObjectID) -> Bool { rig.part(id)?.locked ?? rig.mesh(id)?.locked ?? false }

    public func setLocked(_ id: ObjectID, _ locked: Bool) {
        perform(locked ? "Lock" : "Unlock") { b in
            if let i = b.project.rig.partIndex(id) { b.project.rig.parts[i].locked = locked }
            else if let i = b.project.rig.meshIndex(id) { b.project.rig.meshes[i].locked = locked }
        }
    }

    public func setExpanded(_ id: ObjectID, _ expanded: Bool) {
        // Not an undoable edit; keeps the panel state with the document.
        guard let i = rig.partIndex(id) else { return }
        var b = bundle
        b.project.rig.parts[i].expanded = expanded
        bundle = b
    }

    public func setPartOpacity(_ id: ObjectID, _ opacity: Float) {
        perform("Opacity") { b in if let i = b.project.rig.partIndex(id) { b.project.rig.parts[i].opacity = clamp(opacity, 0, 1) } }
    }

    public func setBlendMode(_ meshID: ObjectID, _ mode: BlendMode) {
        perform("Blend Mode") { b in if let i = b.project.rig.meshIndex(meshID) { b.project.rig.meshes[i].blendMode = mode } }
    }

    public func setMasks(_ meshID: ObjectID, _ masks: [ObjectID], invert: Bool) {
        perform("Clipping Mask") { b in
            guard let i = b.project.rig.meshIndex(meshID) else { return }
            b.project.rig.meshes[i].maskIDs = masks.filter { $0 != meshID }
            b.project.rig.meshes[i].invertMask = invert
        }
    }

    /// Parent of a hierarchy node (nil = root).
    public func hierarchyParent(of id: ObjectID) -> ObjectID? {
        rig.part(id)?.parentID ?? rig.mesh(id)?.partID
    }

    static func removeFromHierarchy(_ id: ObjectID, _ rig: inout RigModel) {
        rig.rootChildren.removeAll { $0 == id }
        for i in rig.parts.indices { rig.parts[i].children.removeAll { $0 == id } }
    }

    static func setHierarchyParent(_ id: ObjectID, _ parent: ObjectID?, _ rig: inout RigModel) {
        if let i = rig.partIndex(id) { rig.parts[i].parentID = parent }
        if let i = rig.meshIndex(id) { rig.meshes[i].partID = parent }
    }

    /// Move a part or mesh to `parent` at `index` (front-most = 0).
    public func moveNode(_ id: ObjectID, toParent parent: ObjectID?, at index: Int) {
        guard rig.isPart(id) || rig.meshIndex(id) != nil else { return }
        if let parent {
            guard rig.isPart(parent), parent != id else { return }
            // Refuse moving a part into its own subtree.
            var cur: ObjectID? = parent
            while let c = cur { if c == id { return }; cur = rig.part(c)?.parentID }
        }
        perform("Move Layer") { b in
            var r = b.project.rig
            let oldSiblings = r.children(of: hierarchyParent(of: id))
            let oldIndex = oldSiblings.firstIndex(of: id) ?? 0
            Self.removeFromHierarchy(id, &r)
            var idx = index
            if hierarchyParent(of: id) == parent && oldIndex < index { idx -= 1 }
            if let parent, let pi = r.partIndex(parent) {
                r.parts[pi].children.insert(id, at: clamp(idx, 0, r.parts[pi].children.count))
            } else {
                r.rootChildren.insert(id, at: clamp(idx, 0, r.rootChildren.count))
            }
            Self.setHierarchyParent(id, parent, &r)
            b.project.rig = r
        }
    }

    /// Move one step towards the front (-1) or back (+1) among siblings.
    public func nudgeOrder(_ id: ObjectID, by delta: Int) {
        let parent = hierarchyParent(of: id)
        let siblings = rig.children(of: parent)
        guard let i = siblings.firstIndex(of: id) else { return }
        let target = clamp(i + delta, 0, siblings.count - 1)
        guard target != i else { return }
        moveNode(id, toParent: parent, at: delta > 0 ? target + 1 : target)
    }

    /// Wrap the selected parts/meshes in a new part.
    @discardableResult
    public func groupSelection(name: String = "Group") -> ObjectID? {
        let ids = selection.objects.filter { rig.isPart($0) || rig.meshIndex($0) != nil }
        guard let first = ids.first else { return nil }
        let parent = hierarchyParent(of: first)
        let siblings = rig.children(of: parent)
        let insertAt = ids.compactMap { siblings.firstIndex(of: $0) }.min() ?? 0
        let part = Part(name: name, parentID: parent)
        perform("Group") { b in
            var r = b.project.rig
            // Keep the original front-to-back order inside the group.
            let ordered = r.meshesBackToFront().reversed()
            let orderIndex = Dictionary(uniqueKeysWithValues: ordered.enumerated().map { ($1, $0) })
            let sorted = ids.sorted { (orderIndex[r.meshes(inPart: $0).first ?? $0] ?? 0) < (orderIndex[r.meshes(inPart: $1).first ?? $1] ?? 0) }
            for id in ids { Self.removeFromHierarchy(id, &r) }
            var p = part
            p.children = sorted
            r.parts.append(p)
            for id in sorted { Self.setHierarchyParent(id, p.id, &r) }
            if let parent, let pi = r.partIndex(parent) { r.parts[pi].children.insert(p.id, at: min(insertAt, r.parts[pi].children.count)) }
            else { r.rootChildren.insert(p.id, at: min(insertAt, r.rootChildren.count)) }
            b.project.rig = r
        }
        selection.objects = [part.id]
        return part.id
    }

    public func ungroup(_ partID: ObjectID) {
        guard let part = rig.part(partID) else { return }
        perform("Ungroup") { b in
            var r = b.project.rig
            let siblings = r.children(of: part.parentID)
            let at = siblings.firstIndex(of: partID) ?? 0
            Self.removeFromHierarchy(partID, &r)
            for c in part.children { Self.setHierarchyParent(c, part.parentID, &r) }
            if let pp = part.parentID, let pi = r.partIndex(pp) { r.parts[pi].children.insert(contentsOf: part.children, at: min(at, r.parts[pi].children.count)) }
            else { r.rootChildren.insert(contentsOf: part.children, at: min(at, r.rootChildren.count)) }
            r.parts.removeAll { $0.id == partID }
            b.project.rig = r
        }
        selection.objects = part.children
    }

    /// Delete the selected objects (parts delete their contents; deformers re-parent their children).
    public func deleteSelection() {
        let ids = selection.objects
        guard !ids.isEmpty else { return }
        perform("Delete") { b in
            var r = b.project.rig
            var meshIDs = Set<ObjectID>(), partIDs = Set<ObjectID>()
            func collect(_ id: ObjectID) {
                if let p = r.part(id) { partIDs.insert(id); p.children.forEach(collect) } else if r.meshIndex(id) != nil { meshIDs.insert(id) }
            }
            ids.forEach(collect)
            for id in ids where r.deformer(id) != nil { Self.deleteDeformer(id, &r) }
            for id in meshIDs.union(partIDs) { Self.removeFromHierarchy(id, &r) }
            r.meshes.removeAll { meshIDs.contains($0.id) }
            r.parts.removeAll { partIDs.contains($0.id) }
            for i in r.meshes.indices { r.meshes[i].maskIDs.removeAll { meshIDs.contains($0) } }
            // Drop unused textures.
            let used = Set(r.meshes.map(\.textureID))
            for t in r.textures where !used.contains(t.id) { b.textures[t.id] = nil }
            r.textures.removeAll { !used.contains($0.id) }
            b.project.rig = r
        }
        selection = Selection()
    }

    static func deleteDeformer(_ id: ObjectID, _ r: inout RigModel) {
        guard let d = r.deformer(id) else { return }
        for i in r.deformers.indices where r.deformers[i].parentID == id { r.deformers[i].parentID = d.parentID }
        for i in r.meshes.indices where r.meshes[i].deformerID == id { r.meshes[i].deformerID = d.parentID }
        r.deformers.removeAll { $0.id == id }
    }

    public func setCanvasSize(width: Int, height: Int) {
        perform("Canvas Size") { b in b.project.rig.canvasWidth = max(16, width); b.project.rig.canvasHeight = max(16, height) }
    }
}
