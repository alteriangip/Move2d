import SwiftUI
import UniformTypeIdentifiers
import M2DCore
import M2DPSD
import M2DRig
import M2DProject
import M2DEditor

enum LeftTab: String, CaseIterable { case layers = "Layers", deformers = "Deformers" }
enum RightTab: String, CaseIterable { case inspector = "Inspector", parameters = "Parameters", physics = "Physics" }

struct EditorRootView: View {
    let session: EditorSession
    let projectName: String
    let onClose: () -> Void
    @Environment(\.horizontalSizeClass) private var hSize

    @State private var viewport = CanvasViewport()
    @State private var tools: CanvasToolController?
    @State private var leftTab: LeftTab = .layers
    @State private var rightTab: RightTab = .parameters
    @State private var showLeft = true
    @State private var showRight = true
    @State private var showTimeline = true
    @State private var pencilOnly = false
    @State private var previousTool: EditorTool = .select
    @State private var importingPSD = false
    @State private var replacingArtwork = false
    @State private var showExport = false
    @State private var importOptions = PSDImportOptionsModel()
    @State private var pendingPSD: (data: [UInt8], name: String)?
    @State private var errorMessage: String?
    @State private var importWarnings: [String] = []


    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider().overlay(Theme.separator)
            HStack(spacing: 0) {
                if showLeft { leftSidebar.frame(width: Theme.sidebarWidth).transition(.move(edge: .leading)) }
                VStack(spacing: 0) {
                    ZStack(alignment: .bottom) {
                        if let tools {
                            CanvasView(session: session, viewport: viewport, tools: tools, pencilOnly: pencilOnly,
                                       onPencilDoubleTap: togglePencilTool)
                        }
                        if session.rig.meshes.isEmpty { WelcomeView(importPSD: { importingPSD = true }, openSample: openSample) }
                        noticeBanner
                    }
                    if showTimeline && session.mode == .animate {
                        Divider().overlay(Theme.separator)
                        TimelineView(session: session).frame(height: 230)
                    }
                }
                if showRight { rightSidebar.frame(width: Theme.sidebarWidth).transition(.move(edge: .trailing)) }
            }
        }
        .background(Theme.canvasBackground)
        .onAppear(perform: setUp)
        .onChange(of: hSize) { _, s in if s == .compact { showLeft = false; showRight = false } }
        .fileImporter(isPresented: $importingPSD, allowedContentTypes: [.photoshopDocument, .data]) { handlePSDPick($0, replace: false) }
        .fileImporter(isPresented: $replacingArtwork, allowedContentTypes: [.photoshopDocument, .data]) { handlePSDPick($0, replace: true) }
        .sheet(isPresented: Binding(get: { pendingPSD != nil }, set: { if !$0 { pendingPSD = nil } })) {
            PSDImportSheet(options: $importOptions, fileName: pendingPSD?.name ?? "") { confirmed in
                if confirmed { runImport() } else { pendingPSD = nil }
            }
        }
        .sheet(isPresented: $showExport) { ExportSheet(session: session) }
        .alert("Couldn't complete the action", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(errorMessage ?? "") }
        .alert("Imported with notes", isPresented: Binding(get: { !importWarnings.isEmpty }, set: { if !$0 { importWarnings = [] } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(importWarnings.prefix(8).joined(separator: "\n")) }
    }

    // MARK: Setup

    func setUp() {
        if tools == nil { tools = CanvasToolController(session: session, viewport: viewport) }
        if hSize == .compact { showLeft = false; showRight = false }
    }

    // MARK: Toolbar

    var toolbar: some View {
        HStack(spacing: 6) {
            Button(action: onClose) {
                Label("Projects", systemImage: "square.grid.2x2").labelStyle(.iconOnly).frame(width: 34, height: 34)
            }
            .help("Back to projects")
            Text(projectName).font(.headline).lineLimit(1).frame(maxWidth: 160, alignment: .leading)
            IconButton(systemName: "sidebar.left", help: "Layers", active: showLeft) { withAnimation(.snappy) { showLeft.toggle() } }
            Menu {
                Button { importingPSD = true } label: { Label("Import PSD…", systemImage: "square.and.arrow.down") }
                Button { replacingArtwork = true } label: { Label("Update Artwork from PSD…", systemImage: "arrow.triangle.2.circlepath") }
                    .disabled(session.rig.meshes.isEmpty)
                Button(action: openSample) { Label("Load Sample Character", systemImage: "person.crop.square") }
                Divider()
                Button { showExport = true } label: { Label("Export…", systemImage: "square.and.arrow.up") }
            } label: { Image(systemName: "doc.badge.plus").frame(width: 34, height: 34) }

            Divider().frame(height: 24)
            Picker("Mode", selection: Binding(get: { session.mode }, set: { session.mode = $0 })) {
                Text("Rig").tag(EditorMode.rig)
                Text("Animate").tag(EditorMode.animate)
            }
            .pickerStyle(.segmented).frame(width: 160)

            Divider().frame(height: 24)
            ForEach(toolList, id: \.0) { tool, icon in
                IconButton(systemName: icon, help: tool.title, active: session.tool == tool) { session.tool = tool }
            }
            Divider().frame(height: 24)
            IconButton(systemName: "arrow.uturn.backward", help: "Undo") { session.undo() }
                .disabled(!session.canUndo)
                .keyboardShortcut("z", modifiers: .command)
            IconButton(systemName: "arrow.uturn.forward", help: "Redo") { session.redo() }
                .disabled(!session.canRedo)
                .keyboardShortcut("z", modifiers: [.command, .shift])

            Spacer()

            if session.mode == .animate {
                IconButton(systemName: session.isPlaying ? "pause.fill" : "play.fill", help: "Play / Pause") { session.togglePlayback() }
                    .keyboardShortcut(.space, modifiers: [])
            }
            Menu {
                Toggle("Mesh Wireframe", isOn: Binding(get: { session.showMeshWireframe }, set: { session.showMeshWireframe = $0 }))
                Toggle("Deformer Handles", isOn: Binding(get: { session.showDeformers }, set: { session.showDeformers = $0 }))
                Toggle("Show All Wireframes", isOn: Binding(get: { session.onionSkin }, set: { session.onionSkin = $0 }))
                Toggle("Physics Preview", isOn: Binding(get: { session.physicsEnabled }, set: { session.physicsEnabled = $0; session.resetPhysics() }))
                Toggle("Pencil Only Editing", isOn: $pencilOnly)
                Toggle("Timeline", isOn: $showTimeline)
                Divider()
                Button("Fit Canvas") { viewport.hasFitted = false }
                Button("Reset Parameters") { session.resetParameters() }
            } label: { Image(systemName: "eye").frame(width: 34, height: 34) }
            IconButton(systemName: "square.and.arrow.up", help: "Export") { showExport = true }
            IconButton(systemName: "sidebar.right", help: "Inspector", active: showRight) { withAnimation(.snappy) { showRight.toggle() } }
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(Theme.panel)
    }

    var toolList: [(EditorTool, String)] {
        [(.select, "cursorarrow"), (.deform, "hand.point.up.left"), (.meshEdit, "point.3.connected.trianglepath.dotted"),
         (.triangle, "triangle"), (.lasso, "lasso"), (.rotate, "arrow.triangle.2.circlepath"), (.hand, "hand.raised")]
    }

    func togglePencilTool() {
        let t = session.tool
        session.tool = previousTool == t ? (t == .select ? .deform : .select) : previousTool
        previousTool = t
    }

    // MARK: Sidebars

    var leftSidebar: some View {
        VStack(spacing: 0) {
            Picker("", selection: $leftTab) { ForEach(LeftTab.allCases, id: \.self) { Text($0.rawValue) } }
                .pickerStyle(.segmented).padding(8)
            switch leftTab {
            case .layers: LayersPanel(session: session)
            case .deformers: DeformersPanel(session: session)
            }
        }
        .background(Theme.panel)
    }

    var rightSidebar: some View {
        VStack(spacing: 0) {
            Picker("", selection: $rightTab) { ForEach(RightTab.allCases, id: \.self) { Text($0.rawValue) } }
                .pickerStyle(.segmented).padding(8)
            switch rightTab {
            case .inspector: InspectorPanel(session: session, tools: tools)
            case .parameters: ParametersPanel(session: session)
            case .physics: PhysicsPanel(session: session)
            }
        }
        .background(Theme.panel)
    }

    @ViewBuilder var noticeBanner: some View {
        if let n = session.notice {
            Text(n)
                .font(.callout)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(.ultraThinMaterial, in: Capsule())
                .padding(.bottom, 14)
                .onTapGesture { session.notice = nil }
                .task(id: n) {
                    try? await Task.sleep(nanoseconds: 3_500_000_000)
                    if session.notice == n { session.notice = nil }
                }
        }
    }

    // MARK: Import

    func handlePSDPick(_ result: Result<URL, Error>, replace: Bool) {
        switch result {
        case let .failure(e): errorMessage = e.localizedDescription
        case let .success(url):
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            do {
                let data = [UInt8](try Data(contentsOf: url))
                if replace {
                    let doc = try PSDParser.parse(data)
                    var b = session.bundle
                    let updated = PSDImporter.updateArtwork(&b, from: doc)
                    session.replaceContentKeepingState(with: b, actionName: "Update Artwork")
                    session.notice = "Updated artwork for \(updated.count) layer\(updated.count == 1 ? "" : "s")."
                } else {
                    pendingPSD = (data, url.lastPathComponent)
                }
            } catch { errorMessage = "\(error)" }
        }
    }

    func runImport() {
        guard let p = pendingPSD else { return }
        pendingPSD = nil
        let options = importOptions.options
        Task.detached(priority: .userInitiated) {
            do {
                let r = try PSDImporter.importPSD(p.data, fileName: p.name, options: options)
                await MainActor.run {
                    session.replaceContent(with: r.bundle, actionName: "Import PSD")
                    viewport.hasFitted = false
                    importWarnings = r.warnings
                }
            } catch {
                await MainActor.run { errorMessage = "\(error)" }
            }
        }
    }

    func openSample() {
        do {
            let s = try SampleRig.makeSession()
            session.replaceContent(with: s.bundle, actionName: "Load Sample")
            viewport.hasFitted = false
        } catch { errorMessage = "\(error)" }
    }
}

/// Options shown before importing a PSD.
struct PSDImportOptionsModel {
    var autoMesh = true
    var spacing: Float = 48
    var standardParameters = true
    var includeHidden = true
    var options: PSDImporter.Options {
        var o = PSDImporter.Options()
        o.meshMode = autoMesh ? .automatic(spacing: spacing) : .quad
        o.addStandardParameters = standardParameters
        o.includeHiddenLayers = includeHidden
        return o
    }
}

struct PSDImportSheet: View {
    @Binding var options: PSDImportOptionsModel
    let fileName: String
    let done: (Bool) -> Void
    var body: some View {
        NavigationStack {
            Form {
                Section("Meshes") {
                    Toggle("Generate meshes from layer outlines", isOn: $options.autoMesh)
                    if options.autoMesh {
                        LabeledSlider(title: "Vertex spacing (px)", value: $options.spacing, range: 12...160, format: "%.0f")
                    }
                }
                Section("Rig") {
                    Toggle("Add standard character parameters", isOn: $options.standardParameters)
                    Toggle("Import hidden layers", isOn: $options.includeHidden)
                }
                Section { Text("Groups become parts, layers become art meshes and clipping layers become masks. You can refine meshes later.").font(.footnote).foregroundStyle(.secondary) }
            }
            .navigationTitle("Import \(fileName)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { done(false) } }
                ToolbarItem(placement: .confirmationAction) { Button("Import") { done(true) } }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

struct WelcomeView: View {
    let importPSD: () -> Void
    let openSample: () -> Void
    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "figure.wave").font(.system(size: 54)).foregroundStyle(Theme.accent)
            Text("Bring your character to life").font(.title2.weight(.semibold))
            Text("Import a layered PSD. Each layer becomes a deformable mesh you can rig with warp and rotation deformers, drive with parameters and animate.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 440)
            HStack(spacing: 12) {
                Button(action: importPSD) { Label("Import PSD", systemImage: "square.and.arrow.down") }.buttonStyle(.borderedProminent)
                Button(action: openSample) { Label("Open Sample Character", systemImage: "person.crop.square") }.buttonStyle(.bordered)
            }
        }
        .padding(32)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
    }
}
