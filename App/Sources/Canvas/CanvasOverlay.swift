import SwiftUI
import M2DCore
import M2DRig
import M2DEditor

/// Vector overlay: mesh wireframes, vertices, deformer lattices and handles.
struct CanvasOverlay: View {
    let session: EditorSession
    let viewport: CanvasViewport
    let tools: CanvasToolController

    var body: some View {
        Canvas { ctx, _ in
            let v = viewport
            // Canvas bounds.
            let r = session.rig.canvasRect
            ctx.stroke(Path(CGRect(origin: v.toView(r.origin), size: CGSize(width: CGFloat(r.width) * v.scale, height: CGFloat(r.height) * v.scale))),
                       with: .color(.white.opacity(0.25)), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
            let pose = session.pose
            let selectedMeshes = Set(session.selectedMeshIDs)
            let showVertices = [.deform, .meshEdit, .triangle, .lasso].contains(session.tool)

            // Meshes
            for m in session.rig.meshes where selectedMeshes.contains(m.id) || (session.onionSkin && session.showMeshWireframe) {
                guard let mp = pose.meshes[m.id] else { continue }
                let pts = mp.positions.map(v.toView)
                let selected = selectedMeshes.contains(m.id)
                if session.showMeshWireframe || showVertices {
                    var wire = Path()
                    for (a, b) in m.mesh.edges { wire.move(to: pts[a]); wire.addLine(to: pts[b]) }
                    ctx.stroke(wire, with: .color(Theme.meshColor.opacity(selected ? 0.75 : 0.25)), lineWidth: 0.75)
                }
                var outline = Path()
                for (a, b) in m.mesh.boundaryEdges { outline.move(to: pts[a]); outline.addLine(to: pts[b]) }
                ctx.stroke(outline, with: .color(Theme.accent), lineWidth: selected ? 1.5 : 0.75)
                if selected && showVertices {
                    let sel = session.selection.vertices[m.id] ?? []
                    for (i, p) in pts.enumerated() {
                        let isSel = sel.contains(i)
                        let picked = session.selection.trianglePick.contains(i)
                        let hover = tools.hoverVertex.map { $0 == (m.id, i) } ?? false
                        let s: CGFloat = isSel || hover || picked ? 9 : 6
                        let rect = CGRect(x: p.x - s / 2, y: p.y - s / 2, width: s, height: s)
                        ctx.fill(Path(ellipseIn: rect), with: .color(picked ? Theme.keyColor : isSel ? .white : Theme.accent))
                        if hover { ctx.stroke(Path(ellipseIn: rect.insetBy(dx: -3, dy: -3)), with: .color(.white), lineWidth: 1) }
                    }
                }
            }

            // Deformers
            if session.showDeformers {
                for d in session.rig.deformers {
                    guard let dp = pose.deformers[d.id] else { continue }
                    let selected = session.selection.contains(d.id)
                    switch d.kind {
                    case let .warp(w):
                        guard selected || session.tool == .select || session.tool == .deform else { continue }
                        let pts = dp.latticePoints.map(v.toView)
                        var grid = Path()
                        let s = w.columns + 1
                        for j in 0...w.rows { for i in 0...w.columns {
                            let p = pts[j * s + i]
                            if i < w.columns { grid.move(to: p); grid.addLine(to: pts[j * s + i + 1]) }
                            if j < w.rows { grid.move(to: p); grid.addLine(to: pts[(j + 1) * s + i]) }
                        }}
                        ctx.stroke(grid, with: .color(Theme.warpColor.opacity(selected ? 0.9 : 0.25)), lineWidth: selected ? 1.25 : 0.75)
                        if selected {
                            let selPts = session.selection.controlPoints[d.id] ?? []
                            for (i, p) in pts.enumerated() {
                                let rect = CGRect(x: p.x - 5, y: p.y - 5, width: 10, height: 10)
                                ctx.fill(Path(rect), with: .color(selPts.contains(i) ? .white : Theme.warpColor))
                                ctx.stroke(Path(rect), with: .color(.black.opacity(0.6)), lineWidth: 0.5)
                            }
                        }
                    case let .rotation(rot):
                        let o = v.toView(dp.origin)
                        let len = CGFloat(rot.handleLength * dp.scale) * v.scale
                        let ang = CGFloat(degreesToRadians(dp.angle))
                        let tip = CGPoint(x: o.x + sin(ang) * len, y: o.y - cos(ang) * len)
                        let color = Theme.rotationColor.opacity(selected ? 1 : 0.4)
                        var line = Path(); line.move(to: o); line.addLine(to: tip)
                        ctx.stroke(line, with: .color(color), lineWidth: selected ? 2 : 1)
                        ctx.stroke(Path(ellipseIn: CGRect(x: o.x - 8, y: o.y - 8, width: 16, height: 16)), with: .color(color), lineWidth: 2)
                        ctx.fill(Path(ellipseIn: CGRect(x: tip.x - 6, y: tip.y - 6, width: 12, height: 12)), with: .color(color))
                    }
                }
            }

            // Lasso
            if tools.lassoPath.count > 1 {
                var p = Path()
                p.addLines(tools.lassoPath.map(v.toView))
                p.closeSubpath()
                ctx.fill(p, with: .color(Theme.accent.opacity(0.12)))
                ctx.stroke(p, with: .color(Theme.accent), style: StrokeStyle(lineWidth: 1, dash: [5, 3]))
            }
        }
        .allowsHitTesting(false)
    }
}
