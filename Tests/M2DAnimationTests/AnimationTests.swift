import XCTest
@testable import M2DAnimation
import M2DRig

final class AnimationTests: XCTestCase {
    func testLinearAndStep() {
        var tr = ParameterTrack(parameterID: "P")
        tr.setKey(time: 0, value: 0, interpolation: .linear)
        tr.setKey(time: 1, value: 10, interpolation: .constant)
        tr.setKey(time: 2, value: 20)
        XCTAssertEqual(tr.value(at: 0.5)!, 5, accuracy: 1e-4)
        XCTAssertEqual(tr.value(at: 1.5)!, 10, accuracy: 1e-4)
        XCTAssertEqual(tr.value(at: 5)!, 20, accuracy: 1e-4)
        tr.setKey(time: 1, value: 12)
        XCTAssertEqual(tr.keyframes.count, 3, "setting an existing key replaces it")
    }

    func testEasingIsMonotonicAndSymmetric() {
        let k0 = Keyframe(time: 0, value: 0, interpolation: .easeInOut), k1 = Keyframe(time: 1, value: 1)
        var prev: Float = -1
        for i in 0...20 {
            let v = CurveMath.segment(k0, k1, at: Double(i) / 20)
            XCTAssertGreaterThanOrEqual(v, prev); prev = v
        }
        XCTAssertEqual(CurveMath.segment(k0, k1, at: 0.5), 0.5, accuracy: 1e-3)
        XCTAssertLessThan(CurveMath.segment(k0, k1, at: 0.2), 0.2)
    }

    func testBezierHandlesOvershoot() {
        let k0 = Keyframe(time: 0, value: 0, interpolation: .bezier, outHandle: CurveHandle(x: 0.33, y: 2))
        let k1 = Keyframe(time: 1, value: 1, inHandle: CurveHandle(x: 0.33, y: 0))
        let peak = (0...100).map { CurveMath.segment(k0, k1, at: Double($0) / 100) }.max()!
        XCTAssertGreaterThan(peak, 1)
        XCTAssertEqual(CurveMath.segment(k0, k1, at: 1), 1, accuracy: 1e-4)
    }

    func testLoopModes() {
        var c = AnimationClip(name: "c", duration: 2, loopMode: .loop)
        XCTAssertEqual(c.localTime(2.5), 0.5, accuracy: 1e-9)
        c.loopMode = .pingPong
        XCTAssertEqual(c.localTime(2.5), 1.5, accuracy: 1e-9)
        c.loopMode = .once
        XCTAssertEqual(c.localTime(9), 2, accuracy: 1e-9)
    }

    func testLayeredPlaybackAdditive() {
        let params = [Parameter(id: "A", name: "A", min: -10, max: 10)]
        var base = AnimationClip(id: "base", name: "base", duration: 1)
        base.tracks = [ParameterTrack(parameterID: "A", keyframes: [Keyframe(time: 0, value: 4)])]
        var add = AnimationClip(id: "add", name: "add", duration: 1)
        add.tracks = [ParameterTrack(parameterID: "A", keyframes: [Keyframe(time: 0, value: 3)])]
        var player = AnimationPlayer()
        player.layers = [AnimationLayer(clipID: "base"), AnimationLayer(clipID: "add", weight: 0.5, additive: true)]
        var v = ParameterValues.defaults(params)
        player.apply(clips: [base, add], parameters: params, to: &v)
        XCTAssertEqual(v["A"]!, 5.5, accuracy: 1e-4)
    }

    func testIdlePreset() {
        let clip = AnimationPresets.idle(for: Parameter.standardSet())
        XCTAssertTrue(clip.tracks.contains { $0.parameterID == "ParamBreath" })
        XCTAssertEqual(clip.track("ParamEyeLOpen")!.value(at: 1.66)!, 0, accuracy: 0.2)
        XCTAssertEqual(clip.track("ParamEyeLOpen")!.value(at: 1.0)!, 1, accuracy: 1e-3)
    }
}
