import Foundation
import M2DCore
import M2DPSD
import M2DRig
import M2DAnimation

/// Turns a layered PSD into a rig-ready project: PSD groups become Parts,
/// pixel layers become ArtMeshes with their own trimmed textures, and
/// clipping layers become mesh masks.
public enum PSDImporter {
    public enum MeshMode: Hashable, Sendable {
        /// Two-triangle quad per layer (fast; refine later in the mesh editor).
        case quad
        /// Outline-following mesh with the given vertex spacing (canvas px).
        case automatic(spacing: Float)
    }

    public struct Options: Sendable {
        public var meshMode: MeshMode = .automatic(spacing: 48)
        /// Add the conventional character parameters (Angle X/Y/Z, eyes, mouth, breath…).
        public var addStandardParameters = true
        /// Import hidden layers (kept hidden) instead of skipping them.
        public var includeHiddenLayers = true
        /// Transparent padding kept around trimmed textures, in pixels.
        public var texturePadding = 2
        public init() {}
    }

    public struct Result: Sendable {
        public var bundle: ProjectBundle
        public var warnings: [String]
    }

    public static func importPSD(_ data: [UInt8], fileName: String? = nil, options: Options = Options()) throws -> Result {
        let doc = try PSDParser.parse(data)
        return importDocument(doc, fileName: fileName, options: options)
    }

    public static func importDocument(_ doc: PSDDocument, fileName: String? = nil, options: Options = Options()) -> Result {
        var warnings = doc.warnings
        let baseName = fileName.map { ($0 as NSString).deletingPathExtension } ?? "Character"
        var rig = RigModel(name: baseName, canvasWidth: doc.width, canvasHeight: doc.height)
        var textures: [ObjectID: RGBAImage] = [:]
        if options.addStandardParameters { rig.parameters = Parameter.standardSet() }

        func importLayers(_ layers: [PSDLayer], parent: ObjectID?) -> [ObjectID] {
            var ids: [ObjectID] = []
            // Clipping: a clipped layer clips to the closest non-clipped layer *below* it.
            // Layers are listed top to bottom, so walk bottom-up to know the base.
            var created: [(layer: PSDLayer, id: ObjectID?)] = []
            for layer in layers {
                if !layer.visible && !options.includeHiddenLayers { created.append((layer, nil)); continue }
                switch layer.kind {
                case .group:
                    var part = Part(name: layer.name, parentID: parent, visible: layer.visible, opacity: layer.opacity)
                    part.expanded = !layer.collapsed
                    let pid = part.id
                    rig.parts.append(part)
                    let children = importLayers(layer.children, parent: pid)
                    if let i = rig.partIndex(pid) { rig.parts[i].children = children }
                    if layer.blendMode != .passThrough && layer.blendMode != .normal {
                        warnings.append("Group \"\(layer.name)\": blend mode \(layer.blendMode) is applied per layer, not to the group.")
                    }
                    created.append((layer, pid))
                case .pixel:
                    guard let img = layer.image, layer.width > 0, layer.height > 0,
                          let b = img.opaqueBounds() else {
                        warnings.append("Layer \"\(layer.name)\" is empty and was skipped.")
                        created.append((layer, nil)); continue
                    }
                    let pad = options.texturePadding
                    let cropped = img.cropped(x: b.x - pad, y: b.y - pad, width: b.width + 2 * pad, height: b.height + 2 * pad)
                    let tex = TextureInfo(name: layer.name, width: cropped.width, height: cropped.height)
                    textures[tex.id] = cropped
                    rig.textures.append(tex)
                    let rect = Rect(x: Float(layer.left + b.x - pad), y: Float(layer.top + b.y - pad),
                                    width: Float(cropped.width), height: Float(cropped.height))
                    let mesh: Mesh
                    switch options.meshMode {
                    case .quad: mesh = .quad(rect)
                    case let .automatic(spacing):
                        mesh = MeshGenerator.generate(image: cropped, rect: rect, settings: .init(spacing: spacing))
                    }
                    var art = ArtMesh(name: layer.name, textureID: tex.id, textureRect: rect, mesh: mesh, partID: parent)
                    art.visible = layer.visible
                    art.sourceLayerID = layer.layerID
                    art.keyforms.forms[0].opacity = layer.opacity
                    switch layer.blendMode {
                    case .normal, .passThrough: art.blendMode = .normal
                    case .multiply: art.blendMode = .multiply
                    case .linearDodge, .colorDodge: art.blendMode = .additive
                    case .screen, .lighten: art.blendMode = .screen
                    default:
                        art.blendMode = .normal
                        warnings.append("Layer \"\(layer.name)\": blend mode \(layer.blendMode) is not supported and was imported as Normal.")
                    }
                    rig.meshes.append(art)
                    created.append((layer, art.id))
                }
            }
            // Resolve clipping, bottom-up.
            var base: ObjectID?
            for (layer, id) in created.reversed() {
                guard let id else { continue }
                if layer.clipped, layer.kind == .pixel, let base, let mi = rig.meshIndex(id) {
                    rig.meshes[mi].maskIDs = [base]
                } else if !layer.clipped {
                    base = layer.kind == .pixel ? id : nil
                }
            }
            ids = created.compactMap(\.id)
            return ids
        }

        rig.rootChildren = importLayers(doc.layers, parent: nil)
        var project = Project(rig: rig, metadata: .init(sourceFileName: fileName))
        if options.addStandardParameters {
            project.animations = [AnimationPresets.idle(for: rig.parameters)]
        }
        return Result(bundle: ProjectBundle(project: project, textures: textures), warnings: warnings)
    }

    /// Replace artwork from an updated PSD while keeping the rig. Layers are
    /// matched by Photoshop layer id, then by name. Returns the names of meshes updated.
    @discardableResult
    public static func updateArtwork(_ bundle: inout ProjectBundle, from doc: PSDDocument, padding: Int = 2) -> [String] {
        let layers = doc.layers.flatMap(\.flattenedPixelLayers)
        var updated: [String] = []
        for i in bundle.project.rig.meshes.indices {
            let m = bundle.project.rig.meshes[i]
            guard let layer = layers.first(where: { m.sourceLayerID != nil && $0.layerID == m.sourceLayerID })
                    ?? layers.first(where: { $0.name == m.name }),
                  let img = layer.image, let b = img.opaqueBounds() else { continue }
            let cropped = img.cropped(x: b.x - padding, y: b.y - padding, width: b.width + 2 * padding, height: b.height + 2 * padding)
            let rect = Rect(x: Float(layer.left + b.x - padding), y: Float(layer.top + b.y - padding),
                            width: Float(cropped.width), height: Float(cropped.height))
            bundle.textures[m.textureID] = cropped
            if let ti = bundle.project.rig.textures.firstIndex(where: { $0.id == m.textureID }) {
                bundle.project.rig.textures[ti].width = cropped.width
                bundle.project.rig.textures[ti].height = cropped.height
            }
            bundle.project.rig.meshes[i].textureRect = rect
            bundle.project.rig.meshes[i].mesh.recomputeUVs(textureRect: rect)
            updated.append(m.name)
        }
        return updated
    }
}
