import Foundation
import M2DCore
import M2DRig
import M2DAnimation
import M2DPhysics

extension EditorSession {
    // MARK: Clips

    @discardableResult
    public func addClip(name: String = "Animation", duration: Double = 3, frameRate: Double = 30) -> ObjectID {
        let clip = AnimationClip(name: name, duration: duration, frameRate: frameRate)
        perform("New Animation") { b in b.project.animations.append(clip) }
        currentClipID = clip.id
        seek(0)
        return clip.id
    }

    @discardableResult
    public func addIdleClip() -> ObjectID {
        let clip = AnimationPresets.idle(for: rig.parameters)
        perform("New Idle Animation") { b in b.project.animations.append(clip) }
        currentClipID = clip.id
        return clip.id
    }

    @discardableResult
    public func duplicateClip(_ id: ObjectID) -> ObjectID? {
        guard var c = project.clip(id) else { return nil }
        c.id = IDGenerator.make("clip"); c.name += " Copy"
        let copy = c
        perform("Duplicate Animation") { b in b.project.animations.append(copy) }
        currentClipID = copy.id
        return copy.id
    }

    public func deleteClip(_ id: ObjectID) {
        perform("Delete Animation") { b in b.project.animations.removeAll { $0.id == id } }
        if currentClipID == id { currentClipID = project.animations.first?.id }
    }

    public func updateClip(_ id: ObjectID, duration: Double? = nil, frameRate: Double? = nil, loopMode: LoopMode? = nil) {
        perform("Edit Animation") { b in
            guard let i = b.project.animations.firstIndex(where: { $0.id == id }) else { return }
            if let frameRate { b.project.animations[i].frameRate = clamp(frameRate, 1, 120) }
            if let duration { b.project.animations[i].duration = max(1 / b.project.animations[i].frameRate, duration) }
            if let loopMode { b.project.animations[i].loopMode = loopMode }
        }
    }

    func mutateClip(_ id: ObjectID, _ name: String, _ f: (inout AnimationClip) -> Void) {
        perform(name) { b in
            guard let i = b.project.animations.firstIndex(where: { $0.id == id }) else { return }
            f(&b.project.animations[i])
        }
    }

    // MARK: Keyframes

    /// Snap a time to the clip's frame grid.
    public func snapTime(_ t: Double, clip: AnimationClip) -> Double {
        clamp((t * clip.frameRate).rounded() / clip.frameRate, 0, clip.duration)
    }

    public func setKeyframe(clipID: ObjectID, parameterID: ObjectID, time: Double, value: Float, interpolation: Interpolation? = nil) {
        guard let clip = project.clip(clipID) else { return }
        let t = snapTime(clip.localTime(time), clip: clip)
        mutateClip(clipID, "Set Keyframe") { c in
            let tol = 0.5 / c.frameRate
            c.withTrack(parameterID) { $0.setKey(time: t, value: value, tolerance: tol, interpolation: interpolation) }
        }
    }

    /// Key every parameter that differs from its default (or that already has a track) at the playhead.
    public func keyAllParameters() {
        guard let clip = currentClip else { notice = "Create an animation first."; return }
        let t = snapTime(clip.localTime(playhead), clip: clip)
        let tracked = Set(clip.tracks.map(\.parameterID))
        mutateClip(clip.id, "Key All Parameters") { c in
            let tol = 0.5 / c.frameRate
            for p in rig.parameters {
                let v = parameterValues[p.id] ?? p.defaultValue
                guard tracked.contains(p.id) || abs(v - p.defaultValue) > 1e-4 else { continue }
                c.withTrack(p.id) { $0.setKey(time: t, value: v, tolerance: tol) }
            }
        }
    }

    public func deleteKeyframes(clipID: ObjectID, _ keys: [(parameterID: ObjectID, keyID: ObjectID)]) {
        mutateClip(clipID, "Delete Keyframes") { c in
            for k in keys { c.withTrack(k.parameterID) { $0.removeKey(id: k.keyID) } }
            c.tracks.removeAll { $0.keyframes.isEmpty }
        }
        seek(playhead)
    }

    /// Move keyframes by `dt` seconds (snapped to frames).
    public func moveKeyframes(clipID: ObjectID, _ keys: [(parameterID: ObjectID, keyID: ObjectID)], by dt: Double) {
        mutateClip(clipID, "Move Keyframes") { c in
            let fr = c.frameRate, dur = c.duration
            for k in keys {
                c.withTrack(k.parameterID) { tr in
                    guard let i = tr.keyframes.firstIndex(where: { $0.id == k.keyID }) else { return }
                    let t = clamp(((tr.keyframes[i].time + dt) * fr).rounded() / fr, 0, dur)
                    tr.keyframes[i].time = t
                    tr.sort()
                }
            }
        }
        seek(playhead)
    }

    public func updateKeyframe(clipID: ObjectID, parameterID: ObjectID, keyID: ObjectID, value: Float? = nil,
                               interpolation: Interpolation? = nil, outHandle: CurveHandle? = nil, inHandle: CurveHandle? = nil) {
        mutateClip(clipID, "Edit Keyframe") { c in
            c.withTrack(parameterID) { tr in
                guard let i = tr.keyframes.firstIndex(where: { $0.id == keyID }) else { return }
                if let value { tr.keyframes[i].value = value }
                if let interpolation { tr.keyframes[i].interpolation = interpolation }
                if let outHandle { tr.keyframes[i].outHandle = outHandle }
                if let inHandle { tr.keyframes[i].inHandle = inHandle }
            }
        }
        seek(playhead)
    }

    public func setTrackEnabled(clipID: ObjectID, parameterID: ObjectID, _ enabled: Bool) {
        mutateClip(clipID, enabled ? "Enable Track" : "Mute Track") { c in c.withTrack(parameterID) { $0.enabled = enabled } }
        seek(playhead)
    }

    public func setTrackBlend(clipID: ObjectID, parameterID: ObjectID, _ blend: TrackBlend) {
        mutateClip(clipID, "Track Blend") { c in c.withTrack(parameterID) { $0.blend = blend } }
    }

    public func deleteTrack(clipID: ObjectID, parameterID: ObjectID) {
        mutateClip(clipID, "Delete Track") { c in c.tracks.removeAll { $0.parameterID == parameterID } }
        seek(playhead)
    }

    // MARK: Physics

    @discardableResult
    public func addPhysicsGroup(_ group: PhysicsGroup? = nil) -> ObjectID {
        let g = group ?? PhysicsGroup(name: "Physics \(project.physics.groups.count + 1)")
        perform("Add Physics") { b in b.project.physics.groups.append(g) }
        resetPhysics()
        return g.id
    }

    public func updatePhysicsGroup(_ id: ObjectID, _ f: @escaping (inout PhysicsGroup) -> Void) {
        perform("Edit Physics") { b in
            guard let i = b.project.physics.groups.firstIndex(where: { $0.id == id }) else { return }
            f(&b.project.physics.groups[i])
        }
        resetPhysics()
    }

    public func deletePhysicsGroup(_ id: ObjectID) {
        perform("Delete Physics") { b in b.project.physics.groups.removeAll { $0.id == id } }
        resetPhysics()
    }

    public func setPhysicsEnvironment(gravity: Vec2? = nil, wind: Vec2? = nil) {
        perform("Physics Settings") { b in
            if let gravity { b.project.physics.gravity = gravity }
            if let wind { b.project.physics.wind = wind }
        }
    }
}
