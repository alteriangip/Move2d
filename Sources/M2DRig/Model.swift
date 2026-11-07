import M2DCore

public enum BlendMode: String, Codable, Hashable, Sendable, CaseIterable {
    case normal, additive, multiply, screen
}

/// Organisational group in the layer hierarchy (imported from PSD groups).
public struct Part: Codable, Hashable, Identifiable, Sendable {
    public var id: ObjectID
    public var name: String
    public var parentID: ObjectID?
    /// Ordered children (part or mesh ids), front-most first.
    public var children: [ObjectID]
    public var visible: Bool
    public var opacity: Float
    public var locked: Bool
    public var expanded: Bool

    public init(id: ObjectID = IDGenerator.make("part"), name: String, parentID: ObjectID? = nil,
                children: [ObjectID] = [], visible: Bool = true, opacity: Float = 1) {
        self.id = id; self.name = name; self.parentID = parentID; self.children = children
        self.visible = visible; self.opacity = opacity; locked = false; expanded = true
    }
}

/// Reference to a texture image stored alongside the model.
public struct TextureInfo: Codable, Hashable, Identifiable, Sendable {
    public var id: ObjectID
    public var name: String
    public var width: Int
    public var height: Int
    public init(id: ObjectID = IDGenerator.make("tex"), name: String, width: Int, height: Int) {
        self.id = id; self.name = name; self.width = width; self.height = height
    }
}

/// A drawable piece of artwork: a textured mesh that can be deformed.
public struct ArtMesh: Codable, Hashable, Identifiable, Sendable {
    public var id: ObjectID
    public var name: String
    /// Layer-hierarchy parent.
    public var partID: ObjectID?
    /// Deformation parent; nil means the canvas.
    public var deformerID: ObjectID?
    public var textureID: ObjectID
    /// Where the texture sits on the canvas in rest pose.
    public var textureRect: Rect
    public var mesh: Mesh
    public var keyforms: KeyformGrid<MeshForm>
    public var visible: Bool
    public var locked: Bool
    public var blendMode: BlendMode
    /// Meshes whose coverage clips this one (PSD clipping masks map here).
    public var maskIDs: [ObjectID]
    public var invertMask: Bool
    /// Photoshop layer id this mesh was imported from, for re-import.
    public var sourceLayerID: Int?

    public init(id: ObjectID = IDGenerator.make("mesh"), name: String, textureID: ObjectID, textureRect: Rect,
                mesh: Mesh? = nil, partID: ObjectID? = nil, deformerID: ObjectID? = nil) {
        self.id = id; self.name = name; self.textureID = textureID; self.textureRect = textureRect
        let m = mesh ?? Mesh.quad(textureRect)
        self.mesh = m
        keyforms = KeyformGrid(rest: MeshForm(offsets: [Vec2](repeating: .zero, count: m.vertexCount)))
        self.partID = partID; self.deformerID = deformerID
        visible = true; locked = false; blendMode = .normal; maskIDs = []; invertMask = false
    }

    /// Replace the mesh topology. Keyform offsets are carried over using
    /// `sources` when given, otherwise reset to zero.
    public mutating func setMesh(_ m: Mesh, sources: [Mesh.VertexSource]? = nil) {
        let oldCount = mesh.vertexCount
        keyforms.mapForms { form in
            guard let sources, form.offsets.count == oldCount else {
                form.offsets = [Vec2](repeating: .zero, count: m.vertexCount); return
            }
            form.offsets = sources.map { src in
                switch src {
                case let .existing(i): return i < form.offsets.count ? form.offsets[i] : .zero
                case let .interpolated(ids, ws):
                    var o = Vec2.zero
                    for (i, w) in zip(ids, ws) where i < form.offsets.count { o += form.offsets[i] * w }
                    return o
                case .new: return .zero
                }
            }
        }
        mesh = m
    }

    /// Positions for one keyform (rest + offsets).
    public func positions(form: MeshForm) -> [Vec2] {
        var out = mesh.vertices
        for i in 0..<min(out.count, form.offsets.count) { out[i] += form.offsets[i] }
        return out
    }
}

/// The complete rig: artwork, hierarchy, deformers and parameters.
public struct RigModel: Codable, Hashable, Sendable {
    public var name: String
    public var canvasWidth: Int
    public var canvasHeight: Int
    public var parts: [Part]
    public var meshes: [ArtMesh]
    public var deformers: [Deformer]
    public var parameters: [Parameter]
    public var textures: [TextureInfo]
    /// Top-level hierarchy (part or mesh ids), front-most first.
    public var rootChildren: [ObjectID]

    public init(name: String = "Untitled", canvasWidth: Int = 2048, canvasHeight: Int = 2048) {
        self.name = name; self.canvasWidth = canvasWidth; self.canvasHeight = canvasHeight
        parts = []; meshes = []; deformers = []; parameters = []; textures = []; rootChildren = []
    }

    public var canvasRect: Rect { Rect(x: 0, y: 0, width: Float(canvasWidth), height: Float(canvasHeight)) }

    // MARK: Lookup

    public func meshIndex(_ id: ObjectID) -> Int? { meshes.firstIndex { $0.id == id } }
    public func partIndex(_ id: ObjectID) -> Int? { parts.firstIndex { $0.id == id } }
    public func deformerIndex(_ id: ObjectID) -> Int? { deformers.firstIndex { $0.id == id } }
    public func parameterIndex(_ id: ObjectID) -> Int? { parameters.firstIndex { $0.id == id } }
    public func mesh(_ id: ObjectID) -> ArtMesh? { meshIndex(id).map { meshes[$0] } }
    public func part(_ id: ObjectID) -> Part? { partIndex(id).map { parts[$0] } }
    public func deformer(_ id: ObjectID) -> Deformer? { deformerIndex(id).map { deformers[$0] } }
    public func parameter(_ id: ObjectID) -> Parameter? { parameterIndex(id).map { parameters[$0] } }

    public func isPart(_ id: ObjectID) -> Bool { partIndex(id) != nil }

    /// Children of a hierarchy node (nil = root), front-most first.
    public func children(of partID: ObjectID?) -> [ObjectID] {
        guard let partID else { return rootChildren }
        return part(partID)?.children ?? []
    }

    /// Mesh ids in hierarchy order, back-most first (default paint order).
    public func meshesBackToFront() -> [ObjectID] {
        var out: [ObjectID] = []
        func walk(_ ids: [ObjectID]) {
            for id in ids.reversed() {
                if let p = part(id) { walk(p.children) } else if meshIndex(id) != nil { out.append(id) }
            }
        }
        walk(rootChildren)
        return out
    }

    /// All meshes inside a part subtree.
    public func meshes(inPart id: ObjectID) -> [ObjectID] {
        guard let p = part(id) else { return meshIndex(id) != nil ? [id] : [] }
        return p.children.flatMap { meshes(inPart: $0) }
    }

    /// Deformer ancestors from immediate parent to root.
    public func deformerChain(from id: ObjectID?) -> [ObjectID] {
        var out: [ObjectID] = []
        var cur = id
        var guardSet = Set<ObjectID>()
        while let c = cur, let d = deformer(c), guardSet.insert(c).inserted {
            out.append(c); cur = d.parentID
        }
        return out
    }

    /// True when making `child` a child of `parent` would create a cycle.
    public func wouldCreateCycle(deformer child: ObjectID, parent: ObjectID?) -> Bool {
        guard let parent else { return false }
        return deformerChain(from: parent).contains(child)
    }

    /// Deformers ordered so parents come before children.
    public func deformersTopological() -> [Deformer] {
        var out: [Deformer] = [], done = Set<ObjectID>()
        func visit(_ d: Deformer, depth: Int) {
            guard !done.contains(d.id), depth < 256 else { return }
            if let p = d.parentID, let pd = deformer(p) { visit(pd, depth: depth + 1) }
            done.insert(d.id); out.append(d)
        }
        for d in deformers { visit(d, depth: 0) }
        return out
    }

    /// Ids of all objects bound to a parameter.
    public func objectsBound(to parameterID: ObjectID) -> [ObjectID] {
        meshes.filter { $0.keyforms.binding(for: parameterID) != nil }.map(\.id)
            + deformers.filter { d in d.bindings.contains { $0.parameterID == parameterID } }.map(\.id)
    }

    public func defaultParameterValues() -> ParameterValues { .defaults(parameters) }
}
