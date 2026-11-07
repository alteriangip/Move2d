import SwiftUI
import Observation
import M2DCore

/// Maps canvas (artwork pixel) coordinates to view points.
@Observable
final class CanvasViewport {
    var scale: CGFloat = 0.5
    var offset: CGPoint = .zero
    var viewSize: CGSize = .zero
    var hasFitted = false

    var affine: Affine2D { Affine2D(a: Float(scale), b: 0, c: 0, d: Float(scale), tx: Float(offset.x), ty: Float(offset.y)) }

    func toView(_ p: Vec2) -> CGPoint { CGPoint(x: CGFloat(p.x) * scale + offset.x, y: CGFloat(p.y) * scale + offset.y) }
    func toCanvas(_ p: CGPoint) -> Vec2 { Vec2(Float((p.x - offset.x) / scale), Float((p.y - offset.y) / scale)) }
    func toCanvasDelta(_ d: CGSize) -> Vec2 { Vec2(Float(d.width / scale), Float(d.height / scale)) }

    func fit(canvas: CGSize, in size: CGSize, margin: CGFloat = 40) {
        guard size.width > 0, size.height > 0, canvas.width > 0, canvas.height > 0 else { return }
        scale = min((size.width - margin * 2) / canvas.width, (size.height - margin * 2) / canvas.height)
        offset = CGPoint(x: (size.width - canvas.width * scale) / 2, y: (size.height - canvas.height * scale) / 2)
        hasFitted = true
    }

    func zoom(by factor: CGFloat, around p: CGPoint) {
        let newScale = min(max(scale * factor, 0.02), 40)
        let f = newScale / scale
        offset = CGPoint(x: p.x - (p.x - offset.x) * f, y: p.y - (p.y - offset.y) * f)
        scale = newScale
    }

    func pan(by d: CGSize) { offset = CGPoint(x: offset.x + d.width, y: offset.y + d.height) }
}
