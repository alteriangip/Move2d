import Foundation
import M2DCore
import M2DRig
import M2DAnimation
import M2DPhysics
import M2DRender
import M2DProject

/// Settings shared by all frame-based exporters.
public struct FrameExportSettings: Sendable {
    public var width: Int
    public var height: Int
    /// Canvas region to frame; nil = whole canvas.
    public var region: Rect?
    public var frameRate: Double
    /// Explicit duration; nil uses the clip's duration (one loop).
    public var duration: Double?
    /// Premultiplied background; alpha 0 keeps transparency.
    public var background: SIMD4<Float>
    public var supersample: Int
    public var physicsEnabled: Bool
    /// Seconds of physics simulation run before the first frame so loops start settled.
    public var physicsWarmup: Double

    public init(width: Int, height: Int, region: Rect? = nil, frameRate: Double = 30, duration: Double? = nil,
                background: SIMD4<Float> = .zero, supersample: Int = 1, physicsEnabled: Bool = true, physicsWarmup: Double = 2) {
        self.width = width; self.height = height; self.region = region; self.frameRate = frameRate
        self.duration = duration; self.background = background; self.supersample = supersample
        self.physicsEnabled = physicsEnabled; self.physicsWarmup = physicsWarmup
    }
}

/// Deterministically renders the frames of an animation clip (animation → physics → rig → raster).
public final class FrameRenderer {
    public let bundle: ProjectBundle
    public let clip: AnimationClip?
    public let settings: FrameExportSettings
    let evaluator: RigEvaluator
    let renderer = SoftwareRenderer()
    var physics: PhysicsSimulator
    public let frameCount: Int
    var nextFrame = 0

    public init(bundle: ProjectBundle, clipID: ObjectID?, settings: FrameExportSettings) {
        self.bundle = bundle
        clip = clipID.flatMap { bundle.project.clip($0) }
        self.settings = settings
        evaluator = RigEvaluator(model: bundle.project.rig)
        renderer.supersample = settings.supersample
        for (id, img) in bundle.textures { renderer.setTexture(id, img) }
        physics = PhysicsSimulator(rig: bundle.project.physics)
        let duration = settings.duration ?? clip?.duration ?? 1
        frameCount = max(1, Int((duration * settings.frameRate).rounded()))
        if settings.physicsEnabled && settings.physicsWarmup > 0 {
            // Warm up by playing the end of the loop so frame 0 continues seamlessly.
            let steps = Int(settings.physicsWarmup * settings.frameRate)
            let d = clip?.duration ?? 1
            for i in 0..<steps {
                var v = parameterValues(at: d - settings.physicsWarmup + Double(i) / settings.frameRate)
                physics.step(dt: 1 / settings.frameRate, parameters: bundle.project.rig.parameters, values: &v)
            }
        }
    }

    func parameterValues(at t: Double) -> ParameterValues {
        var v = bundle.project.rig.defaultParameterValues()
        clip?.apply(at: t, to: &v, parameters: bundle.project.rig.parameters)
        return v
    }

    public func time(ofFrame i: Int) -> Double { Double(i) / settings.frameRate }

    /// Render the next frame in sequence (physics requires sequential stepping).
    public func renderNext() -> RGBAImage? {
        guard nextFrame < frameCount else { return nil }
        let t = time(ofFrame: nextFrame)
        var values = parameterValues(at: t)
        if settings.physicsEnabled {
            physics.step(dt: nextFrame == 0 ? 0 : 1 / settings.frameRate, parameters: bundle.project.rig.parameters, values: &values)
        }
        nextFrame += 1
        return renderer.renderModel(bundle.project.rig, evaluator: evaluator, values: values,
                                    width: settings.width, height: settings.height,
                                    region: settings.region, background: settings.background)
    }

    public func renderAll(progress: ((Double) -> Void)? = nil) -> [RGBAImage] {
        var frames: [RGBAImage] = []
        while let f = renderNext() {
            frames.append(f)
            progress?(Double(frames.count) / Double(frameCount))
        }
        return frames
    }
}

public enum PNGSequenceExporter {
    /// Returns `name_0000.png`… file contents.
    public static func export(_ renderer: FrameRenderer, baseName: String = "frame",
                              progress: ((Double) -> Void)? = nil) -> [String: Data] {
        var files: [String: Data] = [:]
        var i = 0
        while let frame = renderer.renderNext() {
            files[String(format: "%@_%04d.png", baseName, i)] = PNG.encode(frame)
            i += 1
            progress?(Double(i) / Double(renderer.frameCount))
        }
        return files
    }
}
