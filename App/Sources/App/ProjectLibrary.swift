import Foundation
import Observation
import M2DCore
import M2DRig
import M2DRender
import M2DProject
import M2DEditor

/// A project stored in the app's library.
struct ProjectEntry: Identifiable, Hashable {
    var url: URL
    var name: String
    var modified: Date
    var id: URL { url }
    var thumbnailURL: URL { url.appendingPathComponent("thumbnail.png") }
}

/// Projects live in Documents/Projects/<name>.move2d (visible in the Files app
/// under "On My iPad › Move2D"). Saving is atomic and runs off the main thread.
@Observable
final class ProjectLibrary {
    private(set) var projects: [ProjectEntry] = []
    var lastError: String?
    let root: URL
    @ObservationIgnored private let saveQueue = DispatchQueue(label: "move2d.save", qos: .utility)

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        root = docs.appendingPathComponent("Projects", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        refresh()
    }

    func refresh() {
        let fm = FileManager.default
        let urls = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        projects = urls.filter { $0.pathExtension == ProjectArchive.fileExtension }.map { u in
            let manifest = u.appendingPathComponent(ProjectArchive.manifestName)
            let date = (try? fm.attributesOfItem(atPath: manifest.path)[.modificationDate] as? Date) ?? .distantPast
            return ProjectEntry(url: u, name: u.deletingPathExtension().lastPathComponent, modified: date)
        }
        .sorted { $0.modified > $1.modified }
    }

    func uniqueURL(for name: String) -> URL {
        let clean = name.replacingOccurrences(of: "/", with: "-").trimmingCharacters(in: .whitespaces)
        let base = clean.isEmpty ? "Untitled" : clean
        var candidate = root.appendingPathComponent("\(base).\(ProjectArchive.fileExtension)")
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = root.appendingPathComponent("\(base) \(n).\(ProjectArchive.fileExtension)"); n += 1
        }
        return candidate
    }

    /// Create a project from a bundle and return its location.
    func create(_ bundle: ProjectBundle, name: String) throws -> URL {
        let url = uniqueURL(for: name)
        try ProjectArchive.write(bundle, to: url, thumbnail: Self.thumbnail(bundle))
        refresh()
        return url
    }

    func load(_ url: URL) throws -> ProjectBundle { try ProjectArchive.read(from: url) }

    /// Save in the background. Completion runs on the main thread.
    func save(_ bundle: ProjectBundle, to url: URL, completion: ((Error?) -> Void)? = nil) {
        saveQueue.async { [weak self] in
            var err: Error?
            do { try ProjectArchive.write(bundle, to: url, thumbnail: Self.thumbnail(bundle)) } catch { err = error }
            DispatchQueue.main.async {
                if let err { self?.lastError = "Couldn't save: \(err)" }
                self?.refresh()
                completion?(err)
            }
        }
    }

    /// Wait for pending saves (used before rename/duplicate/delete).
    func flush() { saveQueue.sync {} }

    func rename(_ entry: ProjectEntry, to name: String) {
        flush()
        let target = uniqueURL(for: name)
        do { try FileManager.default.moveItem(at: entry.url, to: target) } catch { lastError = "\(error)" }
        refresh()
    }

    func duplicate(_ entry: ProjectEntry) {
        flush()
        do { try FileManager.default.copyItem(at: entry.url, to: uniqueURL(for: entry.name + " Copy")) } catch { lastError = "\(error)" }
        refresh()
    }

    func delete(_ entry: ProjectEntry) {
        flush()
        try? FileManager.default.removeItem(at: entry.url)
        refresh()
    }

    /// Copy a .move2d package from elsewhere (Files) into the library.
    func importPackage(at source: URL) throws -> URL {
        let bundle = try ProjectArchive.read(from: source)
        return try create(bundle, name: source.deletingPathExtension().lastPathComponent)
    }

    static func thumbnail(_ b: ProjectBundle) -> RGBAImage? {
        guard !b.project.rig.meshes.isEmpty else { return nil }
        let r = SoftwareRenderer()
        for (id, img) in b.textures { r.setTexture(id, img) }
        var region = Rect.zero
        for m in b.project.rig.meshes where m.visible { region = region.union(Rect.bounding(m.mesh.vertices)) }
        let side = max(region.width, region.height) * 1.08
        let square = region.isEmpty ? nil : Rect(x: region.center.x - side / 2, y: region.center.y - side / 2, width: side, height: side)
        return r.renderModel(b.project.rig, values: b.project.rig.defaultParameterValues(), width: 320, height: 320, region: square)
    }
}
