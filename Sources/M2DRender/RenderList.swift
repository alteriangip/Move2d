import M2DCore
import M2DRig

/// One textured mesh draw, already deformed, in canvas space.
public struct DrawCommand: Sendable {
    public var meshID: ObjectID
    public var textureID: ObjectID
    public var positions: [Vec2]
    public var uvs: [Vec2]
    public var indices: [UInt32]
    public var opacity: Float
    public var blendMode: BlendMode
    /// Indices into the same command list of meshes clipping this one.
    public var masks: [MaskShape]
    public var invertMask: Bool
}

/// Geometry used as a clipping mask.
public struct MaskShape: Sendable {
    public var textureID: ObjectID
    public var positions: [Vec2]
    public var uvs: [Vec2]
    public var indices: [UInt32]
}

public enum RenderListBuilder {
    /// Build draw commands back-to-front for a pose.
    public static func build(model: RigModel, pose: RigPose, hiddenMeshes: Set<ObjectID> = []) -> [DrawCommand] {
        var out: [DrawCommand] = []
        out.reserveCapacity(pose.drawOrder.count)
        for id in pose.drawOrder {
            guard !hiddenMeshes.contains(id), let m = model.mesh(id), let mp = pose.meshes[id],
                  mp.visible, mp.opacity > 0.001, m.mesh.triangleCount > 0 else { continue }
            let masks: [MaskShape] = m.maskIDs.compactMap { mid in
                guard let mm = model.mesh(mid), let pp = pose.meshes[mid] else { return nil }
                return MaskShape(textureID: mm.textureID, positions: pp.positions, uvs: mm.mesh.uvs, indices: mm.mesh.indices)
            }
            out.append(DrawCommand(meshID: id, textureID: m.textureID, positions: mp.positions, uvs: m.mesh.uvs,
                                   indices: m.mesh.indices, opacity: mp.opacity, blendMode: m.blendMode,
                                   masks: masks, invertMask: m.invertMask))
        }
        return out
    }
}
