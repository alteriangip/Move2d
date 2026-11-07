import XCTest
@testable import M2DProject
import M2DPSD
import M2DRig
import M2DCore
import Foundation

final class ProjectTests: XCTestCase {
    func testSampleImportStructure() throws {
        let result = try PSDImporter.importPSD(SampleCharacter.psdData(size: 256), fileName: "Sample.psd")
        let rig = result.bundle.project.rig
        XCTAssertEqual(rig.canvasWidth, 256)
        XCTAssertEqual(rig.name, "Sample")
        XCTAssertNotNil(rig.parts.first { $0.name == "Head" })
        XCTAssertNotNil(rig.parts.first { $0.name == "Eye L" })
        XCTAssertEqual(rig.meshes.count, 13)
        // Hierarchy preserved: root order front-to-back.
        XCTAssertEqual(rig.rootChildren.compactMap { id in rig.part(id)?.name ?? rig.mesh(id)?.name }, ["Head", "Body", "Hair Back"])
        // Clipping became a mask.
        let iris = rig.meshes.first { $0.name == "Eye L Iris" }!
        let white = rig.meshes.first { $0.name == "Eye L White" }!
        XCTAssertEqual(iris.maskIDs, [white.id])
        // Textures trimmed to content.
        let face = rig.meshes.first { $0.name == "Face" }!
        XCTAssertLessThan(face.textureRect.width, 256)
        XCTAssertGreaterThan(face.mesh.triangleCount, 4)
        XCTAssertFalse(result.bundle.project.animations.isEmpty)
    }

    func testArchiveRoundTrip() throws {
        let bundle = try PSDImporter.importPSD(SampleCharacter.psdData(size: 128)).bundle
        let files = try ProjectArchive.encode(bundle)
        XCTAssertNotNil(files["project.json"])
        let back = try ProjectArchive.decode(files)
        XCTAssertEqual(back.project.rig, bundle.project.rig)
        XCTAssertEqual(back.project.animations, bundle.project.animations)
        for (id, img) in bundle.textures { XCTAssertEqual(back.textures[id], img) }
    }

    func testDirectoryWriteRead() throws {
        let bundle = try PSDImporter.importPSD(SampleCharacter.psdData(size: 64)).bundle
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("m2d-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("Test.move2d")
        try ProjectArchive.write(bundle, to: url)
        try ProjectArchive.write(bundle, to: url) // overwrite works
        let back = try ProjectArchive.read(from: url)
        XCTAssertEqual(back.project.rig.meshes.count, bundle.project.rig.meshes.count)
    }

    func testValidationRejectsBrokenMesh() throws {
        var bundle = try PSDImporter.importPSD(SampleCharacter.psdData(size: 64)).bundle
        bundle.project.rig.meshes[0].mesh.indices.append(9999)
        let files = try ProjectArchive.encode(bundle)
        XCTAssertThrowsError(try ProjectArchive.decode(files))
    }

    func testRejectsNewerFormat() throws {
        var bundle = try PSDImporter.importPSD(SampleCharacter.psdData(size: 64)).bundle
        bundle.project.formatVersion = 99
        XCTAssertThrowsError(try ProjectArchive.decode(try ProjectArchive.encode(bundle))) { e in
            guard case ProjectError.newerFormat(99) = e else { return XCTFail("\(e)") }
        }
    }

    func testUpdateArtworkKeepsRig() throws {
        var bundle = try PSDImporter.importPSD(SampleCharacter.psdData(size: 128)).bundle
        let meshCount = bundle.project.rig.meshes.count
        let updated = PSDImporter.updateArtwork(&bundle, from: SampleCharacter.document(size: 128))
        XCTAssertEqual(updated.count, meshCount)
    }
}
