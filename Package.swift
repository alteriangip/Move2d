// swift-tools-version:5.9
import PackageDescription

// Move2D — a native 2D character rigging & animation studio.
//
// The engine is split into small, independent modules. Everything except
// M2DMetal (and the Apple-only video exporter inside M2DExport) is plain Swift
// with no platform dependencies, so it builds and is tested on Linux as well
// as on iPadOS / macOS.
let package = Package(
    name: "Move2D",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "M2DCore", targets: ["M2DCore"]),
        .library(name: "M2DPSD", targets: ["M2DPSD"]),
        .library(name: "M2DRig", targets: ["M2DRig"]),
        .library(name: "M2DAnimation", targets: ["M2DAnimation"]),
        .library(name: "M2DPhysics", targets: ["M2DPhysics"]),
        .library(name: "M2DRender", targets: ["M2DRender"]),
        .library(name: "M2DMetal", targets: ["M2DMetal"]),
        .library(name: "M2DProject", targets: ["M2DProject"]),
        .library(name: "M2DExport", targets: ["M2DExport"]),
        .library(name: "M2DEditor", targets: ["M2DEditor"]),
        // Lightweight runtime bundle for games: evaluation only, no editor code.
        .library(name: "M2DRuntime", targets: ["M2DCore", "M2DRig", "M2DAnimation", "M2DPhysics", "M2DRender"]),
        .executable(name: "move2d-cli", targets: ["move2d-cli"]),
    ],
    targets: [
        .target(name: "M2DCore"),
        .target(name: "M2DPSD", dependencies: ["M2DCore"]),
        .target(name: "M2DRig", dependencies: ["M2DCore"]),
        .target(name: "M2DAnimation", dependencies: ["M2DCore", "M2DRig"]),
        .target(name: "M2DPhysics", dependencies: ["M2DCore", "M2DRig"]),
        .target(name: "M2DRender", dependencies: ["M2DCore", "M2DRig"]),
        .target(name: "M2DMetal", dependencies: ["M2DCore", "M2DRig", "M2DRender"]),
        .target(name: "M2DProject", dependencies: ["M2DCore", "M2DPSD", "M2DRig", "M2DAnimation", "M2DPhysics"]),
        .target(name: "M2DExport", dependencies: ["M2DCore", "M2DRig", "M2DAnimation", "M2DPhysics", "M2DRender", "M2DProject"]),
        .target(name: "M2DEditor", dependencies: ["M2DCore", "M2DPSD", "M2DRig", "M2DAnimation", "M2DPhysics", "M2DRender", "M2DProject", "M2DExport"]),
        .executableTarget(name: "move2d-cli", dependencies: ["M2DCore", "M2DPSD", "M2DRig", "M2DAnimation", "M2DPhysics", "M2DRender", "M2DProject", "M2DExport", "M2DEditor"]),

        .testTarget(name: "M2DCoreTests", dependencies: ["M2DCore"]),
        .testTarget(name: "M2DPSDTests", dependencies: ["M2DPSD", "M2DCore"]),
        .testTarget(name: "M2DRigTests", dependencies: ["M2DRig", "M2DCore"]),
        .testTarget(name: "M2DAnimationTests", dependencies: ["M2DAnimation", "M2DRig"]),
        .testTarget(name: "M2DPhysicsTests", dependencies: ["M2DPhysics", "M2DRig"]),
        .testTarget(name: "M2DRenderTests", dependencies: ["M2DRender", "M2DRig", "M2DCore"]),
        .testTarget(name: "M2DProjectTests", dependencies: ["M2DProject", "M2DPSD", "M2DRig", "M2DCore"]),
        .testTarget(name: "M2DExportTests", dependencies: ["M2DExport", "M2DProject", "M2DRig", "M2DCore"]),
        .testTarget(name: "M2DEditorTests", dependencies: ["M2DEditor", "M2DProject", "M2DRig", "M2DCore"]),
    ]
)
