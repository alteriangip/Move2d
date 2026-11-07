import SwiftUI
import UniformTypeIdentifiers

@main
struct Move2DApp: App {
    @State private var library = ProjectLibrary()

    var body: some Scene {
        WindowGroup {
            HomeView(library: library)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
        }
    }
}

extension UTType {
    /// Native project package (directory with project.json + textures/).
    static let move2dProject = UTType(exportedAs: "app.move2d.project", conformingTo: .package)
    /// Runtime package for games.
    static let move2dRuntime = UTType(exportedAs: "app.move2d.runtime", conformingTo: .data)
    static let photoshopDocument = UTType(importedAs: "com.adobe.photoshop-image", conformingTo: .image)
}
