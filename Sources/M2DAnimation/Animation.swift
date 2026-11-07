import Foundation
import M2DCore
import M2DRig

public enum LoopMode: String, Codable, Hashable, Sendable, CaseIterable {
    case once, loop, pingPong
}

public enum TrackBlend: String, Codable, Hashable, Sendable, CaseIterable {
    /// Replaces the parameter value.
    case override
    /// Adds (value − parameter default) on top of lower layers.
    case additive
}

/// Animation curve for one parameter.
public struct ParameterTrack: Codable, Hashable, Sendable, Identifiable {
    public var id: ObjectID { parameterID }
    public var parameterID: ObjectID
    public var keyframes: [Keyframe]
    public var enabled: Bool
    public var blend: TrackBlend

    public init(parameterID: ObjectID, keyframes: [Keyframe] = [], blend: TrackBlend = .override) {
        self.parameterID = parameterID; self.keyframes = keyframes.sorted { $0.time < $1.time }
        enabled = true; self.blend = blend
    }

    public func value(at t: Double) -> Float? {
        guard let first = keyframes.first else { return nil }
        if t <= first.time || keyframes.count == 1 { return first.value }
        let last = keyframes[keyframes.count - 1]
        if t >= last.time { return last.value }
        // Binary search for the segment.
        var lo = 0, hi = keyframes.count - 1
        while hi - lo > 1 { let mid = (lo + hi) / 2; if keyframes[mid].time <= t { lo = mid } else { hi = mid } }
        return CurveMath.segment(keyframes[lo], keyframes[hi], at: t)
    }

    /// Insert or replace a key at `time` (within half a frame).
    public mutating func setKey(time: Double, value: Float, tolerance: Double = 1e-3, interpolation: Interpolation? = nil) {
        if let i = keyframes.firstIndex(where: { abs($0.time - time) <= tolerance }) {
            keyframes[i].value = value
            if let interpolation { keyframes[i].interpolation = interpolation }
        } else {
            keyframes.append(Keyframe(time: time, value: value, interpolation: interpolation ?? .easeInOut))
            keyframes.sort { $0.time < $1.time }
        }
    }

    public mutating func removeKey(id: ObjectID) { keyframes.removeAll { $0.id == id } }
    public mutating func sort() { keyframes.sort { $0.time < $1.time } }
}

public struct AnimationClip: Codable, Hashable, Sendable, Identifiable {
    public var id: ObjectID
    public var name: String
    /// Seconds.
    public var duration: Double
    public var frameRate: Double
    public var loopMode: LoopMode
    public var tracks: [ParameterTrack]

    public init(id: ObjectID = IDGenerator.make("clip"), name: String, duration: Double = 2, frameRate: Double = 30,
                loopMode: LoopMode = .loop, tracks: [ParameterTrack] = []) {
        self.id = id; self.name = name; self.duration = max(duration, 1 / frameRate); self.frameRate = frameRate
        self.loopMode = loopMode; self.tracks = tracks
    }

    public var frameCount: Int { max(1, Int((duration * frameRate).rounded())) }

    public func track(_ parameterID: ObjectID) -> ParameterTrack? { tracks.first { $0.parameterID == parameterID } }

    public mutating func withTrack(_ parameterID: ObjectID, _ f: (inout ParameterTrack) -> Void) {
        if let i = tracks.firstIndex(where: { $0.parameterID == parameterID }) { f(&tracks[i]) }
        else { var t = ParameterTrack(parameterID: parameterID); f(&t); tracks.append(t) }
    }

    /// Local clip time for a playhead time, honouring the loop mode.
    public func localTime(_ t: Double) -> Double {
        guard duration > 0 else { return 0 }
        switch loopMode {
        case .once: return clamp(t, 0, duration)
        case .loop:
            let r = t.truncatingRemainder(dividingBy: duration)
            return r < 0 ? r + duration : r
        case .pingPong:
            let period = duration * 2
            var r = t.truncatingRemainder(dividingBy: period)
            if r < 0 { r += period }
            return r <= duration ? r : period - r
        }
    }

    /// Sample every enabled track at playhead time `t`.
    public func sample(at t: Double) -> [(ObjectID, Float, TrackBlend)] {
        let lt = localTime(t)
        return tracks.compactMap { tr in
            guard tr.enabled, let v = tr.value(at: lt) else { return nil }
            return (tr.parameterID, v, tr.blend)
        }
    }

    /// Apply this clip onto `values` with a layer weight (0–1).
    public func apply(at t: Double, to values: inout ParameterValues, parameters: [Parameter], weight: Float = 1, additive: Bool = false) {
        for (pid, v, blend) in sample(at: t) {
            guard let p = parameters.first(where: { $0.id == pid }) else { continue }
            let current = values[pid] ?? p.defaultValue
            if additive || blend == .additive {
                values[pid] = p.clamped(current + (v - p.defaultValue) * weight)
            } else {
                values[pid] = p.clamped(current + (v - current) * weight)
            }
        }
    }
}

/// Procedural generators for common idle motion.
public enum AnimationPresets {
    /// Smooth breathing loop on a 0…1 parameter.
    public static func breathing(parameterID: ObjectID, period: Double = 3.2) -> ParameterTrack {
        ParameterTrack(parameterID: parameterID, keyframes: [
            Keyframe(time: 0, value: 0, interpolation: .easeInOut),
            Keyframe(time: period / 2, value: 1, interpolation: .easeInOut),
            Keyframe(time: period, value: 0, interpolation: .easeInOut),
        ])
    }

    /// Eye blinks at the given times (seconds) on an open-eye parameter (1 = open).
    public static func blinks(parameterID: ObjectID, at times: [Double], duration: Double) -> ParameterTrack {
        var keys = [Keyframe(time: 0, value: 1, interpolation: .linear)]
        for t in times where t + 0.2 < duration {
            keys.append(Keyframe(time: t, value: 1, interpolation: .easeIn))
            keys.append(Keyframe(time: t + 0.06, value: 0, interpolation: .linear))
            keys.append(Keyframe(time: t + 0.1, value: 0, interpolation: .easeOut))
            keys.append(Keyframe(time: t + 0.2, value: 1, interpolation: .linear))
        }
        keys.append(Keyframe(time: duration, value: 1))
        return ParameterTrack(parameterID: parameterID, keyframes: keys)
    }

    /// Gentle sway between -amplitude and +amplitude.
    public static func sway(parameterID: ObjectID, amplitude: Float, period: Double, phase: Double = 0) -> ParameterTrack {
        let q = period / 4
        return ParameterTrack(parameterID: parameterID, keyframes: [
            Keyframe(time: 0, value: amplitude * Float(sin(phase))),
            Keyframe(time: q, value: amplitude),
            Keyframe(time: 3 * q, value: -amplitude),
            Keyframe(time: period, value: amplitude * Float(sin(phase))),
        ].map { var k = $0; k.interpolation = .easeInOut; return k })
    }

    /// A complete idle clip using whichever standard parameters exist in the rig.
    public static func idle(for parameters: [Parameter], duration: Double = 6) -> AnimationClip {
        var clip = AnimationClip(name: "Idle", duration: duration, loopMode: .loop)
        let ids = Set(parameters.map(\.id))
        if ids.contains("ParamBreath") { clip.tracks.append(breathing(parameterID: "ParamBreath", period: duration / 2)) }
        for eye in ["ParamEyeLOpen", "ParamEyeROpen"] where ids.contains(eye) {
            clip.tracks.append(blinks(parameterID: eye, at: [1.6, 4.4], duration: duration))
        }
        if ids.contains("ParamAngleX") { clip.tracks.append(sway(parameterID: "ParamAngleX", amplitude: 6, period: duration)) }
        if ids.contains("ParamAngleZ") { clip.tracks.append(sway(parameterID: "ParamAngleZ", amplitude: 3, period: duration / 2)) }
        if ids.contains("ParamBodyAngleX") { clip.tracks.append(sway(parameterID: "ParamBodyAngleX", amplitude: 2, period: duration)) }
        return clip
    }
}

/// Layered playback: a base clip plus any number of override/additive layers
/// (e.g. idle loop + facial expression).
public struct AnimationLayer: Codable, Hashable, Sendable, Identifiable {
    public var id: ObjectID
    public var clipID: ObjectID
    public var weight: Float
    public var additive: Bool
    public var speed: Double
    public var time: Double
    public init(clipID: ObjectID, weight: Float = 1, additive: Bool = false, speed: Double = 1) {
        id = IDGenerator.make("layer"); self.clipID = clipID; self.weight = weight; self.additive = additive
        self.speed = speed; time = 0
    }
}

public struct AnimationPlayer: Sendable {
    public var layers: [AnimationLayer] = []
    public var isPlaying = false
    public init() {}

    public mutating func advance(by dt: Double) {
        guard isPlaying else { return }
        for i in layers.indices { layers[i].time += dt * layers[i].speed }
    }

    public mutating func seek(_ t: Double) { for i in layers.indices { layers[i].time = t } }

    public func apply(clips: [AnimationClip], parameters: [Parameter], to values: inout ParameterValues) {
        for layer in layers {
            guard let clip = clips.first(where: { $0.id == layer.clipID }) else { continue }
            clip.apply(at: layer.time, to: &values, parameters: parameters, weight: layer.weight, additive: layer.additive)
        }
    }
}
