import SwiftUI
import UniformTypeIdentifiers
import M2DCore
import M2DPSD
import M2DProject
import M2DRig
import M2DEditor

/// Open project: its session, file location and autosave state.
@Observable
final class OpenProject: Identifiable {
    let id = UUID()
    let session: EditorSession
    var url: URL
    var name: String { url.deletingPathExtension().lastPathComponent }
    var savedRevision: Int
    init(session: EditorSession, url: URL) { self.session = session; self.url = url; savedRevision = session.rigRevision }
}

/// Project gallery shown at launch.
struct HomeView: View {
    let library: ProjectLibrary
    @Environment(\.scenePhase) private var scenePhase
    @State private var open: OpenProject?
    @State private var importingPSD = false
    @State private var importingProject = false
    @State private var pendingPSD: (data: [UInt8], name: String)?
    @State private var importOptions = PSDImportOptionsModel()
    @State private var busy: String?
    @State private var errorMessage: String?
    @State private var warnings: [String] = []
    @State private var renaming: ProjectEntry?
    @State private var renameText = ""

    let columns = [GridItem(.adaptive(minimum: 200, maximum: 260), spacing: 24)]

    var body: some View {
        ZStack {
            if let open {
                EditorRootView(session: open.session, projectName: open.name, onClose: closeProject)
                    .onChange(of: open.session.rigRevision) { _, _ in scheduleAutosave(open) }
                    .transition(.opacity)
            } else {
                gallery.transition(.opacity)
            }
            if let busy {
                Color.black.opacity(0.4).ignoresSafeArea()
                ProgressView(busy).padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: open?.id)
        .onChange(of: scenePhase) { _, phase in if phase != .active, let open { saveNow(open) } }
        .fileImporter(isPresented: $importingPSD, allowedContentTypes: [.photoshopDocument, .data]) { pickPSD($0) }
        .fileImporter(isPresented: $importingProject, allowedContentTypes: [.move2dProject, .folder]) { pickProject($0) }
        .sheet(isPresented: Binding(get: { pendingPSD != nil }, set: { if !$0 { pendingPSD = nil } })) {
            PSDImportSheet(options: $importOptions, fileName: pendingPSD?.name ?? "") { ok in
                if ok { runPSDImport() } else { pendingPSD = nil }
            }
        }
        .alert("Something went wrong", isPresented: Binding(get: { errorMessage != nil || library.lastError != nil },
                                                             set: { if !$0 { errorMessage = nil; library.lastError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(errorMessage ?? library.lastError ?? "") }
        .alert("Imported with notes", isPresented: Binding(get: { !warnings.isEmpty }, set: { if !$0 { warnings = [] } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(warnings.prefix(8).joined(separator: "\n")) }
        .alert("Rename Project", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $renameText)
            Button("Rename") { if let r = renaming { library.rename(r, to: renameText) }; renaming = nil }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
    }

    // MARK: Gallery

    var gallery: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header
                actions
                if library.projects.isEmpty {
                    Text("No projects yet. Import a layered PSD to start rigging, or open the sample character to explore a finished rig.")
                        .foregroundStyle(.secondary).padding(.top, 8)
                } else {
                    Text("Projects").font(.title3.weight(.semibold))
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 28) {
                        ForEach(library.projects) { p in ProjectCard(entry: p).onTapGesture { openProject(p.url) }
                            .contextMenu {
                                Button { renameText = p.name; renaming = p } label: { Label("Rename", systemImage: "pencil") }
                                Button { library.duplicate(p) } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
                                Button(role: .destructive) { library.delete(p) } label: { Label("Delete", systemImage: "trash") }
                            }
                        }
                    }
                }
            }
            .padding(40)
            .frame(maxWidth: 1200, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.canvasBackground.ignoresSafeArea())
        .refreshable { library.refresh() }
    }

    var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "figure.wave").font(.system(size: 38)).foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text("Move2D").font(.largeTitle.weight(.bold))
                Text("2D character rigging & animation").foregroundStyle(.secondary)
            }
        }
    }

    var actions: some View {
        HStack(spacing: 16) {
            ActionTile(title: "Import PSD", subtitle: "Layers become meshes", icon: "square.and.arrow.down", prominent: true) { importingPSD = true }
            ActionTile(title: "New Project", subtitle: "Empty canvas", icon: "plus") { newBlank() }
            ActionTile(title: "Sample Character", subtitle: "Fully rigged example", icon: "person.crop.square") { newSample() }
            ActionTile(title: "Open .move2d", subtitle: "From Files", icon: "folder") { importingProject = true }
        }
    }

    // MARK: Actions

    func openProject(_ url: URL) {
        busy = "Opening…"
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try library.load(url) }
            DispatchQueue.main.async {
                busy = nil
                switch result {
                case let .success(bundle): open = OpenProject(session: EditorSession(bundle: bundle), url: url)
                case let .failure(e): errorMessage = "\(e)"
                }
            }
        }
    }

    func createAndOpen(_ bundle: ProjectBundle, name: String) {
        do {
            let url = try library.create(bundle, name: name)
            let s = EditorSession(bundle: bundle)
            open = OpenProject(session: s, url: url)
        } catch { errorMessage = "\(error)" }
    }

    func newBlank() {
        var rig = M2DRig.RigModel(name: "Untitled", canvasWidth: 2048, canvasHeight: 2048)
        rig.parameters = M2DRig.Parameter.standardSet()
        createAndOpen(ProjectBundle(project: Project(rig: rig)), name: "Untitled")
    }

    func newSample() {
        busy = "Building sample…"
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try SampleRig.makeSession().bundle }
            DispatchQueue.main.async {
                busy = nil
                switch result {
                case let .success(b): createAndOpen(b, name: "Sample Character")
                case let .failure(e): errorMessage = "\(e)"
                }
            }
        }
    }

    func pickPSD(_ result: Result<URL, Error>) {
        switch result {
        case let .failure(e): errorMessage = e.localizedDescription
        case let .success(url):
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            do { pendingPSD = ([UInt8](try Data(contentsOf: url)), url.lastPathComponent) } catch { errorMessage = "\(error)" }
        }
    }

    func runPSDImport() {
        guard let p = pendingPSD else { return }
        pendingPSD = nil
        busy = "Importing \(p.name)…"
        let options = importOptions.options
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try PSDImporter.importPSD(p.data, fileName: p.name, options: options) }
            DispatchQueue.main.async {
                busy = nil
                switch result {
                case let .success(r):
                    createAndOpen(r.bundle, name: (p.name as NSString).deletingPathExtension)
                    warnings = r.warnings
                case let .failure(e): errorMessage = "\(e)"
                }
            }
        }
    }

    func pickProject(_ result: Result<URL, Error>) {
        switch result {
        case let .failure(e): errorMessage = e.localizedDescription
        case let .success(url):
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            do { openProject(try library.importPackage(at: url)) } catch { errorMessage = "\(error)" }
        }
    }

    // MARK: Saving

    @State private var autosaveTask: Task<Void, Never>?

    func scheduleAutosave(_ p: OpenProject) {
        autosaveTask?.cancel()
        autosaveTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if !Task.isCancelled { saveNow(p) }
        }
    }

    func saveNow(_ p: OpenProject) {
        guard p.session.rigRevision != p.savedRevision else { return }
        p.savedRevision = p.session.rigRevision
        library.save(p.session.bundle, to: p.url)
        p.session.markSaved()
    }

    func closeProject() {
        if let open { autosaveTask?.cancel(); saveNow(open) }
        open = nil
        library.refresh()
    }
}

struct ActionTile: View {
    let title: String
    let subtitle: String
    let icon: String
    var prominent = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: icon).font(.title2)
                Spacer(minLength: 0)
                Text(title).font(.headline)
                Text(subtitle).font(.caption).foregroundStyle(prominent ? Color.white.opacity(0.8) : Color.secondary)
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 120, alignment: .leading)
            .background(prominent ? Theme.accent : Color(white: 0.17), in: RoundedRectangle(cornerRadius: 16))
            .foregroundStyle(prominent ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
    }
}

struct ProjectCard: View {
    let entry: ProjectEntry
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                Checkerboard(size: 10)
                if let img = UIImage(contentsOfFile: entry.thumbnailURL.path) {
                    Image(uiImage: img).resizable().scaledToFit().padding(8)
                } else {
                    Image(systemName: "photo").font(.largeTitle).foregroundStyle(.secondary)
                }
            }
            .aspectRatio(1, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.08)))
            Text(entry.name).font(.headline).lineLimit(1)
            Text(entry.modified, style: .relative).font(.caption).foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
    }
}
