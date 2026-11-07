import XCTest
@testable import M2DPhysics
import M2DRig

final class PhysicsTests: XCTestCase {
    let params = [Parameter(id: "In", name: "In", min: -10, max: 10), Parameter(id: "Out", name: "Out", min: -1, max: 1)]

    func rig() -> PhysicsRig {
        PhysicsRig(groups: [PhysicsGroup(id: "g", name: "Hair",
                                         inputs: [PhysicsInput(parameterID: "In", kind: .translationX)],
                                         outputs: [PhysicsOutput(parameterID: "Out", particleIndex: 2, angleRange: 30)],
                                         particles: [PhysicsParticle(), PhysicsParticle()])])
    }

    func testRestIsStable() {
        var sim = PhysicsSimulator(rig: rig())
        var v = ParameterValues.defaults(params)
        for _ in 0..<240 { sim.step(dt: 1 / 60, parameters: params, values: &v) }
        XCTAssertEqual(v["Out"]!, 0, accuracy: 0.02)
    }

    func testFollowThroughAndSettle() {
        var sim = PhysicsSimulator(rig: rig())
        var v = ParameterValues.defaults(params)
        sim.step(dt: 1 / 60, parameters: params, values: &v)
        // Jerk the anchor to the right: the chain lags behind (swings left relative to anchor).
        var peak: Float = 0
        for _ in 0..<30 { v["In"] = 10; sim.step(dt: 1 / 60, parameters: params, values: &v); peak = max(peak, abs(v["Out"]!)) }
        XCTAssertGreaterThan(peak, 0.1, "chain should swing")
        for _ in 0..<600 { v["In"] = 10; sim.step(dt: 1 / 60, parameters: params, values: &v) }
        XCTAssertEqual(v["Out"]!, 0, accuracy: 0.05, "chain should settle")
        XCTAssertTrue(v["Out"]!.isFinite)
    }

    func testAngleInputTiltsRestDirection() {
        var r = rig()
        r.groups[0].inputs = [PhysicsInput(parameterID: "In", kind: .angle)]
        var sim = PhysicsSimulator(rig: r)
        var v = ParameterValues.defaults(params)
        v["In"] = 10
        for _ in 0..<600 { sim.step(dt: 1 / 60, parameters: params, values: &v) }
        // Output is measured relative to the tilted frame, so it settles near zero again.
        XCTAssertEqual(v["Out"]!, 0, accuracy: 0.15)
    }
}
