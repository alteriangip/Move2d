import SwiftUI
import UniformTypeIdentifiers
import M2DCore
import M2DRig
import M2DRender
import M2DProject
import M2DEditor

extension UTType {
    /// Native project package (directory with project.json + textures/).
    static let move2dProject = UTType(exportedAs: "app.move2d.project", conformingTo: .package)
    /// Runtime package for games.
    static let move2dRuntime = UTType(exportedAs: "app.move2d.runtime", conformingTo: .data)
    static let photoshopDocument = UTType(importedAs: "com.adobe.photoshop-image", conformingTo: .image)
}

/// Document wrapper around an `EditorSession`. Saving snapshots the bundle on the
/// main thread and encodes PNG textures in the background.
final class Move2DDocument: ReferenceFileDocument {
    static var readableContentTypes: [UTType] { [.move2dProject] }
    static var writableContentTypes: [UTType] { [.move2dProject] }

    let session: EditorSession

    init() { session = EditorSession() }

    init(configuration: ReadConfiguration) throws {
        var files: [String: Data] = [:]
        func collect(_ w: FileWrapper, prefix: String) {
            for (name, child) in w.fileWrappers ?? [:] {
                if child.isDirectory { collect(child, prefix: prefix + name + "/") }
                else if let d = child.regularFileContents { files[prefix + name] = d }
            }
        }
        guard configuration.file.isDirectory else { throw CocoaError(.fileReadCorruptFile) }
        collect(configuration.file, prefix: "")
        session = EditorSession(bundle: try ProjectArchive.decode(files))
    }

    func snapshot(contentType: UTType) throws -> ProjectBundle { session.bundle }

    func fileWrapper(snapshot: ProjectBundle, configuration: WriteConfiguration) throws -> FileWrapper {
        let thumb = Self.thumbnail(snapshot)
        let files = try ProjectArchive.encode(snapshot, thumbnail: thumb)
        let root = FileWrapper(directoryWithFileWrappers: [:])
        let textures = FileWrapper(directoryWithFileWrappers: [:])
        textures.preferredFilename = "textures"
        for (path, data) in files {
            if path.hasPrefix("textures/") {
                let w = FileWrapper(regularFileWithContents: data)
                w.preferredFilename = String(path.dropFirst("textures/".count))
                textures.addFileWrapper(w)
            } else {
                let w = FileWrapper(regularFileWithContents: data)
                w.preferredFilename = path
                root.addFileWrapper(w)
            }
        }
        root.addFileWrapper(textures)
        return root
    }

    static func thumbnail(_ b: ProjectBundle) -> RGBAImage? {
        guard !b.project.rig.meshes.isEmpty else { return nil }
        let r = SoftwareRenderer()
        for (id, img) in b.textures { r.setTexture(id, img) }
        return r.renderModel(b.project.rig, values: b.project.rig.defaultParameterValues(), width: 256, height: 256)
    }
}
