import M2DCore

/// Any per-key data that can be blended with weights.
public protocol KeyformValue: Codable, Sendable {
    static func blend(_ items: [(Self, Float)]) -> Self
}

/// A parameter this object reacts to, and the parameter values at which keyforms exist.
public struct ParameterBinding: Codable, Hashable, Sendable {
    public var parameterID: ObjectID
    /// Strictly increasing key positions.
    public var keys: [Float]
    public init(parameterID: ObjectID, keys: [Float]) {
        self.parameterID = parameterID; self.keys = keys.sorted()
    }
}

/// Keyforms over the cartesian product of parameter keys. With bindings
/// A (keys a0,a1,a2) and B (keys b0,b1) there are 6 forms; evaluation blends the
/// 2^n surrounding forms multilinearly (n = number of bindings).
public struct KeyformGrid<Form: KeyformValue>: Codable, Sendable {
    public var bindings: [ParameterBinding]
    /// Flattened, first binding varies fastest.
    public var forms: [Form]

    public init(rest: Form) { bindings = []; forms = [rest] }
    public init(bindings: [ParameterBinding], forms: [Form]) {
        self.bindings = bindings; self.forms = forms
        precondition(forms.count == Self.count(bindings), "keyform count mismatch")
    }

    static func count(_ b: [ParameterBinding]) -> Int { b.reduce(1) { $0 * max(1, $1.keys.count) } }

    public var formCount: Int { forms.count }
    public func binding(for parameterID: ObjectID) -> ParameterBinding? { bindings.first { $0.parameterID == parameterID } }

    public func flatIndex(_ keyIndices: [Int]) -> Int {
        var idx = 0, mul = 1
        for (i, b) in bindings.enumerated() { idx += keyIndices[i] * mul; mul *= b.keys.count }
        return idx
    }

    public func keyIndices(of flat: Int) -> [Int] {
        var rest = flat
        return bindings.map { b in let k = rest % b.keys.count; rest /= b.keys.count; return k }
    }

    /// (form index, weight) pairs for the given parameter values.
    public func weights(_ values: ParameterValues) -> [(Int, Float)] {
        if bindings.isEmpty { return [(0, 1)] }
        var segs: [(lo: Int, t: Float)] = []
        segs.reserveCapacity(bindings.count)
        for b in bindings {
            let keys = b.keys
            let v = values[b.parameterID] ?? 0
            if keys.count == 1 { segs.append((0, 0)); continue }
            if v <= keys[0] { segs.append((0, 0)); continue }
            if v >= keys[keys.count - 1] { segs.append((keys.count - 2, 1)); continue }
            var i = 0
            while i < keys.count - 2, v > keys[i + 1] { i += 1 }
            let span = keys[i + 1] - keys[i]
            segs.append((i, span > 0 ? (v - keys[i]) / span : 0))
        }
        var result: [(Int, Float)] = []
        let n = bindings.count
        for corner in 0..<(1 << n) {
            var w: Float = 1
            var idx = 0, mul = 1
            for j in 0..<n {
                let high = (corner >> j) & 1 == 1
                let (lo, t) = segs[j]
                if bindings[j].keys.count == 1 {
                    if high { w = 0; break }
                } else {
                    w *= high ? t : 1 - t
                    idx += (lo + (high ? 1 : 0)) * mul
                }
                mul *= bindings[j].keys.count
            }
            if w > 1e-6 { result.append((idx, w)) }
        }
        return result.isEmpty ? [(0, 1)] : result
    }

    public func evaluate(_ values: ParameterValues) -> Form {
        let w = weights(values)
        if w.count == 1, w[0].1 >= 0.99999 { return forms[w[0].0] }
        return Form.blend(w.map { (forms[$0.0], $0.1) })
    }

    /// Index of the form sitting exactly at the current parameter values, or nil
    /// when any bound parameter lies between keys.
    public func exactFormIndex(_ values: ParameterValues, tolerance: Float = 1e-4) -> Int? {
        var indices: [Int] = []
        for b in bindings {
            let v = values[b.parameterID] ?? 0
            guard let k = b.keys.firstIndex(where: { abs($0 - v) <= tolerance }) else { return nil }
            indices.append(k)
        }
        return flatIndex(indices)
    }

    /// Bind a new parameter. Existing forms are duplicated to every key so the
    /// object's appearance is unchanged.
    public mutating func addBinding(_ parameterID: ObjectID, keys: [Float]) {
        guard binding(for: parameterID) == nil, !keys.isEmpty else { return }
        let sorted = Array(Set(keys)).sorted()
        var newForms: [Form] = []
        newForms.reserveCapacity(forms.count * sorted.count)
        for _ in sorted { newForms += forms }
        // New binding is appended last, so it is the slowest-varying index.
        bindings.append(ParameterBinding(parameterID: parameterID, keys: sorted))
        forms = newForms
    }

    public mutating func removeBinding(_ parameterID: ObjectID, keeping value: Float) {
        guard let bi = bindings.firstIndex(where: { $0.parameterID == parameterID }) else { return }
        let keys = bindings[bi].keys
        let keep = keys.enumerated().min { abs($0.element - value) < abs($1.element - value) }!.offset
        var newBindings = bindings
        newBindings.remove(at: bi)
        var newForms: [Form] = []
        for flat in 0..<Self.count(newBindings) {
            var rest = flat
            var idx = newBindings.map { b -> Int in let k = rest % b.keys.count; rest /= b.keys.count; return k }
            idx.insert(keep, at: bi)
            newForms.append(forms[flatIndex(idx)])
        }
        bindings = newBindings; forms = newForms
    }

    /// Insert a key; new forms are interpolated from the existing ones so nothing jumps.
    public mutating func addKey(_ parameterID: ObjectID, value: Float) {
        guard let bi = bindings.firstIndex(where: { $0.parameterID == parameterID }) else { return }
        guard !bindings[bi].keys.contains(where: { abs($0 - value) < 1e-5 }) else { return }
        var newBindings = bindings
        newBindings[bi].keys.append(value)
        newBindings[bi].keys.sort()
        let newKeyIndex = newBindings[bi].keys.firstIndex(of: value)!
        var newForms: [Form] = []
        let old = self
        for flat in 0..<Self.count(newBindings) {
            var rest = flat
            let idx = newBindings.map { b -> Int in let k = rest % b.keys.count; rest /= b.keys.count; return k }
            if idx[bi] == newKeyIndex {
                var vals = ParameterValues()
                for (j, b) in newBindings.enumerated() { vals[b.parameterID] = b.keys[idx[j]] }
                newForms.append(old.evaluate(vals))
            } else {
                var oldIdx = idx
                if idx[bi] > newKeyIndex { oldIdx[bi] -= 1 }
                newForms.append(old.forms[old.flatIndex(oldIdx)])
            }
        }
        bindings = newBindings; forms = newForms
    }

    public mutating func removeKey(_ parameterID: ObjectID, value: Float) {
        guard let bi = bindings.firstIndex(where: { $0.parameterID == parameterID }),
              let ki = bindings[bi].keys.firstIndex(where: { abs($0 - value) < 1e-4 }) else { return }
        if bindings[bi].keys.count == 1 { removeBinding(parameterID, keeping: value); return }
        var newBindings = bindings
        newBindings[bi].keys.remove(at: ki)
        var newForms: [Form] = []
        for flat in 0..<Self.count(newBindings) {
            var rest = flat
            var idx = newBindings.map { b -> Int in let k = rest % b.keys.count; rest /= b.keys.count; return k }
            if idx[bi] >= ki { idx[bi] += 1 }
            newForms.append(forms[flatIndex(idx)])
        }
        bindings = newBindings; forms = newForms
    }

    /// Apply a change to every form (e.g. when vertices are added to a mesh).
    public mutating func mapForms(_ f: (inout Form) -> Void) {
        for i in forms.indices { f(&forms[i]) }
    }
}

// MARK: - Concrete keyform types

/// Mesh keyform: per-vertex offsets from the rest mesh, plus opacity and draw order.
public struct MeshForm: KeyformValue, Hashable {
    public var offsets: [Vec2]
    public var opacity: Float
    public var drawOrder: Float
    public init(offsets: [Vec2], opacity: Float = 1, drawOrder: Float = 500) {
        self.offsets = offsets; self.opacity = opacity; self.drawOrder = drawOrder
    }
    public static func blend(_ items: [(MeshForm, Float)]) -> MeshForm {
        let n = items[0].0.offsets.count
        var off = [Vec2](repeating: .zero, count: n)
        var op: Float = 0, dro: Float = 0
        for (f, w) in items {
            let m = min(n, f.offsets.count)
            for i in 0..<m { off[i] += f.offsets[i] * w }
            op += f.opacity * w; dro += f.drawOrder * w
        }
        return MeshForm(offsets: off, opacity: op, drawOrder: dro)
    }
}

/// Warp keyform: absolute control-point positions in the parent's rest space.
public struct WarpForm: KeyformValue, Hashable {
    public var points: [Vec2]
    public var opacity: Float
    public init(points: [Vec2], opacity: Float = 1) { self.points = points; self.opacity = opacity }
    public static func blend(_ items: [(WarpForm, Float)]) -> WarpForm {
        let n = items[0].0.points.count
        var pts = [Vec2](repeating: .zero, count: n)
        var op: Float = 0
        for (f, w) in items {
            for i in 0..<min(n, f.points.count) { pts[i] += f.points[i] * w }
            op += f.opacity * w
        }
        return WarpForm(points: pts, opacity: op)
    }
}

/// Rotation keyform: pivot position, angle in degrees, uniform scale.
public struct RotationForm: KeyformValue, Hashable {
    public var origin: Vec2
    public var angle: Float
    public var scale: Float
    public var opacity: Float
    public init(origin: Vec2, angle: Float = 0, scale: Float = 1, opacity: Float = 1) {
        self.origin = origin; self.angle = angle; self.scale = scale; self.opacity = opacity
    }
    public static func blend(_ items: [(RotationForm, Float)]) -> RotationForm {
        var o = Vec2.zero, a: Float = 0, s: Float = 0, op: Float = 0
        for (f, w) in items { o += f.origin * w; a += f.angle * w; s += f.scale * w; op += f.opacity * w }
        return RotationForm(origin: o, angle: a, scale: s, opacity: op)
    }
}

extension KeyformGrid: Equatable where Form: Equatable {}
extension KeyformGrid: Hashable where Form: Hashable {}
