import SwiftUI
import M2DEditor

struct CanvasView: View {
    let session: EditorSession
    let viewport: CanvasViewport
    let tools: CanvasToolController
    var pencilOnly: Bool
    var onPencilDoubleTap: () -> Void

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Theme.canvasBackground
                checker
                MetalCanvasView(session: session, viewport: viewport)
                CanvasOverlay(session: session, viewport: viewport, tools: tools)
                CanvasInputView(tools: tools, viewport: viewport, pencilOnly: pencilOnly, onPencilDoubleTap: onPencilDoubleTap)
            }
            .clipped()
            .onAppear { fitIfNeeded(geo.size) }
            .onChange(of: geo.size) { _, s in viewport.viewSize = s; if !viewport.hasFitted { fitIfNeeded(s) } }
            .onChange(of: viewport.hasFitted) { _, fitted in if !fitted { fitIfNeeded(geo.size) } }
            .onChange(of: session.rig.canvasWidth) { _, _ in viewport.hasFitted = false }
        }
    }

    /// Checkerboard limited to the canvas rectangle so transparency is visible.
    var checker: some View {
        let r = session.rig.canvasRect
        let o = viewport.toView(r.origin)
        return Checkerboard(size: 10)
            .frame(width: CGFloat(r.width) * viewport.scale, height: CGFloat(r.height) * viewport.scale)
            .position(x: o.x + CGFloat(r.width) * viewport.scale / 2, y: o.y + CGFloat(r.height) * viewport.scale / 2)
            .allowsHitTesting(false)
    }

    func fitIfNeeded(_ size: CGSize) {
        viewport.viewSize = size
        viewport.fit(canvas: CGSize(width: session.rig.canvasWidth, height: session.rig.canvasHeight), in: size)
    }
}
