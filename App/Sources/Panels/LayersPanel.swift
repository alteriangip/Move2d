import SwiftUI
import UniformTypeIdentifiers
import M2DCore
import M2DRig
import M2DEditor

/// Layer hierarchy (parts and art meshes) in Photoshop order, front-most first.
struct LayersPanel: View {
    let session: EditorSession
    @State private var renaming: ObjectID?
    @State private var renameText = ""

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(title: "Layers") {
                HStack(spacing: 10) {
                    Button { session.groupSelection() } label: { Image(systemName: "folder.badge.plus") }
                        .disabled(session.selection.isEmpty).help("Group selection")
                    Button(role: .destructive) { session.deleteSelection() } label: { Image(systemName: "trash") }
                        .disabled(session.selection.isEmpty).help("Delete selection")
                }
            }
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(flatRows, id: \.id) { row in
                        LayerRow(session: session, id: row.id, depth: row.depth, renaming: $renaming, renameText: $renameText)
                    }
                    // Drop target for moving to the bottom of the root.
                    Color.clear.frame(height: 60)
                        .dropDestination(for: String.self) { items, _ in
                            for id in items { session.moveNode(id, toParent: nil, at: session.rig.rootChildren.count) }
                            return true
                        }
                }
            }
        }
    }

    struct FlatRow { var id: ObjectID; var depth: Int }

    var flatRows: [FlatRow] {
        var out: [FlatRow] = []
        func walk(_ ids: [ObjectID], _ depth: Int) {
            for id in ids {
                out.append(FlatRow(id: id, depth: depth))
                if let p = session.rig.part(id), p.expanded { walk(p.children, depth + 1) }
            }
        }
        walk(session.rig.rootChildren, 0)
        return out
    }
}

struct LayerRow: View {
    let session: EditorSession
    let id: ObjectID
    let depth: Int
    @Binding var renaming: ObjectID?
    @Binding var renameText: String

    var isPart: Bool { session.rig.isPart(id) }
    var selected: Bool { session.selection.contains(id) }

    var body: some View {
        HStack(spacing: 6) {
            Color.clear.frame(width: CGFloat(depth) * 14)
            if isPart {
                Button { session.setExpanded(id, !(session.rig.part(id)?.expanded ?? true)) } label: {
                    Image(systemName: (session.rig.part(id)?.expanded ?? true) ? "chevron.down" : "chevron.right").font(.caption2).frame(width: 14)
                }.buttonStyle(.plain)
            } else { thumbnail }
            Image(systemName: isPart ? "folder" : "photo").font(.caption).foregroundStyle(.secondary)
            if renaming == id {
                TextField("Name", text: $renameText)
                    .textFieldStyle(.roundedBorder).font(.callout)
                    .onSubmit { session.rename(id, to: renameText); renaming = nil }
            } else {
                Text(session.name(of: id)).font(.callout).lineLimit(1)
                    .foregroundStyle(session.isVisible(id) ? Color.primary : Color.secondary)
            }
            Spacer(minLength: 4)
            if let m = session.rig.mesh(id) {
                if !m.maskIDs.isEmpty { Image(systemName: "scissors").font(.caption2).foregroundStyle(.secondary) }
                if !m.keyforms.bindings.isEmpty { Image(systemName: "diamond.fill").font(.system(size: 8)).foregroundStyle(Theme.keyColor) }
            }
            Button { session.setLocked(id, !session.isLockedFlag(id)) } label: {
                Image(systemName: session.isLockedFlag(id) ? "lock.fill" : "lock.open").font(.caption)
                    .foregroundStyle(session.isLockedFlag(id) ? Color.primary : Color.secondary.opacity(0.4))
            }.buttonStyle(.plain)
            Button { session.setVisible(id, !session.isVisible(id)) } label: {
                Image(systemName: session.isVisible(id) ? "eye" : "eye.slash").font(.caption)
            }.buttonStyle(.plain)
        }
        .padding(.horizontal, 10).frame(height: 34)
        .background(selected ? Theme.accent.opacity(0.28) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture { session.select(id, extend: false) }
        .simultaneousGesture(TapGesture().modifiers(.shift).onEnded { session.select(id, extend: true) })
        .draggable(id)
        .dropDestination(for: String.self) { items, _ in
            for dragged in items where dragged != id {
                if isPart, session.rig.part(id)?.expanded == true {
                    session.moveNode(dragged, toParent: id, at: 0)
                } else {
                    let parent = session.hierarchyParent(of: id)
                    let idx = session.rig.children(of: parent).firstIndex(of: id) ?? 0
                    session.moveNode(dragged, toParent: parent, at: idx)
                }
            }
            return true
        }
        .contextMenu {
            Button("Rename") { renameText = session.name(of: id); renaming = id }
            Button("Add to Selection") { session.select(id, extend: true) }
            Button("Move Up") { session.nudgeOrder(id, by: -1) }
            Button("Move Down") { session.nudgeOrder(id, by: 1) }
            if isPart { Button("Ungroup") { session.ungroup(id) } }
            else {
                Button("Auto Mesh") { session.autoMesh([id]) }
                Button("Select All Vertices") { session.select(id); session.selectAllVertices(of: id); session.tool = .deform }
            }
            Divider()
            Button("Delete", role: .destructive) { session.select(id); session.deleteSelection() }
        }
    }

    @ViewBuilder var thumbnail: some View {
        if let m = session.rig.mesh(id), let img = session.texture(m.textureID), let cg = img.thumbnailCGImage(maxSize: 28) {
            Image(decorative: cg, scale: 1).resizable().interpolation(.medium).scaledToFit()
                .frame(width: 24, height: 24).background(Color(white: 0.3), in: RoundedRectangle(cornerRadius: 3))
        } else { Color.clear.frame(width: 24, height: 24) }
    }
}
