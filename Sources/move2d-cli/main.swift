import Foundation
import M2DCore
import M2DPSD
import M2DRig
import M2DProject
import M2DExport
import M2DEditor

// move2d-cli — headless companion to the iPad app for batch import and export.

let usage = """
usage:
  move2d-cli info <file.psd>
  move2d-cli import <file.psd> <out.move2d> [--quad] [--spacing N]
  move2d-cli sample <out.move2d> [--size N]
  move2d-cli export <project.move2d> <out> [--clip NAME] [--format gif|png|m2rt] [--size N] [--fps N] [--frames N]
"""

func fail(_ msg: String) -> Never { FileHandle.standardError.write((msg + "\n").data(using: .utf8)!); exit(1) }

var args = Array(CommandLine.arguments.dropFirst())
func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    let v = args[i + 1]; args.removeSubrange(i...i + 1); return v
}
func flag(_ name: String) -> Bool { if let i = args.firstIndex(of: name) { args.remove(at: i); return true }; return false }

guard let command = args.first else { fail(usage) }
args.removeFirst()

do {
    switch command {
    case "info":
        guard let path = args.first else { fail(usage) }
        let doc = try PSDParser.parse([UInt8](try Data(contentsOf: URL(fileURLWithPath: path))))
        print("\(doc.isPSB ? "PSB" : "PSD") \(doc.width)×\(doc.height), \(doc.depth)-bit, \(doc.pixelLayerCount) pixel layers")
        func dump(_ layers: [PSDLayer], _ indent: String) {
            for l in layers {
                let flags = [l.visible ? nil : "hidden", l.clipped ? "clipped" : nil, l.opacity < 1 ? "opacity \(Int(l.opacity * 100))%" : nil,
                             l.blendMode != .normal && l.blendMode != .passThrough ? l.blendMode.rawValue : nil].compactMap { $0 }
                print("\(indent)\(l.kind == .group ? "▾ " : "• ")\(l.name)\(flags.isEmpty ? "" : "  [\(flags.joined(separator: ", "))]")")
                dump(l.children, indent + "  ")
            }
        }
        dump(doc.layers, "")
        for w in doc.warnings { print("warning: \(w)") }

    case "import":
        let quad = flag("--quad")
        let spacing = option("--spacing").flatMap(Float.init) ?? 48
        guard args.count >= 2 else { fail(usage) }
        var opts = PSDImporter.Options()
        opts.meshMode = quad ? .quad : .automatic(spacing: spacing)
        let url = URL(fileURLWithPath: args[0])
        let r = try PSDImporter.importPSD([UInt8](try Data(contentsOf: url)), fileName: url.lastPathComponent, options: opts)
        try ProjectArchive.write(r.bundle, to: URL(fileURLWithPath: args[1]))
        for w in r.warnings { print("warning: \(w)") }
        print("Imported \(r.bundle.project.rig.meshes.count) layers → \(args[1])")

    case "sample":
        let size = option("--size").flatMap(Int.init) ?? 1024
        guard let out = args.first else { fail(usage) }
        let s = try SampleRig.makeSession(size: size)
        try ProjectArchive.write(s.bundle, to: URL(fileURLWithPath: out))
        print("Wrote rigged sample (\(s.rig.meshes.count) meshes, \(s.rig.deformers.count) deformers, \(s.rig.parameters.count) parameters, \(s.project.animations.count) animations) → \(out)")

    case "export":
        let clipName = option("--clip")
        let format = option("--format") ?? "gif"
        let size = option("--size").flatMap(Int.init) ?? 512
        let fps = option("--fps").flatMap(Double.init)
        let frames = option("--frames").flatMap(Int.init)
        guard args.count >= 2 else { fail(usage) }
        let bundle = try ProjectArchive.read(from: URL(fileURLWithPath: args[0]))
        let out = URL(fileURLWithPath: args[1])
        if format == "m2rt" {
            try RuntimeFormat.write(bundle).write(to: out)
            print("Wrote runtime package → \(out.path)"); break
        }
        let clip = clipName.flatMap { n in bundle.project.animations.first { $0.name == n } } ?? bundle.project.animations.first
        let rate = fps ?? clip?.frameRate ?? 30
        let rig = bundle.project.rig
        let h = Int(Float(size) * Float(rig.canvasHeight) / Float(rig.canvasWidth))
        let settings = FrameExportSettings(width: size, height: h, frameRate: rate,
                                           duration: frames.map { Double($0) / rate }, supersample: 2)
        let renderer = FrameRenderer(bundle: bundle, clipID: clip?.id, settings: settings)
        switch format {
        case "gif": try GIFExporter.export(renderer).write(to: out)
        case "png":
            try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            for (name, data) in PNGSequenceExporter.export(renderer, baseName: clip?.name.replacingOccurrences(of: " ", with: "_") ?? "frame") {
                try data.write(to: out.appendingPathComponent(name))
            }
        default: fail("unknown format \(format)")
        }
        print("Exported \(renderer.frameCount) frames of \"\(clip?.name ?? "rest pose")\" → \(out.path)")

    default:
        fail(usage)
    }
} catch {
    fail("error: \(error)")
}
