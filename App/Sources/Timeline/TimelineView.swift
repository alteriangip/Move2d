import SwiftUI
import M2DCore
import M2DRig
import M2DAnimation
import M2DEditor

struct KeySelection: Hashable { var parameterID: ObjectID; var keyID: ObjectID }

/// Dope sheet + curve view for the current animation clip.
struct TimelineView: View {
    let session: EditorSession
    @State private var pixelsPerSecond: CGFloat = 160
    @State private var selectedKeys: Set<KeySelection> = []
    @State private var showCurves = false
    @State private var renamingClip = false
    @State private var clipName = ""
    @State private var dragStartX: CGFloat?

    let labelWidth: CGFloat = 170
    let rowHeight: CGFloat = 26

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Theme.separator)
            if let clip = session.currentClip {
                if showCurves, let track = selectedTrack(clip) {
                    CurveView(session: session, clip: clip, track: track, pixelsPerSecond: pixelsPerSecond, labelWidth: labelWidth)
                } else {
                    dopeSheet(clip)
                }
            } else {
                VStack(spacing: 10) {
                    Text("No animations yet").foregroundStyle(.secondary)
                    HStack {
                        Button("New Animation") { session.addClip() }.buttonStyle(.borderedProminent)
                        Button("Generate Idle Loop") { session.addIdleClip() }.buttonStyle(.bordered)
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Theme.panel)
        .alert("Rename Animation", isPresented: $renamingClip) {
            TextField("Name", text: $clipName)
            Button("Rename") { if let id = session.currentClipID { session.rename(id, to: clipName) } }
            Button("Cancel", role: .cancel) {}
        }
    }

    // MARK: Header

    var header: some View {
        HStack(spacing: 10) {
            Menu {
                ForEach(session.project.animations) { c in
                    Button { session.currentClipID = c.id; session.seek(0) } label: {
                        if c.id == session.currentClipID { Label(c.name, systemImage: "checkmark") } else { Text(c.name) }
                    }
                }
                Divider()
                Button("New Animation") { session.addClip() }
                Button("Generate Idle Loop") { session.addIdleClip() }
                if let id = session.currentClipID {
                    Button("Rename…") { clipName = session.currentClip?.name ?? ""; renamingClip = true }
                    Button("Duplicate") { session.duplicateClip(id) }
                    Button("Delete", role: .destructive) { session.deleteClip(id) }
                }
            } label: {
                Label(session.currentClip?.name ?? "Animations", systemImage: "film").font(.callout.weight(.medium))
            }
            .frame(width: labelWidth - 10, alignment: .leading)

            Button { session.seek(0) } label: { Image(systemName: "backward.end.fill") }
            Button { session.togglePlayback() } label: { Image(systemName: session.isPlaying ? "pause.fill" : "play.fill") }
            if let clip = session.currentClip {
                Text(String(format: "%03d / %03d", session.currentFrame, clip.frameCount)).font(.caption.monospacedDigit())
                Divider().frame(height: 18)
                Picker("", selection: Binding(get: { clip.loopMode }, set: { session.updateClip(clip.id, loopMode: $0) })) {
                    Text("Loop").tag(LoopMode.loop); Text("Once").tag(LoopMode.once); Text("Ping-Pong").tag(LoopMode.pingPong)
                }.labelsHidden().frame(width: 120)
                Stepper(String(format: "%.1fs", clip.duration), value: Binding(get: { clip.duration }, set: { session.updateClip(clip.id, duration: $0) }), in: 0.1...600, step: 0.5)
                    .font(.caption).frame(width: 130)
                Menu("\(Int(clip.frameRate)) fps") {
                    ForEach([12.0, 24, 30, 60], id: \.self) { f in Button("\(Int(f)) fps") { session.updateClip(clip.id, frameRate: f) } }
                }.font(.caption)
            }
            Spacer()
            Toggle(isOn: Binding(get: { session.autoKey }, set: { session.autoKey = $0 })) { Image(systemName: "record.circle") }
                .toggleStyle(.button).tint(.red).help("Auto-key: parameter changes create keyframes")
            Button { session.keyAllParameters() } label: { Label("Key", systemImage: "plus.diamond") }.help("Key all changed parameters at the playhead")
            Button(role: .destructive) { deleteSelectedKeys() } label: { Image(systemName: "trash") }.disabled(selectedKeys.isEmpty)
            Menu {
                ForEach(Interpolation.allCases, id: \.self) { i in Button(i.displayName) { setInterpolation(i) } }
            } label: { Image(systemName: "point.topleft.down.curvedto.point.bottomright.up") }.disabled(selectedKeys.isEmpty)
            Toggle(isOn: $showCurves) { Image(systemName: "waveform.path") }.toggleStyle(.button).help("Curve editor for the selected track")
            Slider(value: $pixelsPerSecond, in: 40...600).frame(width: 90)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .buttonStyle(.borderless)
    }

    // MARK: Dope sheet

    func dopeSheet(_ clip: AnimationClip) -> some View {
        let tracks = clip.tracks
        let trackIDs = Set(tracks.map(\.parameterID))
        let untracked = session.rig.parameters.filter { !trackIDs.contains($0.id) }
        let width = CGFloat(clip.duration) * pixelsPerSecond + 40
        return ScrollView(.vertical) {
            HStack(alignment: .top, spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    Color.clear.frame(height: 22)
                    ForEach(tracks, id: \.parameterID) { t in trackLabel(clip, t) }
                    Menu {
                        ForEach(untracked) { p in Button(p.name) { session.setKeyframe(clipID: clip.id, parameterID: p.id, time: session.playhead, value: session.value(of: p.id)) } }
                    } label: { Label("Add Track", systemImage: "plus").font(.caption) }
                        .padding(.horizontal, 8).frame(height: rowHeight)
                }
                .frame(width: labelWidth)
                Divider().overlay(Theme.separator)
                ScrollView(.horizontal) {
                    ZStack(alignment: .topLeading) {
                        VStack(alignment: .leading, spacing: 0) {
                            ruler(clip, width: width)
                            ForEach(tracks, id: \.parameterID) { t in keyRow(clip, t, width: width) }
                        }
                        playhead(clip, height: CGFloat(tracks.count + 1) * rowHeight + 22)
                    }
                    .frame(width: width, alignment: .leading)
                }
            }
        }
    }

    func trackLabel(_ clip: AnimationClip, _ t: ParameterTrack) -> some View {
        let selected = selectedKeys.contains { $0.parameterID == t.parameterID }
        return HStack(spacing: 4) {
            Button { session.setTrackEnabled(clipID: clip.id, parameterID: t.parameterID, !t.enabled) } label: {
                Image(systemName: t.enabled ? "speaker.wave.1" : "speaker.slash").font(.caption2)
            }.buttonStyle(.plain)
            Text(session.rig.parameter(t.parameterID)?.name ?? t.parameterID).font(.caption).lineLimit(1)
                .foregroundStyle(t.enabled ? Color.primary : Color.secondary)
            if t.blend == .additive { Text("+").font(.caption.bold()).foregroundStyle(Theme.accent) }
            Spacer()
        }
        .padding(.horizontal, 8).frame(height: rowHeight)
        .background(selected ? Theme.accent.opacity(0.15) : Color.clear)
        .contextMenu {
            Button(t.blend == .additive ? "Override Blend" : "Additive Blend") {
                session.setTrackBlend(clipID: clip.id, parameterID: t.parameterID, t.blend == .additive ? .override : .additive)
            }
            Button("Select All Keys") { selectedKeys = Set(t.keyframes.map { KeySelection(parameterID: t.parameterID, keyID: $0.id) }) }
            Button("Delete Track", role: .destructive) { session.deleteTrack(clipID: clip.id, parameterID: t.parameterID) }
        }
    }

    func ruler(_ clip: AnimationClip, width: CGFloat) -> some View {
        Canvas { ctx, size in
            let frames = clip.frameCount
            let step = max(1, Int(ceil(8 / (pixelsPerSecond / CGFloat(clip.frameRate)))))
            for f in stride(from: 0, through: frames, by: step) {
                let x = CGFloat(Double(f) / clip.frameRate) * pixelsPerSecond + 8
                let major = f % Int(clip.frameRate) == 0
                var p = Path(); p.move(to: CGPoint(x: x, y: size.height)); p.addLine(to: CGPoint(x: x, y: size.height - (major ? 10 : 5)))
                ctx.stroke(p, with: .color(.secondary), lineWidth: 1)
                if major { ctx.draw(Text("\(f / Int(clip.frameRate))s").font(.system(size: 9)), at: CGPoint(x: x + 8, y: 6)) }
            }
            let end = CGFloat(clip.duration) * pixelsPerSecond + 8
            ctx.fill(Path(CGRect(x: end, y: 0, width: 2, height: size.height)), with: .color(.red.opacity(0.6)))
        }
        .frame(width: width, height: 22)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0).onChanged { g in scrub(clip, g.location.x) })
    }

    func keyRow(_ clip: AnimationClip, _ t: ParameterTrack, width: CGFloat) -> some View {
        ZStack(alignment: .leading) {
            Rectangle().fill(Color.white.opacity(0.03)).frame(width: width, height: rowHeight - 2)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { g in scrub(clip, g.location.x) })
            // Segments
            Canvas { ctx, _ in
                for (a, b) in zip(t.keyframes, t.keyframes.dropFirst()) {
                    let x0 = CGFloat(a.time) * pixelsPerSecond + 8, x1 = CGFloat(b.time) * pixelsPerSecond + 8
                    var p = Path(); p.move(to: CGPoint(x: x0, y: rowHeight / 2)); p.addLine(to: CGPoint(x: x1, y: rowHeight / 2))
                    ctx.stroke(p, with: .color(.white.opacity(a.interpolation == .constant ? 0.1 : 0.25)), lineWidth: 2)
                }
            }
            .frame(width: width, height: rowHeight).allowsHitTesting(false)
            ForEach(t.keyframes) { k in
                let sel = KeySelection(parameterID: t.parameterID, keyID: k.id)
                let isSel = selectedKeys.contains(sel)
                Image(systemName: k.interpolation == .constant ? "square.fill" : "diamond.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(isSel ? Color.white : Theme.keyColor)
                    .frame(width: 22, height: rowHeight)
                    .contentShape(Rectangle())
                    .position(x: CGFloat(k.time) * pixelsPerSecond + 8, y: rowHeight / 2)
                    .onTapGesture { selectedKeys = [sel]; session.seek(k.time) }
                    .gesture(DragGesture(minimumDistance: 4)
                        .onChanged { g in
                            if dragStartX == nil { dragStartX = 0; if !isSel { selectedKeys = [sel] } }
                        }
                        .onEnded { g in
                            dragStartX = nil
                            let dt = Double(g.translation.width / pixelsPerSecond)
                            session.moveKeyframes(clipID: clip.id, selectedKeys.map { ($0.parameterID, $0.keyID) }, by: dt)
                        })
                    .contextMenu {
                        ForEach(Interpolation.allCases, id: \.self) { i in
                            Button(i.displayName) { session.updateKeyframe(clipID: clip.id, parameterID: t.parameterID, keyID: k.id, interpolation: i) }
                        }
                        Divider()
                        Button("Delete", role: .destructive) { session.deleteKeyframes(clipID: clip.id, [(t.parameterID, k.id)]) }
                    }
            }
        }
        .frame(width: width, height: rowHeight, alignment: .leading)
    }

    func playhead(_ clip: AnimationClip, height: CGFloat) -> some View {
        let x = CGFloat(clip.localTime(session.playhead)) * pixelsPerSecond + 8
        return Rectangle().fill(Color.red).frame(width: 1.5, height: height).offset(x: x).allowsHitTesting(false)
    }

    func scrub(_ clip: AnimationClip, _ x: CGFloat) {
        if session.isPlaying { session.isPlaying = false }
        if session.mode != .animate { session.mode = .animate }
        let t = Double(max(0, x - 8) / pixelsPerSecond)
        session.seek(session.snapTime(t, clip: clip))
    }

    func selectedTrack(_ clip: AnimationClip) -> ParameterTrack? {
        guard let pid = selectedKeys.first?.parameterID else { return clip.tracks.first }
        return clip.track(pid)
    }

    func deleteSelectedKeys() {
        guard let id = session.currentClipID else { return }
        session.deleteKeyframes(clipID: id, selectedKeys.map { ($0.parameterID, $0.keyID) })
        selectedKeys = []
    }

    func setInterpolation(_ i: Interpolation) {
        guard let id = session.currentClipID else { return }
        for k in selectedKeys { session.updateKeyframe(clipID: id, parameterID: k.parameterID, keyID: k.keyID, interpolation: i) }
    }
}

/// Value-over-time graph for one track, with draggable keys (value) and bezier handles.
struct CurveView: View {
    let session: EditorSession
    let clip: AnimationClip
    let track: ParameterTrack
    let pixelsPerSecond: CGFloat
    let labelWidth: CGFloat
    @State private var dragging: (keyID: ObjectID, handle: Int)? // 0 key, 1 out, 2 in

    var parameter: Parameter? { session.rig.parameter(track.parameterID) }

    var body: some View {
        GeometryReader { geo in
            let p = parameter
            let lo = p?.minValue ?? -1, hi = p?.maxValue ?? 1
            let h = geo.size.height - 20
            let X: (Double) -> CGFloat = { t in labelWidth + CGFloat(t) * pixelsPerSecond + 8 }
            let Y: (Float) -> CGFloat = { v in 10 + CGFloat(1 - (v - lo) / max(hi - lo, 1e-6)) * h }
            let V: (CGFloat) -> Float = { y in lo + Float(1 - (y - 10) / h) * (hi - lo) }
            ZStack(alignment: .topLeading) {
                Canvas { ctx, size in
                    ctx.draw(Text(p?.name ?? "").font(.caption), at: CGPoint(x: 70, y: 14))
                    for v in [lo, (lo + hi) / 2, hi] {
                        var g = Path(); g.move(to: CGPoint(x: labelWidth, y: Y(v))); g.addLine(to: CGPoint(x: size.width, y: Y(v)))
                        ctx.stroke(g, with: .color(.white.opacity(0.08)), lineWidth: 1)
                        ctx.draw(Text(String(format: "%g", v)).font(.system(size: 9)), at: CGPoint(x: labelWidth - 16, y: Y(v)))
                    }
                    var curve = Path()
                    let samples = Int(clip.duration * 60)
                    for i in 0...max(samples, 1) {
                        let t = clip.duration * Double(i) / Double(max(samples, 1))
                        let pt = CGPoint(x: X(t), y: Y(track.value(at: t) ?? 0))
                        if i == 0 { curve.move(to: pt) } else { curve.addLine(to: pt) }
                    }
                    ctx.stroke(curve, with: .color(Theme.accent), lineWidth: 2)
                    for (i, k) in track.keyframes.enumerated() {
                        let kp = CGPoint(x: X(k.time), y: Y(k.value))
                        if k.interpolation == .bezier, i + 1 < track.keyframes.count {
                            let n = track.keyframes[i + 1]
                            let dt = n.time - k.time
                            let o = CGPoint(x: X(k.time + dt * Double(k.outHandle.x)), y: Y(k.value + k.outHandle.y))
                            let inn = CGPoint(x: X(n.time - dt * Double(n.inHandle.x)), y: Y(n.value + n.inHandle.y))
                            var hp = Path(); hp.move(to: kp); hp.addLine(to: o)
                            hp.move(to: CGPoint(x: X(n.time), y: Y(n.value))); hp.addLine(to: inn)
                            ctx.stroke(hp, with: .color(.white.opacity(0.5)), lineWidth: 1)
                            ctx.fill(Path(ellipseIn: CGRect(x: o.x - 4, y: o.y - 4, width: 8, height: 8)), with: .color(.white))
                            ctx.fill(Path(ellipseIn: CGRect(x: inn.x - 4, y: inn.y - 4, width: 8, height: 8)), with: .color(.white))
                        }
                        ctx.fill(Path(CGRect(x: kp.x - 5, y: kp.y - 5, width: 10, height: 10)), with: .color(Theme.keyColor))
                    }
                    let px = X(clip.localTime(session.playhead))
                    ctx.fill(Path(CGRect(x: px, y: 0, width: 1.5, height: size.height)), with: .color(.red))
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        if dragging == nil {
                            dragging = hit(g.startLocation, X: X, Y: Y)
                            if dragging != nil { session.beginGesture("Edit Curve") }
                        }
                        guard let d = dragging, let i = track.keyframes.firstIndex(where: { $0.id == d.keyID }) else {
                            session.seek(Double(max(0, g.location.x - labelWidth - 8) / pixelsPerSecond)); return
                        }
                        let k = track.keyframes[i]
                        switch d.handle {
                        case 0: session.updateKeyframe(clipID: clip.id, parameterID: track.parameterID, keyID: k.id, value: V(g.location.y))
                        case 1 where i + 1 < track.keyframes.count:
                            let dt = track.keyframes[i + 1].time - k.time
                            let hx = Float(Double(g.location.x - X(k.time)) / (dt * Double(pixelsPerSecond)))
                            session.updateKeyframe(clipID: clip.id, parameterID: track.parameterID, keyID: k.id,
                                                   outHandle: CurveHandle(x: min(max(hx, 0), 1), y: V(g.location.y) - k.value))
                        case 2 where i > 0:
                            let dt = k.time - track.keyframes[i - 1].time
                            let hx = Float(Double(X(k.time) - g.location.x) / (dt * Double(pixelsPerSecond)))
                            session.updateKeyframe(clipID: clip.id, parameterID: track.parameterID, keyID: k.id,
                                                   inHandle: CurveHandle(x: min(max(hx, 0), 1), y: V(g.location.y) - k.value))
                        default: break
                        }
                    }
                    .onEnded { _ in if dragging != nil { session.endGesture() }; dragging = nil })
            }
        }
    }

    func hit(_ p: CGPoint, X: (Double) -> CGFloat, Y: (Float) -> CGFloat) -> (keyID: ObjectID, handle: Int)? {
        for (i, k) in track.keyframes.enumerated() {
            if hypot(p.x - X(k.time), p.y - Y(k.value)) < 14 { return (k.id, 0) }
            if k.interpolation == .bezier, i + 1 < track.keyframes.count {
                let dt = track.keyframes[i + 1].time - k.time
                if hypot(p.x - X(k.time + dt * Double(k.outHandle.x)), p.y - Y(k.value + k.outHandle.y)) < 14 { return (k.id, 1) }
            }
            if i > 0, track.keyframes[i - 1].interpolation == .bezier {
                let dt = k.time - track.keyframes[i - 1].time
                if hypot(p.x - X(k.time - dt * Double(k.inHandle.x)), p.y - Y(k.value + k.inHandle.y)) < 14 { return (k.id, 2) }
            }
        }
        return nil
    }
}
