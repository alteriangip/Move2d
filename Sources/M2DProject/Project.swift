import Foundation
import M2DCore
import M2DRig
import M2DAnimation
import M2DPhysics

/// Everything saved in a Move2D project, apart from texture pixels.
public struct Project: Codable, Hashable, Sendable {
    public static let currentFormatVersion = 1

    public var formatVersion: Int
    public var rig: RigModel
    public var animations: [AnimationClip]
    public var physics: PhysicsRig
    public var metadata: Metadata

    public struct Metadata: Codable, Hashable, Sendable {
        public var createdAt: Date
        public var modifiedAt: Date
        public var generator: String
        public var sourceFileName: String?
        public init(sourceFileName: String? = nil) {
            createdAt = Date(); modifiedAt = createdAt; generator = "Move2D 0.1"; self.sourceFileName = sourceFileName
        }
    }

    public init(rig: RigModel = RigModel(), animations: [AnimationClip] = [], physics: PhysicsRig = PhysicsRig(),
                metadata: Metadata = Metadata()) {
        formatVersion = Self.currentFormatVersion
        self.rig = rig; self.animations = animations; self.physics = physics; self.metadata = metadata
    }

    public func clip(_ id: ObjectID) -> AnimationClip? { animations.first { $0.id == id } }
}

/// A project together with its texture images.
public struct ProjectBundle: Sendable {
    public var project: Project
    public var textures: [ObjectID: RGBAImage]
    public init(project: Project, textures: [ObjectID: RGBAImage] = [:]) {
        self.project = project; self.textures = textures
    }
}

public enum ProjectError: Error, CustomStringConvertible {
    case missingManifest, newerFormat(Int), missingTexture(String), invalid(String)
    public var description: String {
        switch self {
        case .missingManifest: return "The project package has no project.json."
        case let .newerFormat(v): return "This project was saved by a newer version of Move2D (format \(v))."
        case let .missingTexture(n): return "Texture \"\(n)\" is missing from the project package."
        case let .invalid(m): return "Invalid project: \(m)"
        }
    }
}

/// Native `.move2d` package: a directory holding `project.json`, one PNG per
/// texture under `textures/`, and `thumbnail.png`. Plain files keep projects
/// friendly to version control and to the iPadOS Files app (as a package).
public enum ProjectArchive {
    public static let manifestName = "project.json"
    public static let fileExtension = "move2d"

    public static func encode(_ bundle: ProjectBundle, thumbnail: RGBAImage? = nil) throws -> [String: Data] {
        var project = bundle.project
        project.metadata.modifiedAt = Date()
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        var files: [String: Data] = [manifestName: try enc.encode(project)]
        for t in project.rig.textures {
            guard let img = bundle.textures[t.id] else { throw ProjectError.missingTexture(t.name) }
            files["textures/\(t.id).png"] = PNG.encode(img)
        }
        if let thumbnail { files["thumbnail.png"] = PNG.encode(thumbnail) }
        return files
    }

    public static func decode(_ files: [String: Data]) throws -> ProjectBundle {
        guard let manifest = files[manifestName] else { throw ProjectError.missingManifest }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        struct VersionProbe: Decodable { var formatVersion: Int }
        let version = try dec.decode(VersionProbe.self, from: manifest).formatVersion
        guard version <= Project.currentFormatVersion else { throw ProjectError.newerFormat(version) }
        let project = try dec.decode(Project.self, from: manifest)
        var textures: [ObjectID: RGBAImage] = [:]
        for t in project.rig.textures {
            guard let data = files["textures/\(t.id).png"] else { throw ProjectError.missingTexture(t.name) }
            textures[t.id] = try PNG.decode(data)
        }
        try validate(project)
        return ProjectBundle(project: project, textures: textures)
    }

    /// Structural checks that keep a damaged file from crashing the evaluator.
    public static func validate(_ p: Project) throws {
        let rig = p.rig
        let tex = Set(rig.textures.map(\.id))
        for m in rig.meshes {
            guard tex.contains(m.textureID) else { throw ProjectError.invalid("mesh \(m.name) references a missing texture") }
            guard m.mesh.uvs.count == m.mesh.vertexCount else { throw ProjectError.invalid("mesh \(m.name) has mismatched UVs") }
            guard m.mesh.indices.allSatisfy({ Int($0) < m.mesh.vertexCount }) else { throw ProjectError.invalid("mesh \(m.name) has out-of-range indices") }
            guard m.keyforms.forms.allSatisfy({ $0.offsets.count == m.mesh.vertexCount }) else { throw ProjectError.invalid("mesh \(m.name) has mismatched keyforms") }
        }
        for d in rig.deformers {
            if case let .warp(w) = d.kind, !w.keyforms.forms.allSatisfy({ $0.points.count == w.pointCount }) {
                throw ProjectError.invalid("warp deformer \(d.name) has mismatched keyforms")
            }
            if rig.wouldCreateCycle(deformer: d.id, parent: d.parentID) || d.parentID == d.id {
                throw ProjectError.invalid("deformer \(d.name) is its own ancestor")
            }
        }
    }

    // MARK: File system

    public static func write(_ bundle: ProjectBundle, to url: URL, thumbnail: RGBAImage? = nil) throws {
        let files = try encode(bundle, thumbnail: thumbnail)
        let fm = FileManager.default
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).saving-\(UUID().uuidString)")
        try fm.createDirectory(at: tmp.appendingPathComponent("textures"), withIntermediateDirectories: true)
        for (path, data) in files { try data.write(to: tmp.appendingPathComponent(path)) }
        if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
        try fm.moveItem(at: tmp, to: url)
    }

    public static func read(from url: URL) throws -> ProjectBundle {
        var files: [String: Data] = [:]
        let fm = FileManager.default
        files[manifestName] = try Data(contentsOf: url.appendingPathComponent(manifestName))
        let texDir = url.appendingPathComponent("textures")
        if let names = try? fm.contentsOfDirectory(atPath: texDir.path) {
            for n in names where n.hasSuffix(".png") { files["textures/\(n)"] = try Data(contentsOf: texDir.appendingPathComponent(n)) }
        }
        return try decode(files)
    }
}
