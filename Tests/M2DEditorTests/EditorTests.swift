import XCTest
@testable import M2DEditor
import M2DProject
import M2DRig
import M2DCore

final class EditorTests: XCTestCase {
    func session() throws -> EditorSession {
        var o = PSDImporter.Options(); o.meshMode = .quad
        return try EditorSession.importingPSD(SampleCharacter.psdData(size: 256), fileName: "s.psd", options: o).0
    }

    func testUndoRedoRename() throws {
        let s = try session()
        let id = s.rig.meshes[0].id
        let old = s.rig.meshes[0].name
        s.rename(id, to: "Renamed")
        XCTAssertEqual(s.rig.mesh(id)?.name, "Renamed")
        XCTAssertTrue(s.isDirty)
        s.undo(); XCTAssertEqual(s.rig.mesh(id)?.name, old)
        s.redo(); XCTAssertEqual(s.rig.mesh(id)?.name, "Renamed")
    }

    func testGestureIsOneUndoStep() throws {
        let s = try session()
        let id = s.rig.meshes.first { $0.name == "Face" }!.id
        let before = s.pose.meshes[id]!.positions[0]
        s.beginGesture("Drag")
        for _ in 0..<10 { s.deformVertices(id, [0], byCanvasDelta: Vec2(1, 0)) }
        s.endGesture()
        XCTAssertEqual(s.pose.meshes[id]!.positions[0].x, before.x + 10, accuracy: 1e-3)
        s.undo()
        XCTAssertEqual(s.pose.meshes[id]!.positions[0].x, before.x, accuracy: 1e-3)
        XCTAssertFalse(s.canUndo)
    }

    func testGroupUngroupAndMove() throws {
        let s = try session()
        let body = s.rig.meshes.first { $0.name == "Body" }!.id
        let hairBack = s.rig.meshes.first { $0.name == "Hair Back" }!.id
        s.selection.objects = [body, hairBack]
        let g = s.groupSelection(name: "Torso")!
        XCTAssertEqual(s.rig.part(g)?.children, [body, hairBack])
        XCTAssertEqual(s.rig.mesh(body)?.partID, g)
        XCTAssertTrue(s.rig.rootChildren.contains(g))
        s.ungroup(g)
        XCTAssertNil(s.rig.part(g))
        XCTAssertTrue(s.rig.rootChildren.contains(body))
        s.moveNode(hairBack, toParent: nil, at: 0)
        XCTAssertEqual(s.rig.rootChildren.first, hairBack)
        XCTAssertEqual(s.rig.meshesBackToFront().last, hairBack, "front-most in hierarchy draws last")
    }

    func testDeformRequiresKey() throws {
        let s = try session()
        let face = s.rig.meshes.first { $0.name == "Face" }!.id
        s.bind([face], to: "ParamAngleX")
        s.setParameterValue("ParamAngleX", 12, fromUser: false)
        XCTAssertFalse(s.deformVertices(face, [0], byCanvasDelta: Vec2(5, 0)))
        XCTAssertNotNil(s.notice)
        s.addKeyAtCurrentValue("ParamAngleX", objectIDs: [face])
        XCTAssertEqual(s.keys(of: "ParamAngleX", for: [face]), [-30, 0, 12, 30])
        XCTAssertTrue(s.deformVertices(face, [0], byCanvasDelta: Vec2(5, 0)))
        s.setParameterValue("ParamAngleX", 21, fromUser: false)
        // Halfway between 12 and 30 → half the displacement.
        let rest = s.rig.mesh(face)!.mesh.vertices[0]
        XCTAssertEqual(s.pose.meshes[face]!.positions[0].x, rest.x + 2.5, accuracy: 1e-3)
    }

    func testWarpWrapsSelectionAndDeforms() throws {
        let s = try session()
        let head = s.rig.parts.first { $0.name == "Head" }!.id
        s.selection.objects = [head]
        let w = s.createWarpDeformer(columns: 2, rows: 2)!
        XCTAssertTrue(s.rig.meshes(inPart: head).allSatisfy { s.rig.mesh($0)?.deformerID == w })
        let face = s.rig.meshes.first { $0.name == "Face" }!.id
        let before = s.pose.meshes[face]!.positions
        XCTAssertTrue(s.moveControlPoints(w, Set(0..<9), byCanvasDelta: Vec2(0, 7)))
        let after = s.pose.meshes[face]!.positions
        XCTAssertEqual(after[0].y, before[0].y + 7, accuracy: 1e-3)
        // Rotation deformer above the warp keeps nesting intact.
        s.selection.objects = [w]
        let r = s.createRotationDeformer(pivot: Vec2(128, 160))!
        XCTAssertEqual(s.rig.deformer(w)?.parentID, r)
        s.setDeformerParent(r, to: w)
        XCTAssertEqual(s.rig.deformer(r)?.parentID, nil, "cycle refused")
        s.deleteDeformer(r)
        XCTAssertNil(s.rig.deformer(w)?.parentID)
    }

    func testMeshTopologyEditsKeepKeyforms() throws {
        let s = try session()
        let face = s.rig.meshes.first { $0.name == "Face" }!.id
        s.bind([face], to: "ParamMouthOpenY")
        let n = s.rig.mesh(face)!.mesh.vertexCount
        let c = s.pose.meshes[face]!.positions.reduce(Vec2.zero, +) / Float(n)
        let idx = s.addVertex(face, atCanvas: c)!
        XCTAssertEqual(s.rig.mesh(face)!.mesh.vertexCount, n + 1)
        XCTAssertTrue(s.rig.mesh(face)!.keyforms.forms.allSatisfy { $0.offsets.count == n + 1 })
        s.selection.vertices[face] = [idx]
        s.removeSelectedVertices()
        XCTAssertEqual(s.rig.mesh(face)!.mesh.vertexCount, n)
        s.autoMesh([face], spacing: 20)
        XCTAssertGreaterThan(s.rig.mesh(face)!.mesh.vertexCount, n)
        s.subdivide(face)
        XCTAssertTrue(s.rig.mesh(face)!.keyforms.forms.allSatisfy { $0.offsets.count == s.rig.mesh(face)!.mesh.vertexCount })
    }

    func testAutoKeyAndPlayback() throws {
        let s = try session()
        let clip = s.addClip(name: "Wave", duration: 2)
        s.mode = .animate
        s.seek(0); s.setParameterValue("ParamAngleX", 0)
        s.seek(1); s.setParameterValue("ParamAngleX", 20)
        XCTAssertEqual(s.project.clip(clip)!.track("ParamAngleX")!.keyframes.count, 2)
        s.seek(0.5)
        XCTAssertGreaterThan(s.value(of: "ParamAngleX"), 0)
        XCTAssertLessThan(s.value(of: "ParamAngleX"), 20)
        s.togglePlayback()
        s.tick(dt: 0.5)
        XCTAssertEqual(s.playhead, 1, accuracy: 1e-9)
        XCTAssertEqual(s.value(of: "ParamAngleX"), 20, accuracy: 1e-3)
    }

    func testDeleteParameterCleansUp() throws {
        let s = try session()
        let face = s.rig.meshes.first { $0.name == "Face" }!.id
        s.bind([face], to: "ParamAngleX")
        s.addClip()
        s.setKeyframe(clipID: s.currentClipID!, parameterID: "ParamAngleX", time: 0, value: 3)
        s.deleteParameter("ParamAngleX")
        XCTAssertTrue(s.bindings(of: face).isEmpty)
        XCTAssertNil(s.currentClip!.track("ParamAngleX"))
    }

    func testHitTestUsesArtworkAlpha() throws {
        let s = try session()
        // Face centre at (128, 107.5) for the 256 sample; the eye white is on top there.
        let hit = s.hitTestMesh(Vec2(128, 135))
        XCTAssertEqual(hit.flatMap { s.rig.mesh($0)?.name }, "Mouth")
        XCTAssertNil(s.hitTestMesh(Vec2(2, 2)))
    }

    func testSampleRigIsValidAndAnimates() throws {
        let s = try SampleRig.makeSession(size: 256)
        XCTAssertNoThrow(try ProjectArchive.validate(s.project))
        XCTAssertEqual(s.project.animations.count, 3)
        XCTAssertEqual(s.project.physics.groups.count, 2)
        let face = s.rig.meshes.first { $0.name == "Face" }!.id
        let rest = s.pose.meshes[face]!.positions
        s.setParameterValue("ParamAngleZ", 30, fromUser: false)
        XCTAssertNotEqual(s.pose.meshes[face]!.positions[0], rest[0])
        XCTAssertFalse(s.isDirty)
        // Physics responds while playing.
        s.resetParameters()
        s.currentClipID = s.project.animations.first { $0.name == "Look Around" }?.id
        s.togglePlayback()
        var sway: Float = 0
        for _ in 0..<90 { s.tick(dt: 1 / 30); sway = max(sway, abs(s.value(of: "ParamHairFront"))) }
        XCTAssertGreaterThan(sway, 0.02)
    }
}
