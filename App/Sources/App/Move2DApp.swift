import SwiftUI

@main
struct Move2DApp: App {
    var body: some Scene {
        DocumentGroup(newDocument: { Move2DDocument() }) { file in
            EditorRootView(document: file.document)
                .preferredColorScheme(.dark)
        }
    }
}
