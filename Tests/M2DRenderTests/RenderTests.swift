import XCTest
@testable import M2DRender
import M2DRig
import M2DCore

final class RenderTests: XCTestCase {
    func model() -> RigModel {
        var m = RigModel(name: "R", canvasWidth: 20, canvasHeight: 20)
        m.textures = [TextureInfo(id: "red", name: "red", width: 4, height: 4), TextureInfo(id: "blue", name: "blue", width: 4, height: 4)]
        var back = ArtMesh(id: "back", name: "back", textureID: "red", textureRect: Rect(x: 0, y: 0, width: 20, height: 20))
        back.keyforms.forms[0].drawOrder = 500
        let front = ArtMesh(id: "front", name: "front", textureID: "blue", textureRect: Rect(x: 5, y: 5, width: 10, height: 10))
        m.meshes = [back, front]
        m.rootChildren = ["front", "back"]
        return m
    }

    func renderer() -> SoftwareRenderer {
        let r = SoftwareRenderer()
        r.setTexture("red", RGBAImage(width: 4, height: 4, fill: (255, 0, 0, 255)))
        r.setTexture("blue", RGBAImage(width: 4, height: 4, fill: (0, 0, 255, 255)))
        return r
    }

    func testHierarchyOrderAndCoverage() {
        let m = model()
        let img = renderer().renderModel(m, values: ParameterValues(), width: 20, height: 20)
        XCTAssertEqual(img.pixel(1, 1).0, 255)
        XCTAssertEqual(img.pixel(10, 10).2, 255, "front mesh draws over back mesh")
        XCTAssertEqual(img.pixel(10, 10).0, 0)
    }

    func testDrawOrderKeyformOverridesHierarchy() {
        var m = model()
        m.meshes[0].keyforms.forms[0].drawOrder = 900
        let img = renderer().renderModel(m, values: ParameterValues(), width: 20, height: 20)
        XCTAssertEqual(img.pixel(10, 10).0, 255)
    }

    func testOpacityAndMask() {
        var m = model()
        m.meshes[0].keyforms.forms[0].opacity = 0.5
        let img = renderer().renderModel(m, values: ParameterValues(), width: 20, height: 20)
        XCTAssertEqual(Int(img.pixel(1, 1).3), 128, accuracy: 2)

        var masked = model()
        masked.meshes[0].maskIDs = ["front"] // red clipped to the blue square
        masked.meshes[0].keyforms.forms[0].drawOrder = 900
        let img2 = renderer().renderModel(masked, values: ParameterValues(), width: 20, height: 20)
        XCTAssertEqual(img2.pixel(1, 1).3, 0, "outside mask is clipped")
        XCTAssertEqual(img2.pixel(10, 10).0, 255, "inside mask is drawn")
    }

    func testHiddenPartHidesChildren() {
        var m = model()
        m.parts = [Part(id: "p", name: "p", children: ["front"], visible: false)]
        m.meshes[1].partID = "p"
        m.rootChildren = ["p", "back"]
        let img = renderer().renderModel(m, values: ParameterValues(), width: 20, height: 20)
        XCTAssertEqual(img.pixel(10, 10).0, 255)
    }
}
