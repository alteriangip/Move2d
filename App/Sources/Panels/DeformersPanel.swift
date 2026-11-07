import SwiftUI
import M2DCore
import M2DRig
import M2DEditor

/// Deformation tree: deformers with their child deformers and meshes.
struct DeformersPanel: View {
    let session: EditorSession

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(title: "Deformers") {
                HStack(spacing: 12) {
                    Button { session.createWarpDeformer() } label: { Image(systemName: "squareshape.split.3x3") }
                        .help("New warp deformer around selection")
                    Button { session.createRotationDeformer() } label: { Image(systemName: "rotate.right") }
                        .help("New rotation deformer for selection")
                }
                .disabled(session.selectionForKeyforms.isEmpty)
            }
            if session.selectionForKeyforms.isEmpty {
                Text("Select layers, then add a warp or rotation deformer to group and deform them together.")
                    .font(.caption).foregroundStyle(.secondary).padding(10)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(rows, id: \.id) { row in DeformerRow(session: session, id: row.id, depth: row.depth) }
                }
            }
        }
    }

    struct Row { var id: ObjectID; var depth: Int }

    var rows: [Row] {
        var out: [Row] = []
        func walk(_ parent: ObjectID?, _ depth: Int) {
            for id in session.deformerChildren(of: parent) {
                out.append(Row(id: id, depth: depth))
                if session.rig.deformer(id) != nil && depth < 32 { walk(id, depth + 1) }
            }
        }
        walk(nil, 0)
        return out
    }
}

struct DeformerRow: View {
    let session: EditorSession
    let id: ObjectID
    let depth: Int

    var body: some View {
        let kind = session.kind(of: id)
        HStack(spacing: 6) {
            Color.clear.frame(width: CGFloat(depth) * 14)
            Image(systemName: kind == .warp ? "squareshape.split.3x3" : kind == .rotation ? "rotate.right" : "photo")
                .font(.caption)
                .foregroundStyle(kind == .warp ? Theme.warpColor : kind == .rotation ? Theme.rotationColor : .secondary)
            Text(session.name(of: id)).font(.callout).lineLimit(1)
            Spacer()
            if !session.bindings(of: id).isEmpty {
                Text(session.bindings(of: id).compactMap { session.rig.parameter($0.parameterID)?.name }.joined(separator: ", "))
                    .font(.caption2).foregroundStyle(Theme.keyColor).lineLimit(1)
            }
        }
        .padding(.horizontal, 10).frame(height: 32)
        .background(session.selection.contains(id) ? Theme.accent.opacity(0.28) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture { session.select(id) }
        .draggable(id)
        .dropDestination(for: String.self) { items, _ in
            guard session.rig.deformer(id) != nil else { return false }
            for item in items where item != id { session.setDeformerParent(item, to: id) }
            return true
        }
        .contextMenu {
            Menu("Parent") {
                Button("Canvas (none)") { session.setDeformerParent(id, to: nil) }
                ForEach(session.rig.deformers.filter { $0.id != id }, id: \.id) { d in
                    Button(d.name) { session.setDeformerParent(id, to: d.id) }
                }
            }
            if session.rig.deformer(id) != nil {
                Button("Delete Deformer", role: .destructive) { session.deleteDeformer(id) }
            }
        }
    }
}
