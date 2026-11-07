import Foundation
import M2DCore
import M2DRig
import M2DAnimation
import M2DPhysics
import M2DProject

extension EditorSession {
    /// Set the current keyform of a mesh from a function of each vertex's rest position.
    public func shapeKeyform(_ meshID: ObjectID, _ offset: (Vec2) -> Vec2) {
        guard let fi = editableFormIndex(meshID) else { notice = keyformBlocker(meshID); return }
        perform("Shape") { b in
            guard let i = b.project.rig.meshIndex(meshID) else { return }
            let verts = b.project.rig.meshes[i].mesh.vertices
            b.project.rig.meshes[i].keyforms.forms[fi].offsets = verts.map(offset)
        }
    }

    /// Set the current keyform of a warp from a function of each rest control point.
    public func shapeWarp(_ id: ObjectID, _ f: (Vec2) -> Vec2) {
        guard let fi = editableFormIndex(id) else { notice = keyformBlocker(id); return }
        perform("Shape Warp") { b in
            guard let i = b.project.rig.deformerIndex(id), case var .warp(w) = b.project.rig.deformers[i].kind else { return }
            w.keyforms.forms[fi].points = w.restPoints.map { $0 + f($0) }
            b.project.rig.deformers[i].kind = .warp(w)
        }
    }

    func meshID(named n: String) -> ObjectID? { rig.meshes.first { $0.name == n }?.id }
    func partID(named n: String) -> ObjectID? { rig.parts.first { $0.name == n }?.id }
}

public enum SampleRig {
    /// The sample character, imported and fully rigged through the editor API.
    public static func makeSession(size: Int = 1024) throws -> EditorSession {
        var opts = PSDImporter.Options()
        opts.meshMode = .automatic(spacing: Float(size) / 24)
        let (s, _) = try EditorSession.importingPSD(SampleCharacter.psdData(size: size), fileName: "Sample Character.psd", options: opts)
        rig(s, scale: Float(size) / 1024)
        s.markSaved()
        return s
    }

    static func rig(_ s: EditorSession, scale k: Float) {
        func P(_ x: Float, _ y: Float) -> Vec2 { Vec2(x * k, y * k) }
        guard let head = s.partID(named: "Head") else { return }

        // Body rotation (root of everything) and breathing.
        s.selection.objects = s.rig.rootChildren
        let bodyRot = s.createRotationDeformer(name: "Body Rotation", pivot: P(512, 1000))!
        s.bind([bodyRot], to: "ParamBodyAngleZ")
        for (v, a): (Float, Float) in [(-10, -4), (10, 4)] {
            s.setParameterValue("ParamBodyAngleZ", v, fromUser: false); s.setRotationForm(bodyRot, angle: a)
        }
        s.setParameterValue("ParamBodyAngleZ", 0, fromUser: false)

        if let body = s.meshID(named: "Body") {
            s.bind([body], to: "ParamBreath")
            s.setParameterValue("ParamBreath", 1, fromUser: false)
            s.shapeKeyform(body) { p in Vec2(0, -max(0, (1020 * k - p.y) / (360 * k)) * 6 * k) }
            s.setParameterValue("ParamBreath", 0, fromUser: false)
            s.bind([body], to: "ParamBodyAngleX")
            for v: Float in [-10, 10] {
                s.setParameterValue("ParamBodyAngleX", v, fromUser: false)
                s.shapeKeyform(body) { p in Vec2(v * 0.8 * k * max(0, (1020 * k - p.y) / (360 * k)), 0) }
            }
            s.setParameterValue("ParamBodyAngleX", 0, fromUser: false)
        }

        // Head: rotation (Angle Z) → warp (Angle X / Y).
        s.selection.objects = [head]
        let headRot = s.createRotationDeformer(name: "Head Rotation", pivot: P(512, 630))!
        s.bind([headRot], to: "ParamAngleZ")
        for (v, a): (Float, Float) in [(-30, -12), (30, 12)] {
            s.setParameterValue("ParamAngleZ", v, fromUser: false); s.setRotationForm(headRot, angle: a)
        }
        s.setParameterValue("ParamAngleZ", 0, fromUser: false)

        s.selection.objects = [head]
        let headWarp = s.createWarpDeformer(name: "Head Warp", columns: 4, rows: 4)!
        s.bind([headWarp], to: "ParamAngleX")
        s.bind([headWarp], to: "ParamAngleY")
        let c = P(512, 430)
        for x: Float in [-30, 0, 30] { for y: Float in [-30, 0, 30] where !(x == 0 && y == 0) {
            s.setParameterValue("ParamAngleX", x, fromUser: false)
            s.setParameterValue("ParamAngleY", y, fromUser: false)
            s.shapeWarp(headWarp) { p in
                // Fake 3D turn: the middle of the face moves more than the edges.
                let d = p - c
                let bulgeX = max(0, 1 - abs(d.x) / (260 * k)), bulgeY = max(0, 1 - abs(d.y) / (300 * k))
                return Vec2(x / 30 * 34 * k * (0.35 + 0.65 * bulgeX) * (0.6 + 0.4 * bulgeY),
                            y / 30 * 26 * k * (0.35 + 0.65 * bulgeY) * (0.6 + 0.4 * bulgeX))
            }
        }}
        s.setParameterValue("ParamAngleX", 0, fromUser: false); s.setParameterValue("ParamAngleY", 0, fromUser: false)

        // Eyes: blink compresses towards the eye line; irises follow the eyeballs.
        for (side, param) in [("L", "ParamEyeLOpen"), ("R", "ParamEyeROpen")] {
            let ids = ["Eye \(side) White", "Eye \(side) Iris"].compactMap { s.meshID(named: $0) }
            s.bind(ids, to: param)
            s.setParameterValue(param, 0, fromUser: false)
            for id in ids { s.shapeKeyform(id) { p in Vec2(0, (448 * k - p.y) * 0.92) } }
            s.setParameterValue(param, 1, fromUser: false)
            if let iris = s.meshID(named: "Eye \(side) Iris") {
                s.bind([iris], to: "ParamEyeBallX")
                s.bind([iris], to: "ParamEyeBallY")
                for ex: Float in [-1, 0, 1] { for ey: Float in [-1, 0, 1] where !(ex == 0 && ey == 0) {
                    s.setParameterValue("ParamEyeBallX", ex, fromUser: false); s.setParameterValue("ParamEyeBallY", ey, fromUser: false)
                    for eo: Float in [0, 1] {
                        s.setParameterValue(param, eo, fromUser: false)
                        s.shapeKeyform(iris) { p in
                            let blink = eo == 0 ? Vec2(0, (448 * k - p.y) * 0.92) : .zero
                            return blink + Vec2(ex * 14 * k, ey * 9 * k)
                        }
                    }
                }}
                s.setParameterValue("ParamEyeBallX", 0, fromUser: false); s.setParameterValue("ParamEyeBallY", 0, fromUser: false)
                s.setParameterValue(param, 1, fromUser: false)
            }
        }
        // Lashes: one mesh, two parameters (a 2×2 keyform grid).
        if let lashes = s.meshID(named: "Eyelashes") {
            s.bind([lashes], to: "ParamEyeLOpen"); s.bind([lashes], to: "ParamEyeROpen")
            for l: Float in [0, 1] { for r: Float in [0, 1] where !(l == 1 && r == 1) {
                s.setParameterValue("ParamEyeLOpen", l, fromUser: false); s.setParameterValue("ParamEyeROpen", r, fromUser: false)
                s.shapeKeyform(lashes) { p in
                    let closed = p.x < 512 * k ? l == 0 : r == 0
                    return closed ? Vec2(0, 40 * k) : .zero
                }
            }}
            s.setParameterValue("ParamEyeLOpen", 1, fromUser: false); s.setParameterValue("ParamEyeROpen", 1, fromUser: false)
        }

        // Brows and mouth.
        for (n, param) in [("Brow L", "ParamBrowLY"), ("Brow R", "ParamBrowRY")] {
            guard let id = s.meshID(named: n) else { continue }
            s.bind([id], to: param)
            for v: Float in [-1, 1] { s.setParameterValue(param, v, fromUser: false); s.shapeKeyform(id) { _ in Vec2(0, -v * 12 * k) } }
            s.setParameterValue(param, 0, fromUser: false)
        }
        if let mouth = s.meshID(named: "Mouth") {
            s.bind([mouth], to: "ParamMouthOpenY")
            s.setParameterValue("ParamMouthOpenY", 1, fromUser: false)
            s.shapeKeyform(mouth) { p in Vec2((p.x - 512 * k) * -0.25, (p.y - 545 * k) * 1.6) }
            s.setParameterValue("ParamMouthOpenY", 0, fromUser: false)
            s.bind([mouth], to: "ParamMouthForm")
            for v: Float in [-1, 1] {
                s.setParameterValue("ParamMouthForm", v, fromUser: false)
                s.shapeKeyform(mouth) { p in Vec2(0, v * -((p.x - 512 * k) / (30 * k)) * ((p.x - 512 * k) / (30 * k)) * 5 * k) }
            }
            s.setParameterValue("ParamMouthForm", 0, fromUser: false)
        }

        // Hair sway warps driven by physics.
        func hairWarp(_ meshName: String, _ param: ObjectID, amount: Float) {
            guard let id = s.meshID(named: meshName) else { return }
            s.selection.objects = [id]
            guard let w = s.createWarpDeformer(name: "\(meshName) Sway", columns: 3, rows: 3) else { return }
            s.bind([w], to: param)
            guard let rect = s.rig.deformer(w)?.warp?.rect else { return }
            for v: Float in [-1, 1] {
                s.setParameterValue(param, v, fromUser: false)
                s.shapeWarp(w) { p in
                    let t = max(0, (p.y - rect.minY) / rect.height)
                    return Vec2(v * amount * k * t * t, -abs(v) * 4 * k * t)
                }
            }
            s.setParameterValue(param, 0, fromUser: false)
        }
        hairWarp("Hair Front", "ParamHairFront", amount: 30)
        hairWarp("Hair Back", "ParamHairBack", amount: 44)
        s.addPhysicsGroup(.hair(name: "Front Hair", output: "ParamHairFront", segments: 2))
        var back = PhysicsGroup.hair(name: "Back Hair", output: "ParamHairBack", segments: 3)
        back.particles = back.particles.map { var p = $0; p.length = 12; p.damping = 0.3; return p }
        s.addPhysicsGroup(back)

        // Animations: idle, look-around and a talk loop.
        var look = AnimationClip(name: "Look Around", duration: 4, loopMode: .loop)
        look.tracks = [
            ParameterTrack(parameterID: "ParamAngleX", keyframes: [Keyframe(time: 0, value: 0), Keyframe(time: 1, value: 25), Keyframe(time: 2.2, value: -25), Keyframe(time: 4, value: 0)]),
            ParameterTrack(parameterID: "ParamAngleY", keyframes: [Keyframe(time: 0, value: 0), Keyframe(time: 1.6, value: 12), Keyframe(time: 3, value: -8), Keyframe(time: 4, value: 0)]),
            ParameterTrack(parameterID: "ParamEyeBallX", keyframes: [Keyframe(time: 0, value: 0), Keyframe(time: 0.8, value: 0.9), Keyframe(time: 2, value: -0.9), Keyframe(time: 4, value: 0)]),
            ParameterTrack(parameterID: "ParamAngleZ", keyframes: [Keyframe(time: 0, value: 0), Keyframe(time: 1.2, value: 8), Keyframe(time: 2.6, value: -8), Keyframe(time: 4, value: 0)]),
            AnimationPresets.blinks(parameterID: "ParamEyeLOpen", at: [2.9], duration: 4),
            AnimationPresets.blinks(parameterID: "ParamEyeROpen", at: [2.9], duration: 4),
            AnimationPresets.breathing(parameterID: "ParamBreath", period: 4),
        ]
        var talk = AnimationClip(name: "Talk", duration: 2, loopMode: .loop)
        let mouthKeys: [(Double, Float)] = [(0, 0), (0.15, 0.8), (0.3, 0.2), (0.45, 1), (0.6, 0.1), (0.8, 0.7), (1.0, 0), (1.3, 0.9), (1.5, 0.3), (1.7, 0.6), (2, 0)]
        talk.tracks = [
            ParameterTrack(parameterID: "ParamMouthOpenY", keyframes: mouthKeys.map { Keyframe(time: $0.0, value: $0.1, interpolation: .easeInOut) }),
            ParameterTrack(parameterID: "ParamBrowLY", keyframes: [Keyframe(time: 0, value: 0), Keyframe(time: 0.5, value: 0.6), Keyframe(time: 2, value: 0)]),
            ParameterTrack(parameterID: "ParamBrowRY", keyframes: [Keyframe(time: 0, value: 0), Keyframe(time: 0.5, value: 0.6), Keyframe(time: 2, value: 0)]),
            ParameterTrack(parameterID: "ParamAngleY", keyframes: [Keyframe(time: 0, value: 0), Keyframe(time: 0.45, value: -6), Keyframe(time: 1.3, value: -4), Keyframe(time: 2, value: 0)]),
        ]
        s.perform("Sample Animations") { b in b.project.animations += [look, talk] }
        s.currentClipID = s.project.animations.first?.id
        s.selection = Selection()
        s.resetParameters()
        s.notice = nil
    }
}
