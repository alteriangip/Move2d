import SwiftUI
import M2DCore
import M2DRig
import M2DEditor

/// Properties of the current selection.
struct InspectorPanel: View {
    let session: EditorSession
    let tools: CanvasToolController?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if let id = session.selection.primary {
                    switch session.kind(of: id) {
                    case .mesh: MeshInspector(session: session, id: id, tools: tools)
                    case .part: PartInspector(session: session, id: id)
                    case .warp: WarpInspector(session: session, id: id)
                    case .rotation: RotationInspector(session: session, id: id)
                    case nil: EmptyView()
                    }
                    BindingsSection(session: session, id: id)
                } else {
                    DocumentInspector(session: session)
                }
            }
            .padding(.bottom, 24)
        }
    }
}

struct InspectorSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PanelHeader(title)
            VStack(alignment: .leading, spacing: 10) { content() }.padding(12)
        }
    }
}

struct NameField: View {
    let session: EditorSession
    let id: ObjectID
    @State private var text = ""
    var body: some View {
        TextField("Name", text: $text)
            .textFieldStyle(.roundedBorder)
            .onAppear { text = session.name(of: id) }
            .onChange(of: id) { _, n in text = session.name(of: n) }
            .onSubmit { session.rename(id, to: text) }
    }
}

/// Keyform-aware float control: edits are grouped into one undo step per drag.
struct FormSlider: View {
    let session: EditorSession
    let title: String
    let value: Float
    let range: ClosedRange<Float>
    var format = "%.2f"
    let set: (Float) -> Void
    var body: some View {
        LabeledSlider(title: title, value: Binding(get: { value }, set: set), range: range, format: format) { editing in
            if editing { session.beginGesture(title) } else { session.endGesture() }
        }
    }
}

struct MeshInspector: View {
    let session: EditorSession
    let id: ObjectID
    let tools: CanvasToolController?
    @State private var columns = 4
    @State private var rows = 4

    var body: some View {
        if let m = session.rig.mesh(id) {
            InspectorSection(title: "Art Mesh") {
                NameField(session: session, id: id)
                Picker("Blend", selection: Binding(get: { m.blendMode }, set: { session.setBlendMode(id, $0) })) {
                    ForEach(BlendMode.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                }
                Text("\(m.mesh.vertexCount) vertices · \(m.mesh.triangleCount) triangles · texture \(Int(m.textureRect.width))×\(Int(m.textureRect.height))")
                    .font(.caption).foregroundStyle(.secondary)
                Menu {
                    Button("None") { session.setMasks(id, [], invert: false) }
                    ForEach(session.rig.meshes.filter { $0.id != id }, id: \.id) { other in
                        Button(other.name) { session.setMasks(id, [other.id], invert: m.invertMask) }
                    }
                } label: {
                    Label(m.maskIDs.isEmpty ? "Clipping mask: none" : "Clipped by \(m.maskIDs.map(session.name(of:)).joined(separator: ", "))", systemImage: "scissors")
                        .font(.callout)
                }
                if !m.maskIDs.isEmpty {
                    Toggle("Invert mask", isOn: Binding(get: { m.invertMask }, set: { session.setMasks(id, m.maskIDs, invert: $0) }))
                }
            }
            InspectorSection(title: "Mesh") {
                LabeledSlider(title: "Auto-mesh vertex spacing", value: Binding(get: { session.meshSpacing }, set: { session.meshSpacing = $0 }), range: 8...200, format: "%.0f px")
                HStack {
                    Button("Auto Mesh") { session.autoMesh([id]) }.buttonStyle(.borderedProminent)
                    Button("Quad") { session.resetToQuad(id) }.buttonStyle(.bordered)
                }
                HStack {
                    Stepper("Grid \(columns)×\(rows)", value: $columns, in: 1...40).font(.callout)
                    Stepper("", value: $rows, in: 1...40).labelsHidden()
                }
                Button("Apply Grid Mesh") { session.gridMesh(id, columns: columns, rows: rows) }.buttonStyle(.bordered)
                HStack {
                    Button("Subdivide") { session.subdivide(id) }
                    Button("Retriangulate") { session.retriangulate(id) }
                }.buttonStyle(.bordered)
                let selCount = session.selection.vertices[id]?.count ?? 0
                HStack {
                    Button("Select All") { session.selectAllVertices(of: id) }
                    Button("Delete \(selCount) Vertices", role: .destructive) { session.removeSelectedVertices() }.disabled(selCount == 0)
                }.buttonStyle(.bordered)
                Text("Edit Mesh tool: tap to add vertices, drag to move them over the artwork. Triangles tool: tap three vertices to add a triangle, tap inside a triangle to delete it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            InspectorSection(title: "Current Keyform") {
                if let fi = session.editableFormIndex(id) {
                    let f = m.keyforms.forms[fi]
                    FormSlider(session: session, title: "Opacity", value: f.opacity, range: 0...1) { session.setMeshFormOpacity(id, $0) }
                    FormSlider(session: session, title: "Draw order", value: f.drawOrder, range: 0...1000, format: "%.0f") { session.setMeshFormDrawOrder(id, $0) }
                    if let tools {
                        LabeledSlider(title: "Deform soft-selection radius", value: Binding(get: { tools.falloffRadius }, set: { tools.falloffRadius = $0 }), range: 0...400, format: "%.0f px")
                    }
                    Button("Reset Shape") { session.resetKeyformShape(id) }.buttonStyle(.bordered)
                } else {
                    Text(session.keyformBlocker(id) ?? "").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct PartInspector: View {
    let session: EditorSession
    let id: ObjectID
    var body: some View {
        if let p = session.rig.part(id) {
            InspectorSection(title: "Part") {
                NameField(session: session, id: id)
                FormSlider(session: session, title: "Opacity", value: p.opacity, range: 0...1) { session.setPartOpacity(id, $0) }
                Text("\(session.rig.meshes(inPart: id).count) art meshes").font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Auto Mesh All") { session.autoMesh(session.rig.meshes(inPart: id)) }
                    Button("Ungroup") { session.ungroup(id) }
                }.buttonStyle(.bordered)
            }
        }
    }
}

struct WarpInspector: View {
    let session: EditorSession
    let id: ObjectID
    var body: some View {
        if let d = session.rig.deformer(id), let w = d.warp {
            InspectorSection(title: "Warp Deformer") {
                NameField(session: session, id: id)
                Stepper("Columns: \(w.columns)", value: Binding(get: { w.columns }, set: { session.setWarpResolution(id, columns: $0, rows: w.rows) }), in: 1...32)
                Stepper("Rows: \(w.rows)", value: Binding(get: { w.rows }, set: { session.setWarpResolution(id, columns: w.columns, rows: $0) }), in: 1...32)
                parentLabel(session, d)
            }
            InspectorSection(title: "Current Keyform") {
                if let fi = session.editableFormIndex(id) {
                    FormSlider(session: session, title: "Opacity", value: w.keyforms.forms[fi].opacity, range: 0...1) { session.setDeformerOpacity(id, $0) }
                    Text("Deform tool: drag lattice points (lasso to select several). Select tool: drag inside to move the whole lattice.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Reset Shape") { session.resetKeyformShape(id) }.buttonStyle(.bordered)
                } else {
                    Text(session.keyformBlocker(id) ?? "").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct RotationInspector: View {
    let session: EditorSession
    let id: ObjectID
    var body: some View {
        if let d = session.rig.deformer(id), let r = d.rotation {
            InspectorSection(title: "Rotation Deformer") {
                NameField(session: session, id: id)
                parentLabel(session, d)
                Text("Drag the pivot ring in Rig mode to move the pivot; drag the handle tip to rotate.").font(.caption).foregroundStyle(.secondary)
            }
            InspectorSection(title: "Current Keyform") {
                if let fi = session.editableFormIndex(id) {
                    let f = r.keyforms.forms[fi]
                    FormSlider(session: session, title: "Angle", value: f.angle, range: -180...180, format: "%.1f°") { session.setRotationForm(id, angle: $0) }
                    FormSlider(session: session, title: "Scale", value: f.scale, range: 0.1...3) { session.setRotationForm(id, scale: $0) }
                    FormSlider(session: session, title: "Opacity", value: f.opacity, range: 0...1) { session.setRotationForm(id, opacity: $0) }
                    Button("Reset") { session.resetKeyformShape(id) }.buttonStyle(.bordered)
                } else {
                    Text(session.keyformBlocker(id) ?? "").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

@ViewBuilder func parentLabel(_ session: EditorSession, _ d: Deformer) -> some View {
    Menu {
        Button("Canvas (none)") { session.setDeformerParent(d.id, to: nil) }
        ForEach(session.rig.deformers.filter { $0.id != d.id }, id: \.id) { o in Button(o.name) { session.setDeformerParent(d.id, to: o.id) } }
    } label: {
        Label("Parent: \(d.parentID.map(session.name(of:)) ?? "Canvas")", systemImage: "arrow.turn.left.up").font(.callout)
    }
}

/// Parameters this object reacts to, with their keys.
struct BindingsSection: View {
    let session: EditorSession
    let id: ObjectID
    var body: some View {
        let bindings = session.bindings(of: id)
        if session.kind(of: id) != .part {
            InspectorSection(title: "Parameter Bindings") {
                if bindings.isEmpty {
                    Text("Not bound. Use ◇+ next to a parameter to add a key for this object.").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(bindings, id: \.parameterID) { b in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(session.rig.parameter(b.parameterID)?.name ?? b.parameterID).font(.callout)
                            Text(b.keys.map { String(format: "%g", $0) }.joined(separator: "  ·  ")).font(.caption.monospacedDigit()).foregroundStyle(Theme.keyColor)
                        }
                        Spacer()
                        Button(role: .destructive) { session.unbind([id], from: b.parameterID) } label: { Image(systemName: "xmark.circle") }.buttonStyle(.plain)
                    }
                }
            }
        }
    }
}

struct DocumentInspector: View {
    let session: EditorSession
    @State private var w = 0
    @State private var h = 0
    var body: some View {
        InspectorSection(title: "Document") {
            Text(session.rig.name).font(.headline)
            Text("\(session.rig.meshes.count) art meshes · \(session.rig.deformers.count) deformers · \(session.rig.parameters.count) parameters · \(session.project.animations.count) animations")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                TextField("W", value: $w, format: .number).textFieldStyle(.roundedBorder).frame(width: 80)
                Text("×")
                TextField("H", value: $h, format: .number).textFieldStyle(.roundedBorder).frame(width: 80)
                Button("Set Canvas") { session.setCanvasSize(width: w, height: h) }.buttonStyle(.bordered)
            }
            .onAppear { w = session.rig.canvasWidth; h = session.rig.canvasHeight }
            Text("Select a layer or deformer to see its properties. Tips: two fingers pan and pinch, double-tap the Pencil to switch tools, ⌘Z undoes.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
