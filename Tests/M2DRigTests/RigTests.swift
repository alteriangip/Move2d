import XCTest
@testable import M2DRig
import M2DCore

final class KeyformTests: XCTestCase {
    func testSingleBindingInterpolation() {
        var g = KeyformGrid(rest: RotationForm(origin: .zero))
        g.addBinding("A", keys: [-10, 0, 10])
        XCTAssertEqual(g.formCount, 3)
        g.forms[0].angle = -30; g.forms[2].angle = 30
        XCTAssertEqual(g.evaluate(ParameterValues(["A": 5])).angle, 15, accuracy: 1e-4)
        XCTAssertEqual(g.evaluate(ParameterValues(["A": -10])).angle, -30, accuracy: 1e-4)
        XCTAssertEqual(g.evaluate(ParameterValues(["A": 50])).angle, 30, accuracy: 1e-4) // clamped
        XCTAssertEqual(g.exactFormIndex(ParameterValues(["A": 10])), 2)
        XCTAssertNil(g.exactFormIndex(ParameterValues(["A": 3])))
    }

    func testBilinearTwoBindings() {
        var g = KeyformGrid(rest: RotationForm(origin: .zero))
        g.addBinding("X", keys: [0, 1])
        g.addBinding("Y", keys: [0, 1])
        XCTAssertEqual(g.formCount, 4)
        g.forms[g.flatIndex([1, 0])].angle = 10
        g.forms[g.flatIndex([0, 1])].angle = 20
        g.forms[g.flatIndex([1, 1])].angle = 40
        XCTAssertEqual(g.evaluate(ParameterValues(["X": 0.5, "Y": 0.5])).angle, 17.5, accuracy: 1e-4)
    }

    func testAddKeyPreservesShape() {
        var g = KeyformGrid(rest: RotationForm(origin: .zero))
        g.addBinding("A", keys: [0, 1])
        g.forms[1].angle = 10
        g.addKey("A", value: 0.25)
        XCTAssertEqual(g.binding(for: "A")!.keys, [0, 0.25, 1])
        XCTAssertEqual(g.forms[1].angle, 2.5, accuracy: 1e-4)
        XCTAssertEqual(g.evaluate(ParameterValues(["A": 0.6])).angle, 6, accuracy: 1e-4)
        g.removeKey("A", value: 0.25)
        XCTAssertEqual(g.formCount, 2)
        g.removeBinding("A", keeping: 1)
        XCTAssertEqual(g.formCount, 1)
        XCTAssertEqual(g.forms[0].angle, 10)
    }
}

final class DeformerTests: XCTestCase {
    func testWarpIdentityAndShift() {
        let w = WarpDeformer(rect: Rect(x: 0, y: 0, width: 100, height: 100), columns: 2, rows: 2)
        let rest = w.keyforms.forms[0].points
        let p = Vec2(33, 71)
        XCTAssertEqual(w.map(p, points: rest).x, 33, accuracy: 1e-4)
        let shifted = rest.map { $0 + Vec2(5, -3) }
        let q = w.map(p, points: shifted)
        XCTAssertEqual(q.x, 38, accuracy: 1e-4); XCTAssertEqual(q.y, 68, accuracy: 1e-4)
        // Extrapolation outside the lattice stays continuous.
        XCTAssertEqual(w.map(Vec2(-10, 50), points: rest).x, -10, accuracy: 1e-4)
    }

    func testWarpResamplePreservesDeformation() {
        var w = WarpDeformer(rect: Rect(x: 0, y: 0, width: 100, height: 100), columns: 1, rows: 1)
        w.keyforms.forms[0].points[3] += Vec2(20, 20)
        let probe = Vec2(50, 50)
        let before = w.map(probe, points: w.keyforms.forms[0].points)
        w.resample(columns: 4, rows: 4)
        XCTAssertEqual(w.pointCount, 25)
        let after = w.map(probe, points: w.keyforms.forms[0].points)
        XCTAssertEqual(before.x, after.x, accuracy: 1e-3); XCTAssertEqual(before.y, after.y, accuracy: 1e-3)
    }

    func testRotationAndPivotMove() {
        var r = RotationDeformer(origin: Vec2(10, 10))
        r.keyforms.forms[0].angle = 90
        let p = r.map(Vec2(20, 10), form: r.keyforms.forms[0])
        XCTAssertEqual(p.x, 10, accuracy: 1e-4); XCTAssertEqual(p.y, 20, accuracy: 1e-4)
        let probe = Vec2(33, -4)
        let before = r.map(probe, form: r.keyforms.forms[0])
        r.movePivot(to: Vec2(50, 0))
        let after = r.map(probe, form: r.keyforms.forms[0])
        XCTAssertEqual(before.x, after.x, accuracy: 1e-3); XCTAssertEqual(before.y, after.y, accuracy: 1e-3)
    }

    func makeModel() -> RigModel {
        var m = RigModel(name: "T", canvasWidth: 200, canvasHeight: 200)
        m.parameters = [Parameter(id: "P", name: "P", min: -1, max: 1)]
        m.textures = [TextureInfo(id: "t", name: "t", width: 10, height: 10)]
        var warp = Deformer(id: "warp", name: "Warp", kind: .warp(WarpDeformer(rect: Rect(x: 0, y: 0, width: 200, height: 200), columns: 2, rows: 2)))
        if case var .warp(w) = warp.kind {
            w.keyforms.addBinding("P", keys: [0, 1])
            w.keyforms.forms[1].points = w.keyforms.forms[1].points.map { $0 + Vec2(10, 0) }
            warp.kind = .warp(w)
        }
        var rot = Deformer(id: "rot", name: "Rot", parentID: "warp", kind: .rotation(RotationDeformer(origin: Vec2(100, 100))))
        if case var .rotation(r) = rot.kind {
            r.keyforms.addBinding("P", keys: [0, 1])
            r.keyforms.forms[1].angle = 90
            rot.kind = .rotation(r)
        }
        m.deformers = [rot, warp] // deliberately child first
        let mesh = ArtMesh(id: "mesh", name: "Mesh", textureID: "t", textureRect: Rect(x: 100, y: 90, width: 20, height: 20), deformerID: "rot")
        m.meshes = [mesh]
        m.rootChildren = ["mesh"]
        return m
    }

    func testNestedEvaluation() {
        let m = makeModel()
        let ev = RigEvaluator(model: m)
        let rest = ev.evaluate(ParameterValues(["P": 0]))
        XCTAssertEqual(rest.meshes["mesh"]!.positions[0].x, 100, accuracy: 1e-3)
        let posed = ev.evaluate(ParameterValues(["P": 1]))
        // (100,90) rotated 90° about (100,100) → (110,100), then warp shifts +10 x → (120,100)
        let p = posed.meshes["mesh"]!.positions[0]
        XCTAssertEqual(p.x, 120, accuracy: 1e-3); XCTAssertEqual(p.y, 100, accuracy: 1e-3)
        XCTAssertEqual(posed.deformers["rot"]!.angle, 90, accuracy: 1e-2)
        XCTAssertEqual(m.deformersTopological().map(\.id), ["warp", "rot"])
        XCTAssertTrue(m.wouldCreateCycle(deformer: "warp", parent: "rot"))
    }

    func testCanvasDeltaToLocalInvertsChain() {
        let m = makeModel()
        let ev = RigEvaluator(model: m)
        let vals = ParameterValues(["P": 1])
        let local = ev.canvasDeltaToLocal(Vec2(0, 5), at: Vec2(100, 90), through: "rot", values: vals)
        // Rotation by 90° maps local +x to canvas +y.
        XCTAssertEqual(local.x, 5, accuracy: 1e-2); XCTAssertEqual(local.y, 0, accuracy: 1e-2)
    }
}

final class MeshTests: XCTestCase {
    func testDelaunaySquare() {
        let tris = Delaunay.triangulate([Vec2(0, 0), Vec2(10, 0), Vec2(10, 10), Vec2(0, 10), Vec2(5, 5)])
        XCTAssertEqual(tris.count, 4)
    }

    func testDelaunayGridCount() {
        var pts: [Vec2] = []
        for y in 0..<10 { for x in 0..<10 { pts.append(Vec2(Float(x) * 10 + Float(y % 2) * 0.01, Float(y) * 10)) } }
        let tris = Delaunay.triangulate(pts)
        // Euler: triangles = 2n - 2 - hull points (hull = 36) → 162.
        XCTAssertEqual(tris.count, 162)
    }

    func testAddRemoveVertex() {
        let rect = Rect(x: 0, y: 0, width: 10, height: 10)
        var m = Mesh.quad(rect)
        let (i, src) = m.addVertex(Vec2(6, 3), textureRect: rect)
        XCTAssertEqual(i, 4); XCTAssertEqual(m.triangleCount, 4)
        if case .interpolated = src {} else { XCTFail("expected interpolated source") }
        XCTAssertEqual(m.uvs[4].x, 0.6, accuracy: 1e-5)
        let old = m.removeVertices([4])
        XCTAssertEqual(old, [0, 1, 2, 3])
        XCTAssertEqual(m.vertexCount, 4)
        XCTAssertEqual(m.triangleCount, 2, "hole should be re-triangulated")
    }

    func testSubdivideWatertight() {
        let rect = Rect(x: 0, y: 0, width: 10, height: 10)
        var m = Mesh.quad(rect)
        m.subdivide([0], textureRect: rect)
        // Area must be preserved and no T-junction: boundary edges only on the outline.
        var area: Float = 0
        for t in 0..<m.triangleCount { let (a, b, c) = m.triangle(t); area += abs(Geometry.orient(m.vertices[a], m.vertices[b], m.vertices[c])) / 2 }
        XCTAssertEqual(area, 100, accuracy: 1e-3)
        for (a, b) in m.boundaryEdges {
            let mid = (m.vertices[a] + m.vertices[b]) / 2
            XCTAssertTrue(mid.x < 1e-3 || mid.y < 1e-3 || mid.x > 9.999 || mid.y > 9.999, "interior boundary edge \(a)-\(b)")
        }
    }

    func testArtMeshKeyformsFollowTopology() {
        let rect = Rect(x: 0, y: 0, width: 10, height: 10)
        var art = ArtMesh(name: "m", textureID: "t", textureRect: rect)
        art.keyforms.forms[0].offsets = [Vec2(1, 0), Vec2(1, 0), Vec2(1, 0), Vec2(1, 0)]
        var mesh = art.mesh
        let (_, src) = mesh.addVertex(Vec2(5, 5), textureRect: rect)
        art.setMesh(mesh, sources: (0..<4).map { .existing($0) } + [src])
        XCTAssertEqual(art.keyforms.forms[0].offsets.count, 5)
        XCTAssertEqual(art.keyforms.forms[0].offsets[4].x, 1, accuracy: 1e-5)
    }

    func testMeshGeneratorFollowsAlpha() {
        // A filled disc in a 200x200 image.
        var img = RGBAImage(width: 200, height: 200)
        for y in 0..<200 { for x in 0..<200 {
            let d = Vec2(Float(x) + 0.5, Float(y) + 0.5) - Vec2(100, 100)
            if d.length < 80 { img.pixels[(y * 200 + x) * 4 + 3] = 255 }
        }}
        let m = MeshGenerator.generate(image: img, rect: Rect(x: 0, y: 0, width: 200, height: 200), settings: .init(spacing: 20))
        XCTAssertGreaterThan(m.triangleCount, 20)
        // No vertex far outside the disc; area roughly matches.
        for v in m.vertices { XCTAssertLessThan((v - Vec2(100, 100)).length, 92) }
        var area: Float = 0
        for t in 0..<m.triangleCount { let (a, b, c) = m.triangle(t); area += abs(Geometry.orient(m.vertices[a], m.vertices[b], m.vertices[c])) / 2 }
        XCTAssertGreaterThan(area, .pi * 80 * 80 * 0.95)
        XCTAssertLessThan(area, .pi * 86 * 86)
        // Every opaque pixel is covered by some triangle.
        for (x, y) in [(100, 100), (100, 25), (175, 100), (45, 45)] {
            XCTAssertNotNil(m.triangle(containing: Vec2(Float(x), Float(y))), "pixel \(x),\(y) uncovered")
        }
    }
}
