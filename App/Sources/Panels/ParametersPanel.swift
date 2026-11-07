import SwiftUI
import M2DCore
import M2DRig
import M2DEditor

/// Parameter sliders with key markers. Keys shown are those of the current
/// selection (or of the whole rig when nothing is selected).
struct ParametersPanel: View {
    let session: EditorSession
    @State private var editing: Parameter?
    @State private var creating = false

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(title: "Parameters") {
                HStack(spacing: 12) {
                    Menu {
                        Button("New Parameter…") { creating = true }
                        Button("Add Standard Parameters") { session.addStandardParameters() }
                        Button("Reset All Values") { session.resetParameters() }
                    } label: { Image(systemName: "plus") }
                }
            }
            if session.mode == .rig && !session.selectionForKeyforms.isEmpty {
                Text("Keys for: \(session.selectionForKeyforms.prefix(3).map(session.name(of:)).joined(separator: ", "))\(session.selectionForKeyforms.count > 3 ? "…" : "")")
                    .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.top, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4, pinnedViews: [.sectionHeaders]) {
                    ForEach(groups, id: \.0) { group, params in
                        Section {
                            ForEach(params) { p in ParameterRow(session: session, parameter: p, edit: { editing = p }) }
                        } header: {
                            Text(group.isEmpty ? "General" : group).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.vertical, 4)
                                .background(Theme.panel)
                        }
                    }
                }
                .padding(.bottom, 20)
            }
        }
        .sheet(item: $editing) { p in ParameterEditor(session: session, parameter: p) }
        .sheet(isPresented: $creating) { ParameterEditor(session: session, parameter: nil) }
    }

    var groups: [(String, [Parameter])] {
        var order: [String] = []
        var dict: [String: [Parameter]] = [:]
        for p in session.rig.parameters {
            if dict[p.group] == nil { order.append(p.group) }
            dict[p.group, default: []].append(p)
        }
        return order.map { ($0, dict[$0]!) }
    }
}

struct ParameterRow: View {
    let session: EditorSession
    let parameter: Parameter
    let edit: () -> Void

    var keys: [Float] {
        session.selectionForKeyforms.isEmpty ? session.allKeys(of: parameter.id) : session.keys(of: parameter.id)
    }
    var animated: Bool { session.currentClip?.track(parameter.id) != nil && session.mode == .animate }

    var body: some View {
        let value = session.value(of: parameter.id)
        let onKey = keys.contains { abs($0 - value) < 1e-4 }
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                if animated { Image(systemName: "diamond.fill").font(.system(size: 8)).foregroundStyle(Theme.keyColor) }
                Text(parameter.name).font(.callout).lineLimit(1)
                Spacer()
                Text(String(format: "%.2f", value)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                if session.mode == .rig {
                    Button {
                        if onKey { session.removeKeyAtCurrentValue(parameter.id) } else { session.addKeyAtCurrentValue(parameter.id) }
                    } label: {
                        Image(systemName: onKey ? "minus.diamond" : "plus.diamond").foregroundStyle(onKey ? Color.red.opacity(0.8) : Theme.keyColor)
                    }
                    .buttonStyle(.plain)
                    .disabled(session.selectionForKeyforms.isEmpty)
                    .help(onKey ? "Remove key at this value from selection" : "Add key at this value to selection")
                }
                Menu {
                    Button("Edit…", action: edit)
                    Button("Snap to Nearest Key") { session.snapToNearestKey(parameter.id) }
                    Button("Reset to Default") { session.setParameterValue(parameter.id, parameter.defaultValue) }
                    if session.mode == .rig, !session.selectionForKeyforms.isEmpty {
                        Divider()
                        Button("Bind Selection (min/default/max)") { session.bind(to: parameter.id) }
                        Button("Unbind Selection") { session.unbind(from: parameter.id) }
                        if let id = session.selectionForKeyforms.first {
                            Button("Mirror Shape to Opposite Key") { session.mirrorKeyform(id, parameterID: parameter.id) }
                        }
                    }
                    Divider()
                    Button("Delete Parameter", role: .destructive) { session.deleteParameter(parameter.id) }
                } label: { Image(systemName: "ellipsis").frame(width: 22, height: 22) }
            }
            KeyedSlider(value: Binding(get: { value }, set: { session.setParameterValue(parameter.id, $0) }),
                        range: parameter.minValue...parameter.maxValue, keys: keys, defaultValue: parameter.defaultValue,
                        onEditingChanged: { editing in
                            if session.mode == .animate { if editing { session.beginGesture("Key \(parameter.name)") } else { session.endGesture() } }
                        })
                .frame(height: 26)
        }
        .padding(.horizontal, 12).padding(.vertical, 4)
    }
}

/// Slider that draws key positions and snaps to them when close.
struct KeyedSlider: View {
    @Binding var value: Float
    let range: ClosedRange<Float>
    let keys: [Float]
    let defaultValue: Float
    var onEditingChanged: (Bool) -> Void = { _ in }
    @State private var dragging = false

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let span = max(range.upperBound - range.lowerBound, 1e-6)
            let x: (Float) -> CGFloat = { v in CGFloat((v - range.lowerBound) / span) * (w - 16) + 8 }
            ZStack(alignment: .leading) {
                Capsule().fill(Color(white: 0.28)).frame(height: 4).padding(.horizontal, 8)
                Rectangle().fill(Color.white.opacity(0.35)).frame(width: 1, height: 10).position(x: x(defaultValue), y: geo.size.height / 2)
                ForEach(keys, id: \.self) { k in
                    Image(systemName: "diamond.fill").font(.system(size: 8)).foregroundStyle(Theme.keyColor)
                        .position(x: x(k), y: geo.size.height / 2 + 9)
                }
                Circle().fill(Color.white).frame(width: 16, height: 16).shadow(radius: 1)
                    .position(x: x(value), y: geo.size.height / 2)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { g in
                    if !dragging { dragging = true; onEditingChanged(true) }
                    var v = range.lowerBound + Float((g.location.x - 8) / max(w - 16, 1)) * span
                    v = min(max(v, range.lowerBound), range.upperBound)
                    // Snap to keys within 1.5% of the range.
                    if let k = keys.min(by: { abs($0 - v) < abs($1 - v) }), abs(k - v) < span * 0.015 { v = k }
                    value = v
                }
                .onEnded { _ in dragging = false; onEditingChanged(false) })
            .accessibilityElement()
            .accessibilityValue(Text(String(format: "%.2f", value)))
            .accessibilityAdjustableAction { dir in
                let step = span / 20
                value = min(max(value + (dir == .increment ? step : -step), range.lowerBound), range.upperBound)
            }
        }
    }
}

struct ParameterEditor: View {
    let session: EditorSession
    let parameter: Parameter?
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var minV: Float = -1
    @State private var maxV: Float = 1
    @State private var defV: Float = 0
    @State private var group = ""
    @State private var cyclic = false

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $name)
                TextField("Group", text: $group)
                Section("Range") {
                    numberField("Minimum", $minV)
                    numberField("Maximum", $maxV)
                    numberField("Default", $defV)
                    Toggle("Cyclic (wraps around)", isOn: $cyclic)
                }
            }
            .navigationTitle(parameter == nil ? "New Parameter" : "Edit Parameter")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        if let p = parameter {
                            if name != p.name { session.rename(p.id, to: name) }
                            session.updateParameter(p.id, min: minV, max: maxV, default: defV, group: group, cyclic: cyclic)
                        } else {
                            let id = session.addParameter(name: name.isEmpty ? "Parameter" : name, min: minV, max: max(maxV, minV + 0.001), default: defV, group: group)
                            if cyclic { session.updateParameter(id, cyclic: true) }
                        }
                        dismiss()
                    }
                }
            }
            .onAppear {
                if let p = parameter { name = p.name; minV = p.minValue; maxV = p.maxValue; defV = p.defaultValue; group = p.group; cyclic = p.isCyclic }
            }
        }
        .presentationDetents([.medium])
    }

    func numberField(_ title: String, _ v: Binding<Float>) -> some View {
        HStack {
            Text(title)
            Spacer()
            TextField(title, value: v, format: .number).keyboardType(.numbersAndPunctuation).multilineTextAlignment(.trailing).frame(width: 100)
        }
    }
}
