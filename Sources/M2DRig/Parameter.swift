import M2DCore

/// A user-defined control (e.g. "Angle X", "Eye L Open"). Parameters drive
/// keyform interpolation on any number of meshes and deformers.
public struct Parameter: Codable, Hashable, Identifiable, Sendable {
    public var id: ObjectID
    public var name: String
    public var minValue: Float
    public var maxValue: Float
    public var defaultValue: Float
    /// Optional grouping in the parameter panel ("Face", "Body"...).
    public var group: String
    /// Wraps around instead of clamping (useful for 360° spins).
    public var isCyclic: Bool

    public init(id: ObjectID = IDGenerator.make("param"), name: String, min: Float = -1, max: Float = 1,
                default def: Float = 0, group: String = "", isCyclic: Bool = false) {
        self.id = id; self.name = name; minValue = min; maxValue = max
        defaultValue = Swift.min(Swift.max(def, min), max); self.group = group; self.isCyclic = isCyclic
    }

    public func clamped(_ v: Float) -> Float {
        if isCyclic, maxValue > minValue {
            let span = maxValue - minValue
            var x = (v - minValue).truncatingRemainder(dividingBy: span)
            if x < 0 { x += span }
            return minValue + x
        }
        return Swift.min(Swift.max(v, minValue), maxValue)
    }

    /// Standard parameter set for a character, using the conventional ranges.
    public static func standardSet() -> [Parameter] {
        [
            Parameter(id: "ParamAngleX", name: "Angle X", min: -30, max: 30, group: "Head"),
            Parameter(id: "ParamAngleY", name: "Angle Y", min: -30, max: 30, group: "Head"),
            Parameter(id: "ParamAngleZ", name: "Angle Z", min: -30, max: 30, group: "Head"),
            Parameter(id: "ParamEyeLOpen", name: "Eye L Open", min: 0, max: 1, default: 1, group: "Eyes"),
            Parameter(id: "ParamEyeROpen", name: "Eye R Open", min: 0, max: 1, default: 1, group: "Eyes"),
            Parameter(id: "ParamEyeBallX", name: "Eyeball X", min: -1, max: 1, group: "Eyes"),
            Parameter(id: "ParamEyeBallY", name: "Eyeball Y", min: -1, max: 1, group: "Eyes"),
            Parameter(id: "ParamBrowLY", name: "Brow L Y", min: -1, max: 1, group: "Brows"),
            Parameter(id: "ParamBrowRY", name: "Brow R Y", min: -1, max: 1, group: "Brows"),
            Parameter(id: "ParamMouthOpenY", name: "Mouth Open", min: 0, max: 1, group: "Mouth"),
            Parameter(id: "ParamMouthForm", name: "Mouth Form", min: -1, max: 1, group: "Mouth"),
            Parameter(id: "ParamBodyAngleX", name: "Body Angle X", min: -10, max: 10, group: "Body"),
            Parameter(id: "ParamBodyAngleZ", name: "Body Angle Z", min: -10, max: 10, group: "Body"),
            Parameter(id: "ParamBreath", name: "Breath", min: 0, max: 1, group: "Body"),
            Parameter(id: "ParamHairFront", name: "Hair Front Sway", min: -1, max: 1, group: "Hair"),
            Parameter(id: "ParamHairSide", name: "Hair Side Sway", min: -1, max: 1, group: "Hair"),
            Parameter(id: "ParamHairBack", name: "Hair Back Sway", min: -1, max: 1, group: "Hair"),
        ]
    }
}

/// Current values of all parameters, keyed by id. Missing entries fall back to the default.
public struct ParameterValues: Codable, Hashable, Sendable {
    public var values: [ObjectID: Float]
    public init(_ values: [ObjectID: Float] = [:]) { self.values = values }

    public subscript(id: ObjectID) -> Float? {
        get { values[id] }
        set { values[id] = newValue }
    }

    public static func defaults(_ params: [Parameter]) -> ParameterValues {
        ParameterValues(Dictionary(uniqueKeysWithValues: params.map { ($0.id, $0.defaultValue) }))
    }

    public func value(_ p: Parameter) -> Float { values[p.id].map(p.clamped) ?? p.defaultValue }
}
