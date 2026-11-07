import SwiftUI
import M2DCore
import M2DRig
import M2DPhysics
import M2DEditor

/// Secondary motion: pendulum chains driven by input parameters that write output parameters.
struct PhysicsPanel: View {
    let session: EditorSession
    @State private var expanded: Set<ObjectID> = []

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(title: "Physics") {
                Menu {
                    Button("Empty Group") { expanded.insert(session.addPhysicsGroup()) }
                    Menu("Hair Preset") {
                        ForEach(session.rig.parameters) { p in
                            Button("Output → \(p.name)") { expanded.insert(session.addPhysicsGroup(.hair(name: "\(p.name) Physics", output: p.id))) }
                        }
                    }
                } label: { Image(systemName: "plus") }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Simulate in preview", isOn: Binding(get: { session.physicsEnabled }, set: { session.physicsEnabled = $0; session.resetPhysics() }))
                        .padding(.horizontal, 12).padding(.top, 8)
                    environment.padding(.horizontal, 12)
                    if session.project.physics.groups.isEmpty {
                        Text("Physics makes hair, clothing and accessories swing after the head and body move. Add a group, choose inputs (e.g. Angle X) and an output parameter that drives a sway deformer.")
                            .font(.caption).foregroundStyle(.secondary).padding(12)
                    }
                    ForEach(session.project.physics.groups) { g in
                        DisclosureGroup(isExpanded: Binding(get: { expanded.contains(g.id) }, set: { if $0 { expanded.insert(g.id) } else { expanded.remove(g.id) } })) {
                            PhysicsGroupEditor(session: session, group: g)
                        } label: {
                            HStack {
                                Toggle("", isOn: Binding(get: { g.enabled }, set: { v in session.updatePhysicsGroup(g.id) { $0.enabled = v } })).labelsHidden()
                                Text(g.name).font(.callout)
                            }
                        }
                        .padding(.horizontal, 12)
                        Divider()
                    }
                }
                .padding(.bottom, 20)
            }
        }
    }

    var environment: some View {
        let phys = session.project.physics
        return VStack(alignment: .leading) {
            FormSlider(session: session, title: "Gravity", value: phys.gravity.y, range: 0...300, format: "%.0f") { session.setPhysicsEnvironment(gravity: Vec2(0, $0)) }
            FormSlider(session: session, title: "Wind", value: phys.wind.x, range: -100...100, format: "%.0f") { session.setPhysicsEnvironment(wind: Vec2($0, 0)) }
        }
    }
}

struct PhysicsGroupEditor: View {
    let session: EditorSession
    let group: PhysicsGroup

    func update(_ f: @escaping (inout PhysicsGroup) -> Void) { session.updatePhysicsGroup(group.id, f) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Inputs").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(Array(group.inputs.enumerated()), id: \.offset) { i, input in
                HStack {
                    parameterMenu(input.parameterID) { pid in update { $0.inputs[i].parameterID = pid } }
                    Picker("", selection: Binding(get: { input.kind }, set: { k in update { $0.inputs[i].kind = k } })) {
                        Text("X").tag(PhysicsInputKind.translationX); Text("Y").tag(PhysicsInputKind.translationY); Text("Angle").tag(PhysicsInputKind.angle)
                    }.labelsHidden().frame(width: 90)
                    Text(String(format: "%.0f%%", input.weight * 100)).font(.caption.monospacedDigit())
                    Stepper("", value: Binding(get: { input.weight }, set: { w in update { $0.inputs[i].weight = min(max(w, 0), 1) } }), in: 0...1, step: 0.1).labelsHidden()
                    Button { update { $0.inputs.remove(at: i) } } label: { Image(systemName: "minus.circle") }.buttonStyle(.plain)
                }
            }
            Button("Add Input") { update { $0.inputs.append(PhysicsInput(parameterID: session.rig.parameters.first?.id ?? "", kind: .translationX)) } }
                .font(.caption)

            Text("Outputs").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(Array(group.outputs.enumerated()), id: \.offset) { i, out in
                VStack(alignment: .leading) {
                    HStack {
                        parameterMenu(out.parameterID) { pid in update { $0.outputs[i].parameterID = pid } }
                        Toggle("Flip", isOn: Binding(get: { out.reflect }, set: { v in update { $0.outputs[i].reflect = v } })).font(.caption)
                        Button { update { $0.outputs.remove(at: i) } } label: { Image(systemName: "minus.circle") }.buttonStyle(.plain)
                    }
                    Stepper("Segment \(out.particleIndex)", value: Binding(get: { out.particleIndex }, set: { v in update { $0.outputs[i].particleIndex = max(1, min(v, $0.particles.count)) } }), in: 1...max(1, group.particles.count))
                        .font(.caption)
                    FormSlider(session: session, title: "Swing range (°)", value: out.angleRange, range: 5...90, format: "%.0f") { v in update { $0.outputs[i].angleRange = v } }
                }
            }
            Button("Add Output") { update { $0.outputs.append(PhysicsOutput(parameterID: session.rig.parameters.first?.id ?? "", particleIndex: max(1, $0.particles.count))) } }
                .font(.caption)

            Text("Pendulum").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Stepper("Segments: \(group.particles.count)", value: Binding(get: { group.particles.count }, set: { n in
                update { g in
                    let n = max(1, min(n, 8))
                    while g.particles.count < n { g.particles.append(g.particles.last ?? PhysicsParticle()) }
                    while g.particles.count > n { g.particles.removeLast() }
                    for o in g.outputs.indices { g.outputs[o].particleIndex = min(g.outputs[o].particleIndex, n) }
                }
            }), in: 1...8)
            let p = group.particles.first ?? PhysicsParticle()
            FormSlider(session: session, title: "Length", value: p.length, range: 1...40, format: "%.1f") { v in update { g in for i in g.particles.indices { g.particles[i].length = v } } }
            FormSlider(session: session, title: "Stiffness", value: p.stiffness, range: 0...60, format: "%.1f") { v in update { g in for i in g.particles.indices { g.particles[i].stiffness = v } } }
            FormSlider(session: session, title: "Damping", value: p.damping, range: 0...2) { v in update { g in for i in g.particles.indices { g.particles[i].damping = v } } }
            FormSlider(session: session, title: "Follow-through (lower = more lag)", value: p.mobility, range: 0...1) { v in update { g in for i in g.particles.indices { g.particles[i].mobility = v } } }
            FormSlider(session: session, title: "Input travel", value: group.translationScale, range: 0...40, format: "%.1f") { v in update { $0.translationScale = v } }
            FormSlider(session: session, title: "Input tilt (°)", value: group.angleScale, range: 0...45, format: "%.0f") { v in update { $0.angleScale = v } }
            Button("Delete Group", role: .destructive) { session.deletePhysicsGroup(group.id) }.font(.caption)
        }
        .padding(.vertical, 6)
    }

    func parameterMenu(_ current: ObjectID, _ set: @escaping (ObjectID) -> Void) -> some View {
        Menu {
            ForEach(session.rig.parameters) { p in Button(p.name) { set(p.id) } }
        } label: {
            Text(session.rig.parameter(current)?.name ?? "Choose…").font(.callout).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
