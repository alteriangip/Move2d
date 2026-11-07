import Foundation
import M2DCore
import M2DRig

/// What a physics input reads from its parameter.
public enum PhysicsInputKind: String, Codable, Hashable, Sendable, CaseIterable {
    /// Horizontal anchor movement (e.g. Body Angle X, Angle X).
    case translationX
    /// Vertical anchor movement (e.g. Breath).
    case translationY
    /// Tilts the anchor frame (e.g. Angle Z).
    case angle
}

public struct PhysicsInput: Codable, Hashable, Sendable {
    public var parameterID: ObjectID
    public var kind: PhysicsInputKind
    /// Relative contribution, typically 0…1.
    public var weight: Float
    public var reflect: Bool
    public init(parameterID: ObjectID, kind: PhysicsInputKind, weight: Float = 1, reflect: Bool = false) {
        self.parameterID = parameterID; self.kind = kind; self.weight = weight; self.reflect = reflect
    }
}

public struct PhysicsOutput: Codable, Hashable, Sendable {
    public var parameterID: ObjectID
    /// Segment whose angle drives the parameter (1 = first segment below the anchor).
    public var particleIndex: Int
    /// Degrees of swing that map to the parameter's full range.
    public var angleRange: Float
    public var weight: Float
    public var reflect: Bool
    public init(parameterID: ObjectID, particleIndex: Int = 1, angleRange: Float = 30, weight: Float = 1, reflect: Bool = false) {
        self.parameterID = parameterID; self.particleIndex = particleIndex; self.angleRange = angleRange
        self.weight = weight; self.reflect = reflect
    }
}

/// One link of the pendulum chain.
public struct PhysicsParticle: Codable, Hashable, Sendable {
    /// Rest distance to the previous particle (simulation units ≈ canvas px / 10).
    public var length: Float
    /// Spring pulling the link back to its rest direction (0 = free pendulum).
    public var stiffness: Float
    /// Velocity damping per second (0 = none, 1 = heavy).
    public var damping: Float
    /// How strongly the link follows its anchor (0…1). Low values lag more.
    public var mobility: Float
    public init(length: Float = 10, stiffness: Float = 12, damping: Float = 0.4, mobility: Float = 0.9) {
        self.length = length; self.stiffness = stiffness; self.damping = damping; self.mobility = mobility
    }
}

/// A pendulum chain driven by input parameters and writing output parameters.
public struct PhysicsGroup: Codable, Hashable, Sendable, Identifiable {
    public var id: ObjectID
    public var name: String
    public var enabled: Bool
    public var inputs: [PhysicsInput]
    public var outputs: [PhysicsOutput]
    public var particles: [PhysicsParticle]
    /// Simulation units of anchor travel for a fully deflected translation input.
    public var translationScale: Float
    /// Degrees of anchor tilt for a fully deflected angle input.
    public var angleScale: Float

    public init(id: ObjectID = IDGenerator.make("phys"), name: String, inputs: [PhysicsInput] = [], outputs: [PhysicsOutput] = [],
                particles: [PhysicsParticle] = [PhysicsParticle(), PhysicsParticle()], translationScale: Float = 10, angleScale: Float = 10) {
        self.id = id; self.name = name; enabled = true; self.inputs = inputs; self.outputs = outputs
        self.particles = particles; self.translationScale = translationScale; self.angleScale = angleScale
    }

    /// Typical hair setup: head and body sway in, hair sway out.
    public static func hair(name: String, output: ObjectID, segments: Int = 2) -> PhysicsGroup {
        PhysicsGroup(name: name,
                     inputs: [PhysicsInput(parameterID: "ParamAngleX", kind: .translationX, weight: 0.6),
                              PhysicsInput(parameterID: "ParamAngleZ", kind: .angle, weight: 0.6),
                              PhysicsInput(parameterID: "ParamBodyAngleX", kind: .translationX, weight: 0.4),
                              PhysicsInput(parameterID: "ParamBodyAngleZ", kind: .angle, weight: 0.4)],
                     outputs: [PhysicsOutput(parameterID: output, particleIndex: segments, angleRange: 25)],
                     particles: Array(repeating: PhysicsParticle(length: 8, stiffness: 10, damping: 0.5, mobility: 0.95), count: segments))
    }
}

public struct PhysicsRig: Codable, Hashable, Sendable {
    public var groups: [PhysicsGroup]
    /// Gravity direction and strength in simulation units/s².
    public var gravity: Vec2
    public var wind: Vec2
    public init(groups: [PhysicsGroup] = [], gravity: Vec2 = Vec2(0, 98), wind: Vec2 = .zero) {
        self.groups = groups; self.gravity = gravity; self.wind = wind
    }
}

/// Runtime state for a `PhysicsRig`. Verlet-integrated pendulum chains on a fixed step.
public struct PhysicsSimulator: Sendable {
    public static let fixedStep: Double = 1.0 / 120

    struct ChainState: Sendable {
        var positions: [Vec2]
        var previous: [Vec2]
    }

    public private(set) var rig: PhysicsRig
    var states: [ObjectID: ChainState] = [:]
    var accumulator: Double = 0
    var initialized = false

    public init(rig: PhysicsRig) { self.rig = rig }

    public mutating func update(rig newRig: PhysicsRig) {
        if newRig != rig { rig = newRig; states = [:]; initialized = false }
    }

    public mutating func reset() { states = [:]; initialized = false; accumulator = 0 }

    static func normalized(_ v: Float, _ p: Parameter) -> Float {
        if v >= p.defaultValue { let span = p.maxValue - p.defaultValue; return span > 0 ? (v - p.defaultValue) / span : 0 }
        let span = p.defaultValue - p.minValue
        return span > 0 ? (v - p.defaultValue) / span : 0
    }

    func anchor(_ g: PhysicsGroup, values: ParameterValues, parameters: [ObjectID: Parameter]) -> (Vec2, Float) {
        var t = Vec2.zero, angle: Float = 0
        for input in g.inputs {
            guard let p = parameters[input.parameterID] else { continue }
            var n = Self.normalized(values[p.id] ?? p.defaultValue, p) * input.weight
            if input.reflect { n = -n }
            switch input.kind {
            case .translationX: t.x += n * g.translationScale
            case .translationY: t.y += n * g.translationScale
            case .angle: angle += n * g.angleScale
            }
        }
        return (t, degreesToRadians(angle))
    }

    func restChain(_ g: PhysicsGroup, anchor: Vec2, angle: Float) -> [Vec2] {
        var pts = [anchor]
        let down = Vec2(0, 1).rotated(by: angle)
        for p in g.particles { pts.append(pts[pts.count - 1] + down * p.length) }
        return pts
    }

    /// Advance the simulation by `dt` seconds and write outputs into `values`.
    public mutating func step(dt: Double, parameters: [Parameter], values: inout ParameterValues) {
        let byID = Dictionary(uniqueKeysWithValues: parameters.map { ($0.id, $0) })
        if !initialized {
            for g in rig.groups {
                let (a, ang) = anchor(g, values: values, parameters: byID)
                let rest = restChain(g, anchor: a, angle: ang)
                states[g.id] = ChainState(positions: rest, previous: rest)
            }
            initialized = true
        }
        accumulator += min(dt, 0.25)
        let h = Float(Self.fixedStep)
        while accumulator >= Self.fixedStep {
            accumulator -= Self.fixedStep
            for g in rig.groups where g.enabled {
                guard var s = states[g.id] else { continue }
                let (a, ang) = anchor(g, values: values, parameters: byID)
                let down = Vec2(0, 1).rotated(by: ang)
                s.previous[0] = s.positions[0]
                s.positions[0] = a
                for i in 1..<s.positions.count {
                    let p = g.particles[i - 1]
                    let cur = s.positions[i]
                    let vel = (cur - s.previous[i]) * max(0, 1 - p.damping * h * 4)
                    // Spring towards the rest direction from the previous particle.
                    let target = s.positions[i - 1] + down * p.length
                    let spring = (target - cur) * p.stiffness
                    let acc = rig.gravity * 0.1 + rig.wind + spring
                    var next = cur + vel + acc * h * h
                    // Mobility: blend with being dragged rigidly by the parent's motion.
                    let parentMove = s.positions[i - 1] - s.previous[i - 1]
                    next += parentMove * (1 - p.mobility)
                    s.previous[i] = cur
                    s.positions[i] = next
                }
                // Distance constraints.
                for _ in 0..<2 {
                    for i in 1..<s.positions.count {
                        let len = g.particles[i - 1].length
                        let d = s.positions[i] - s.positions[i - 1]
                        let l = d.length
                        if l > 1e-6 { s.positions[i] = s.positions[i - 1] + d * (len / l) }
                    }
                }
                states[g.id] = s
            }
        }
        // Outputs.
        for g in rig.groups where g.enabled {
            guard let s = states[g.id] else { continue }
            let (_, ang) = anchor(g, values: values, parameters: byID)
            for out in g.outputs {
                guard let p = byID[out.parameterID], out.particleIndex >= 1, out.particleIndex < s.positions.count else { continue }
                let seg = s.positions[out.particleIndex] - s.positions[out.particleIndex - 1]
                let rel = atan2(seg.y, seg.x) - (Float.pi / 2 + ang)
                var deg = radiansToDegrees(atan2(sin(rel), cos(rel)))
                if out.reflect { deg = -deg }
                // Swing to the right (positive x) means the chain rotated clockwise → negative angle.
                let n = clamp(-deg / max(out.angleRange, 1e-3), -1, 1) * out.weight
                let v = n >= 0 ? p.defaultValue + n * (p.maxValue - p.defaultValue) : p.defaultValue + n * (p.defaultValue - p.minValue)
                values[p.id] = p.clamped(v)
            }
        }
    }

    /// Current chain points per group (for drawing in the editor).
    public func chain(_ groupID: ObjectID) -> [Vec2] { states[groupID]?.positions ?? [] }
}
