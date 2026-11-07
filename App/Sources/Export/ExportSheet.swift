import SwiftUI
import M2DCore
import M2DRig
import M2DProject
import M2DExport
import M2DEditor

enum ExportFormat: String, CaseIterable, Identifiable {
    case gif = "Animated GIF"
    case png = "PNG Sequence"
    case hevcAlpha = "HEVC + Alpha (.mov)"
    case prores = "ProRes 4444 (.mov)"
    case mp4 = "H.264 (.mp4, opaque)"
    case runtime = "Runtime Package (.m2rt)"
    case still = "Still Image (PNG)"
    var id: String { rawValue }
    var isAnimated: Bool { self != .runtime && self != .still }
    var supportsTransparency: Bool { self != .mp4 }
}

/// Export settings and progress. Rendering runs off the main thread on a copy of the project.
struct ExportSheet: View {
    let session: EditorSession
    @Environment(\.dismiss) private var dismiss
    @State private var format: ExportFormat = .gif
    @State private var clipID: ObjectID?
    @State private var size: Int = 1024
    @State private var fps: Double = 30
    @State private var transparent = true
    @State private var background = Color.white
    @State private var loops = 1
    @State private var supersample = true
    @State private var cropToContent = true
    @State private var runtimeScale: Float = 1
    @State private var progress: Double?
    @State private var resultURL: URL?
    @State private var showMover = false
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            Form {
                Picker("Format", selection: $format) { ForEach(ExportFormat.allCases) { Text($0.rawValue).tag($0) } }
                if format.isAnimated {
                    Picker("Animation", selection: $clipID) {
                        ForEach(session.project.animations) { Text($0.name).tag(Optional($0.id)) }
                    }
                    Stepper("Loops: \(loops)", value: $loops, in: 1...20)
                    Picker("Frame rate", selection: $fps) { ForEach([12.0, 15, 24, 30, 60], id: \.self) { Text("\(Int($0)) fps").tag($0) } }
                }
                if format != .runtime {
                    Picker("Size", selection: $size) { ForEach([256, 512, 768, 1024, 1536, 2048, 4096], id: \.self) { Text("\($0) px").tag($0) } }
                    Toggle("Crop to character", isOn: $cropToContent)
                    Toggle("Anti-aliasing (2× supersampling)", isOn: $supersample)
                    if format.supportsTransparency { Toggle("Transparent background", isOn: $transparent) }
                    if !transparent || !format.supportsTransparency { ColorPicker("Background", selection: $background, supportsOpacity: false) }
                } else {
                    Picker("Texture resolution", selection: $runtimeScale) {
                        Text("Full").tag(Float(1)); Text("Half").tag(Float(0.5)); Text("Quarter").tag(Float(0.25))
                    }
                    Text("Packs the rig, animations and physics with texture atlases into one compact file for game engines. See docs/runtime-format.md.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if let progress {
                    Section { ProgressView(value: progress) { Text("Exporting…") } }
                }
                if let errorText { Section { Text(errorText).foregroundStyle(.red) } }
            }
            .navigationTitle("Export")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Export", action: start).disabled(progress != nil) }
            }
            .onAppear { clipID = session.currentClipID ?? session.project.animations.first?.id; fps = session.currentClip?.frameRate ?? 30 }
            .fileMover(isPresented: $showMover, file: resultURL) { result in
                if case let .failure(e) = result { errorText = e.localizedDescription } else { dismiss() }
            }
        }
    }

    func backgroundColor() -> SIMD4<Float> {
        if transparent && format.supportsTransparency { return .zero }
        let ui = UIColor(background)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ui.getRed(&r, green: &g, blue: &b, alpha: &a)
        return SIMD4(Float(r), Float(g), Float(b), 1)
    }

    /// Region covering the character across the animation (rest pose bounds + margin).
    func contentRegion(_ bundle: ProjectBundle) -> Rect? {
        guard cropToContent else { return nil }
        var r = Rect.zero
        for m in bundle.project.rig.meshes where m.visible { r = r.union(Rect.bounding(m.mesh.vertices)) }
        guard !r.isEmpty else { return nil }
        let side = max(r.width, r.height) * 1.12
        return Rect(x: r.center.x - side / 2, y: r.center.y - side / 2, width: side, height: side)
    }

    func start() {
        let bundle = session.bundle
        let name = session.rig.name.replacingOccurrences(of: "/", with: "-")
        let clip = clipID.flatMap { bundle.project.clip($0) }
        let region = contentRegion(bundle)
        let aspect = region.map { $0.height / $0.width } ?? Float(bundle.project.rig.canvasHeight) / Float(bundle.project.rig.canvasWidth)
        let settings = FrameExportSettings(width: size, height: max(1, Int(Float(size) * aspect)), region: region, frameRate: fps,
                                           duration: clip.map { $0.duration * Double(loops) }, background: backgroundColor(),
                                           supersample: supersample ? 2 : 1, physicsEnabled: session.physicsEnabled)
        let format = format, runtimeScale = runtimeScale
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Export-\(UUID().uuidString)")
        progress = 0; errorText = nil
        Task.detached(priority: .userInitiated) {
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let report: (Double) -> Void = { p in Task { @MainActor in progress = p } }
                let clipName = clip?.name ?? "Pose"
                var url: URL
                switch format {
                case .gif:
                    url = dir.appendingPathComponent("\(name) - \(clipName).gif")
                    try GIFExporter.export(FrameRenderer(bundle: bundle, clipID: clip?.id, settings: settings), progress: report).write(to: url)
                case .png:
                    url = dir.appendingPathComponent("\(name) - \(clipName)")
                    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                    let files = PNGSequenceExporter.export(FrameRenderer(bundle: bundle, clipID: clip?.id, settings: settings),
                                                           baseName: clipName.replacingOccurrences(of: " ", with: "_"), progress: report)
                    for (n, d) in files { try d.write(to: url.appendingPathComponent(n)) }
                case .hevcAlpha, .prores, .mp4:
                    let codec: VideoExporter.Codec = format == .hevcAlpha ? .hevcWithAlpha : format == .prores ? .proRes4444 : .h264
                    url = dir.appendingPathComponent("\(name) - \(clipName).\(codec.fileExtension)")
                    var s = settings
                    // Video encoders want even dimensions.
                    s.width -= s.width % 2; s.height -= s.height % 2
                    try await VideoExporter.export(FrameRenderer(bundle: bundle, clipID: clip?.id, settings: s), codec: codec, to: url, progress: report)
                case .runtime:
                    url = dir.appendingPathComponent("\(name).m2rt")
                    var o = RuntimeFormat.Options(); o.textureScale = runtimeScale
                    try RuntimeFormat.write(bundle, options: o).write(to: url)
                case .still:
                    url = dir.appendingPathComponent("\(name).png")
                    var s = settings; s.duration = 1 / s.frameRate; s.physicsWarmup = 0
                    let frame = FrameRenderer(bundle: bundle, clipID: nil, settings: s).renderNext()!
                    try PNG.encode(frame).write(to: url)
                }
                await MainActor.run { progress = nil; resultURL = url; showMover = true }
            } catch {
                await MainActor.run { progress = nil; errorText = "\(error)" }
            }
        }
    }
}
