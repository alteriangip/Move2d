import Foundation
import M2DCore
import M2DRig

extension EditorSession {
    // MARK: Parameter definitions

    @discardableResult
    public func addParameter(name: String, min: Float = -1, max: Float = 1, default def: Float = 0, group: String = "") -> ObjectID {
        let p = Parameter(name: name, min: min, max: max, default: def, group: group)
        perform("Add Parameter") { b in b.project.rig.parameters.append(p) }
        parameterValues[p.id] = p.defaultValue
        return p.id
    }

    public func updateParameter(_ id: ObjectID, min: Float? = nil, max: Float? = nil, default def: Float? = nil, group: String? = nil, cyclic: Bool? = nil) {
        perform("Edit Parameter") { b in
            guard let i = b.project.rig.parameterIndex(id) else { return }
            var p = b.project.rig.parameters[i]
            if let min { p.minValue = min }
            if let max { p.maxValue = max }
            if p.maxValue <= p.minValue { p.maxValue = p.minValue + 1 }
            if let def { p.defaultValue = def }
            p.defaultValue = Swift.min(Swift.max(p.defaultValue, p.minValue), p.maxValue)
            if let group { p.group = group }
            if let cyclic { p.isCyclic = cyclic }
            b.project.rig.parameters[i] = p
        }
    }

    /// Delete a parameter, collapsing bound keyforms at its default value.
    public func deleteParameter(_ id: ObjectID) {
        guard let p = rig.parameter(id) else { return }
        perform("Delete Parameter") { b in
            var r = b.project.rig
            for i in r.meshes.indices { r.meshes[i].keyforms.removeBinding(id, keeping: p.defaultValue) }
            for i in r.deformers.indices {
                switch r.deformers[i].kind {
                case var .warp(w): w.keyforms.removeBinding(id, keeping: p.defaultValue); r.deformers[i].kind = .warp(w)
                case var .rotation(ro): ro.keyforms.removeBinding(id, keeping: p.defaultValue); r.deformers[i].kind = .rotation(ro)
                }
            }
            r.parameters.removeAll { $0.id == id }
            b.project.rig = r
            for c in b.project.animations.indices { b.project.animations[c].tracks.removeAll { $0.parameterID == id } }
            for g in b.project.physics.groups.indices {
                b.project.physics.groups[g].inputs.removeAll { $0.parameterID == id }
                b.project.physics.groups[g].outputs.removeAll { $0.parameterID == id }
            }
        }
        parameterValues[id] = nil
    }

    public func moveParameter(_ id: ObjectID, to index: Int) {
        perform("Reorder Parameters") { b in
            guard let i = b.project.rig.parameterIndex(id) else { return }
            let p = b.project.rig.parameters.remove(at: i)
            b.project.rig.parameters.insert(p, at: clamp(index, 0, b.project.rig.parameters.count))
        }
    }

    /// Adds any standard parameters (Angle X/Y/Z, eyes, mouth…) that are missing.
    public func addStandardParameters() {
        let existing = Set(rig.parameters.map(\.id))
        let missing = Parameter.standardSet().filter { !existing.contains($0.id) }
        guard !missing.isEmpty else { return }
        perform("Add Standard Parameters") { b in b.project.rig.parameters += missing }
        for p in missing { parameterValues[p.id] = p.defaultValue }
    }

    // MARK: Binding objects to parameters

    /// Generic access to an object's keyform bindings.
    public func bindings(of objectID: ObjectID) -> [ParameterBinding] {
        rig.mesh(objectID)?.keyforms.bindings ?? rig.deformer(objectID)?.bindings ?? []
    }

    func mutateKeyforms(_ objectIDs: [ObjectID], _ name: String,
                        mesh: @escaping (inout KeyformGrid<MeshForm>) -> Void,
                        warp: @escaping (inout KeyformGrid<WarpForm>) -> Void,
                        rotation: @escaping (inout KeyformGrid<RotationForm>) -> Void) {
        perform(name) { b in
            for id in objectIDs {
                if let i = b.project.rig.meshIndex(id) { mesh(&b.project.rig.meshes[i].keyforms) }
                else if let i = b.project.rig.deformerIndex(id) {
                    switch b.project.rig.deformers[i].kind {
                    case var .warp(w): warp(&w.keyforms); b.project.rig.deformers[i].kind = .warp(w)
                    case var .rotation(r): rotation(&r.keyforms); b.project.rig.deformers[i].kind = .rotation(r)
                    }
                }
            }
        }
    }

    /// Default key positions for a new binding: min/default/max (2 keys when default sits at an end).
    public func defaultKeys(for p: Parameter) -> [Float] {
        var keys = [p.minValue, p.maxValue]
        if p.defaultValue > p.minValue && p.defaultValue < p.maxValue { keys.insert(p.defaultValue, at: 1) }
        return keys
    }

    /// Bind the selected objects (or `objectIDs`) to a parameter with keys at min/default/max.
    public func bind(_ objectIDs: [ObjectID]? = nil, to parameterID: ObjectID, keys: [Float]? = nil) {
        guard let p = rig.parameter(parameterID) else { return }
        let ids = objectIDs ?? selectionForKeyforms
        guard !ids.isEmpty else { notice = "Select meshes or deformers to bind."; return }
        let k = keys ?? defaultKeys(for: p)
        mutateKeyforms(ids, "Bind \(p.name)",
                       mesh: { $0.addBinding(parameterID, keys: k) },
                       warp: { $0.addBinding(parameterID, keys: k) },
                       rotation: { $0.addBinding(parameterID, keys: k) })
    }

    public func unbind(_ objectIDs: [ObjectID]? = nil, from parameterID: ObjectID) {
        let ids = objectIDs ?? selectionForKeyforms
        let keep = value(of: parameterID)
        mutateKeyforms(ids, "Unbind",
                       mesh: { $0.removeBinding(parameterID, keeping: keep) },
                       warp: { $0.removeBinding(parameterID, keeping: keep) },
                       rotation: { $0.removeBinding(parameterID, keeping: keep) })
    }

    /// Add a key at the parameter's current value to the selected objects (binding them if needed).
    public func addKeyAtCurrentValue(_ parameterID: ObjectID, objectIDs: [ObjectID]? = nil) {
        guard let p = rig.parameter(parameterID) else { return }
        let ids = objectIDs ?? selectionForKeyforms
        guard !ids.isEmpty else { notice = "Select meshes or deformers to add a key to."; return }
        let v = value(of: parameterID)
        let unbound = ids.filter { id in !bindings(of: id).contains { $0.parameterID == parameterID } }
        if !unbound.isEmpty {
            let keys = Array(Set([p.defaultValue, v])).sorted()
            mutateKeyforms(unbound, "Bind \(p.name)",
                           mesh: { $0.addBinding(parameterID, keys: keys) },
                           warp: { $0.addBinding(parameterID, keys: keys) },
                           rotation: { $0.addBinding(parameterID, keys: keys) })
        }
        mutateKeyforms(ids, "Add Key",
                       mesh: { $0.addKey(parameterID, value: v) },
                       warp: { $0.addKey(parameterID, value: v) },
                       rotation: { $0.addKey(parameterID, value: v) })
    }

    public func removeKeyAtCurrentValue(_ parameterID: ObjectID, objectIDs: [ObjectID]? = nil) {
        let ids = objectIDs ?? selectionForKeyforms
        let v = value(of: parameterID)
        mutateKeyforms(ids, "Remove Key",
                       mesh: { $0.removeKey(parameterID, value: v) },
                       warp: { $0.removeKey(parameterID, value: v) },
                       rotation: { $0.removeKey(parameterID, value: v) })
    }

    /// Objects keyform operations apply to: selected meshes/deformers (parts expand to meshes).
    public var selectionForKeyforms: [ObjectID] {
        selectedMeshIDs + selection.objects.filter { rig.deformer($0) != nil }
    }

    /// Key positions of `parameterID` across the given objects (for slider tick marks).
    public func keys(of parameterID: ObjectID, for objectIDs: [ObjectID]? = nil) -> [Float] {
        let ids = objectIDs ?? selectionForKeyforms
        var set = Set<Float>()
        for id in ids { for b in bindings(of: id) where b.parameterID == parameterID { set.formUnion(b.keys) } }
        return set.sorted()
    }

    /// All keys of a parameter across the whole rig.
    public func allKeys(of parameterID: ObjectID) -> [Float] {
        keys(of: parameterID, for: rig.meshes.map(\.id) + rig.deformers.map(\.id))
    }

    /// Snap a parameter to its nearest key among the selection (useful before editing).
    public func snapToNearestKey(_ parameterID: ObjectID) {
        let ks = keys(of: parameterID).isEmpty ? allKeys(of: parameterID) : keys(of: parameterID)
        let v = value(of: parameterID)
        guard let k = ks.min(by: { abs($0 - v) < abs($1 - v) }) else { return }
        setParameterValue(parameterID, k, fromUser: false)
    }

    // MARK: Mesh keyform properties

    public func setMeshFormOpacity(_ meshID: ObjectID, _ opacity: Float) {
        guard let fi = editableFormIndex(meshID) else { notice = keyformBlocker(meshID); return }
        perform("Mesh Opacity") { b in
            guard let i = b.project.rig.meshIndex(meshID) else { return }
            b.project.rig.meshes[i].keyforms.forms[fi].opacity = clamp(opacity, 0, 1)
        }
    }

    public func setMeshFormDrawOrder(_ meshID: ObjectID, _ order: Float) {
        guard let fi = editableFormIndex(meshID) else { notice = keyformBlocker(meshID); return }
        perform("Draw Order") { b in
            guard let i = b.project.rig.meshIndex(meshID) else { return }
            b.project.rig.meshes[i].keyforms.forms[fi].drawOrder = clamp(order, 0, 1000)
        }
    }
}
