import Foundation
import Observation
import M2DCore
import M2DPSD
import M2DRig
import M2DAnimation
import M2DPhysics
import M2DRender
import M2DProject

public enum EditorMode: String, CaseIterable, Sendable {
    /// Build the rig: meshes, deformers, keyforms.
    case rig
    /// Animate parameters on the timeline.
    case animate
}

public enum EditorTool: String, CaseIterable, Sendable {
    /// Select objects; drag to move whole meshes/deformers in the current keyform.
    case select
    /// Move vertices / control points of the current keyform (deformation).
    case deform
    /// Edit mesh topology in the rest pose: move, add and remove vertices.
    case meshEdit
    /// Tap three vertices to add a triangle; tap a triangle to delete it.
    case triangle
    /// Lasso-select vertices.
    case lasso
    /// Rotate a rotation deformer around its pivot.
    case rotate
    /// Pan/zoom only.
    case hand

    public var title: String {
        switch self {
        case .select: return "Select"
        case .deform: return "Deform"
        case .meshEdit: return "Edit Mesh"
        case .triangle: return "Triangles"
        case .lasso: return "Lasso"
        case .rotate: return "Rotate"
        case .hand: return "Hand"
        }
    }
}

public struct Selection: Hashable, Sendable {
    /// Selected objects (meshes, parts, deformers), in selection order.
    public var objects: [ObjectID] = []
    /// Selected vertex indices per mesh.
    public var vertices: [ObjectID: Set<Int>] = [:]
    /// Selected warp control points per deformer.
    public var controlPoints: [ObjectID: Set<Int>] = [:]
    /// Vertices picked so far with the triangle tool.
    public var trianglePick: [Int] = []
    public init() {}
    public var primary: ObjectID? { objects.last }
    public var isEmpty: Bool { objects.isEmpty }
    public func contains(_ id: ObjectID) -> Bool { objects.contains(id) }
}

/// The editing state of one open project. All mutations go through methods
/// that record undo history, so the UI layer never edits the model directly.
@Observable
public final class EditorSession {
    // MARK: Document
    public internal(set) var bundle: ProjectBundle
    public var project: Project { bundle.project }
    public var rig: RigModel { bundle.project.rig }
    /// Bumped on every rig change (rebuild GPU buffers / evaluator).
    public internal(set) var rigRevision = 0
    /// Bumped when texture pixels change (re-upload textures).
    public internal(set) var textureRevision = 0
    public internal(set) var isDirty = false

    // MARK: UI state
    public var mode: EditorMode = .rig { didSet { if mode == .rig { isPlaying = false } } }
    public var tool: EditorTool = .select { didSet { selection.trianglePick = [] } }
    public var selection = Selection()
    public var showMeshWireframe = true
    public var showDeformers = true
    public var onionSkin = false
    /// When on, dragging a parameter in animate mode writes a keyframe at the playhead.
    public var autoKey = true
    /// Mesh generation density used by "Auto Mesh".
    public var meshSpacing: Float = 48
    /// Status/notice line for the UI.
    public var notice: String?

    // MARK: Parameters / animation
    public internal(set) var parameterValues: ParameterValues
    public var currentClipID: ObjectID?
    public internal(set) var playhead: Double = 0
    public var isPlaying = false
    public var physicsEnabled = true
    public internal(set) var pose: RigPose

    // MARK: Internals
    @ObservationIgnored var evaluatorCache: RigEvaluator?
    @ObservationIgnored var evaluatorRevision = -1
    @ObservationIgnored var simulator: PhysicsSimulator
    @ObservationIgnored var undoStack: [(String, ProjectBundle)] = []
    @ObservationIgnored var redoStack: [(String, ProjectBundle)] = []
    @ObservationIgnored var gestureSnapshot: (String, ProjectBundle)?
    @ObservationIgnored public var maxUndo = 80
    /// Parameters manually set while animating (overrides the clip until the playhead moves).
    @ObservationIgnored var manualOverrides: Set<ObjectID> = []

    public init(bundle: ProjectBundle) {
        self.bundle = bundle
        parameterValues = bundle.project.rig.defaultParameterValues()
        simulator = PhysicsSimulator(rig: bundle.project.physics)
        let ev = RigEvaluator(model: bundle.project.rig)
        pose = ev.evaluate(bundle.project.rig.defaultParameterValues())
        evaluatorCache = ev
        evaluatorRevision = 0
        currentClipID = bundle.project.animations.first?.id
    }

    public convenience init() {
        self.init(bundle: ProjectBundle(project: Project()))
    }

    /// Open a PSD as a new project.
    public static func importingPSD(_ data: [UInt8], fileName: String?, options: PSDImporter.Options = .init()) throws -> (EditorSession, [String]) {
        let result = try PSDImporter.importPSD(data, fileName: fileName, options: options)
        return (EditorSession(bundle: result.bundle), result.warnings)
    }

    public var evaluator: RigEvaluator {
        if evaluatorRevision != rigRevision || evaluatorCache == nil {
            evaluatorCache = RigEvaluator(model: rig)
            evaluatorRevision = rigRevision
        }
        return evaluatorCache!
    }

    // MARK: - History

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }
    public var undoActionName: String? { undoStack.last?.0 }
    public var redoActionName: String? { redoStack.last?.0 }

    /// Apply an undoable change.
    public func perform(_ name: String, textures: Bool = false, _ change: (inout ProjectBundle) throws -> Void) rethrows {
        let before = bundle
        var next = bundle
        try change(&next)
        if gestureSnapshot == nil {
            undoStack.append((name, before))
            if undoStack.count > maxUndo { undoStack.removeFirst() }
            redoStack.removeAll()
        }
        commit(next, textures: textures)
    }

    /// Begin a continuous edit (drag). Intermediate updates share one undo step.
    public func beginGesture(_ name: String) {
        guard gestureSnapshot == nil else { return }
        gestureSnapshot = (name, bundle)
    }

    public func endGesture() {
        guard let snap = gestureSnapshot else { return }
        gestureSnapshot = nil
        if snap.1.project != bundle.project {
            undoStack.append(snap)
            if undoStack.count > maxUndo { undoStack.removeFirst() }
            redoStack.removeAll()
        }
    }

    public func cancelGesture() {
        guard let snap = gestureSnapshot else { return }
        gestureSnapshot = nil
        commit(snap.1, textures: true)
    }

    public func undo() {
        guard let (name, prev) = undoStack.popLast() else { return }
        redoStack.append((name, bundle))
        commit(prev, textures: true)
        notice = "Undo \(name)"
    }

    public func redo() {
        guard let (name, next) = redoStack.popLast() else { return }
        undoStack.append((name, bundle))
        commit(next, textures: true)
        notice = "Redo \(name)"
    }

    func commit(_ next: ProjectBundle, textures: Bool) {
        bundle = next
        rigRevision &+= 1
        if textures { textureRevision &+= 1 }
        isDirty = true
        simulator.update(rig: next.project.physics)
        sanitizeSelection()
        refreshPose()
    }

    public func markSaved() { isDirty = false }

    func sanitizeSelection() {
        let valid = Set(rig.meshes.map(\.id) + rig.parts.map(\.id) + rig.deformers.map(\.id))
        selection.objects.removeAll { !valid.contains($0) }
        for (id, set) in selection.vertices {
            guard let m = rig.mesh(id) else { selection.vertices[id] = nil; continue }
            selection.vertices[id] = set.filter { $0 < m.mesh.vertexCount }
        }
        for (id, set) in selection.controlPoints {
            guard let d = rig.deformer(id), let w = d.warp else { selection.controlPoints[id] = nil; continue }
            selection.controlPoints[id] = set.filter { $0 < w.pointCount }
        }
        if let c = currentClipID, project.clip(c) == nil { currentClipID = project.animations.first?.id }
    }

    // MARK: - Evaluation

    /// Re-evaluate the pose for the current parameter values.
    public func refreshPose() {
        pose = evaluator.evaluate(parameterValues)
    }

    /// Advance playback / physics by `dt` seconds. Call once per display frame.
    public func tick(dt: Double) {
        var values = parameterValues
        if mode == .animate, let clip = currentClip {
            if isPlaying {
                playhead += dt
                if clip.loopMode == .once && playhead >= clip.duration { playhead = clip.duration; isPlaying = false }
                manualOverrides.removeAll()
            }
            values = valuesFromClip(clip, at: playhead, keeping: manualOverrides, base: values)
        }
        if physicsEnabled && !project.physics.groups.isEmpty {
            simulator.step(dt: dt, parameters: rig.parameters, values: &values)
        }
        if values != parameterValues || isPlaying || physicsEnabled {
            parameterValues = values
            refreshPose()
        }
    }

    func valuesFromClip(_ clip: AnimationClip, at t: Double, keeping: Set<ObjectID>, base: ParameterValues) -> ParameterValues {
        var v = rig.defaultParameterValues()
        for id in keeping { v[id] = base[id] }
        var sampled = v
        clip.apply(at: t, to: &sampled, parameters: rig.parameters)
        for id in keeping { sampled[id] = base[id] }
        return sampled
    }

    public func resetPhysics() { simulator.reset() }
    public func physicsChain(_ groupID: ObjectID) -> [Vec2] { simulator.chain(groupID) }

    // MARK: - Parameter values

    public func value(of parameterID: ObjectID) -> Float {
        guard let p = rig.parameter(parameterID) else { return 0 }
        return parameterValues.value(p)
    }

    /// Set a parameter's live value. In animate mode with auto-key, also keys it.
    public func setParameterValue(_ id: ObjectID, _ v: Float, fromUser: Bool = true) {
        guard let p = rig.parameter(id) else { return }
        parameterValues[id] = p.clamped(v)
        if mode == .animate && fromUser {
            if autoKey, let clipID = currentClipID {
                setKeyframe(clipID: clipID, parameterID: id, time: playhead, value: p.clamped(v))
            } else {
                manualOverrides.insert(id)
            }
        }
        refreshPose()
    }

    public func resetParameters() {
        parameterValues = rig.defaultParameterValues()
        manualOverrides.removeAll()
        refreshPose()
    }

    // MARK: - Playback

    public var currentClip: AnimationClip? { currentClipID.flatMap { project.clip($0) } }

    public func seek(_ t: Double) {
        playhead = max(0, t)
        manualOverrides.removeAll()
        if let clip = currentClip, mode == .animate {
            parameterValues = valuesFromClip(clip, at: playhead, keeping: [], base: parameterValues)
            refreshPose()
        }
    }

    public func togglePlayback() {
        if mode != .animate { mode = .animate }
        if !isPlaying, let c = currentClip, c.loopMode == .once, playhead >= c.duration { playhead = 0 }
        isPlaying.toggle()
    }

    /// Frame index under the playhead for the current clip.
    public var currentFrame: Int {
        guard let c = currentClip else { return 0 }
        return Int((c.localTime(playhead) * c.frameRate).rounded())
    }

    // MARK: - Textures

    public func texture(_ id: ObjectID) -> RGBAImage? { bundle.textures[id] }
}
