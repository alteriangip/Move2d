import SwiftUI
import UIKit
import M2DCore
import M2DEditor

/// Transparent UIKit layer that receives touches so Apple Pencil and fingers can
/// be told apart: Pencil (or one finger, unless "Pencil only" is on) drives the
/// active tool, two fingers pan/zoom, and Pencil hover previews vertex picks.
struct CanvasInputView: UIViewRepresentable {
    let tools: CanvasToolController
    let viewport: CanvasViewport
    var pencilOnly: Bool
    var onPencilDoubleTap: () -> Void

    func makeUIView(context: Context) -> InputView {
        let v = InputView()
        v.backgroundColor = .clear
        v.isMultipleTouchEnabled = true
        v.configure(tools: tools, viewport: viewport)
        return v
    }

    func updateUIView(_ v: InputView, context: Context) {
        v.pencilOnly = pencilOnly
        v.onPencilDoubleTap = onPencilDoubleTap
    }

    final class InputView: UIView, UIGestureRecognizerDelegate, UIPencilInteractionDelegate {
        var tools: CanvasToolController!
        var viewport: CanvasViewport!
        var pencilOnly = false
        var onPencilDoubleTap: () -> Void = {}
        private var activeTouch: UITouch?
        private var lastViewPoint: CGPoint = .zero
        private var navigating = false

        func configure(tools: CanvasToolController, viewport: CanvasViewport) {
            self.tools = tools; self.viewport = viewport
            let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
            let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
            pan.minimumNumberOfTouches = 2; pan.maximumNumberOfTouches = 2
            for g in [pinch, pan] as [UIGestureRecognizer] {
                g.delegate = self
                g.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
                g.cancelsTouchesInView = false
                addGestureRecognizer(g)
            }
            let hover = UIHoverGestureRecognizer(target: self, action: #selector(handleHover(_:)))
            addGestureRecognizer(hover)
            let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
            doubleTap.numberOfTapsRequired = 2; doubleTap.numberOfTouchesRequired = 2
            addGestureRecognizer(doubleTap)
            let pencil = UIPencilInteraction()
            pencil.delegate = self
            addInteraction(pencil)
        }

        func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

        // MARK: Tool touches

        private func accepts(_ t: UITouch) -> Bool {
            t.type == .pencil || (!pencilOnly && t.type == .direct) || t.type == .indirectPointer
        }

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
            let directCount = event?.allTouches?.filter { $0.type == .direct && $0.phase != .ended && $0.phase != .cancelled }.count ?? 0
            if directCount >= 2, let t = activeTouch, t.type == .direct {
                // A second finger arrived: this is navigation, undo the tool stroke.
                tools.cancelled(); activeTouch = nil; navigating = true
                return
            }
            guard activeTouch == nil, !navigating, let t = touches.first(where: accepts) else { return }
            activeTouch = t
            let p = t.location(in: self)
            lastViewPoint = p
            let shift = event?.modifierFlags.contains(.shift) ?? false
            tools.began(viewport.toCanvas(p), isPencil: t.type == .pencil, shift: shift)
        }

        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
            guard let t = activeTouch, touches.contains(t) else { return }
            let samples = event?.coalescedTouches(for: t) ?? [t]
            for s in samples {
                let p = s.preciseLocation(in: self)
                let d = CGSize(width: p.x - lastViewPoint.x, height: p.y - lastViewPoint.y)
                lastViewPoint = p
                tools.moved(viewport.toCanvas(p), viewDelta: d)
            }
        }

        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
            if let t = activeTouch, touches.contains(t) {
                tools.ended(viewport.toCanvas(t.preciseLocation(in: self)))
                activeTouch = nil
            }
            if event?.allTouches?.allSatisfy({ $0.phase == .ended || $0.phase == .cancelled }) ?? true { navigating = false }
        }

        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
            if let t = activeTouch, touches.contains(t) { tools.cancelled(); activeTouch = nil }
            navigating = false
        }

        // MARK: Navigation

        @objc func handlePinch(_ g: UIPinchGestureRecognizer) {
            guard g.state == .changed || g.state == .began else { return }
            viewport.zoom(by: g.scale, around: g.location(in: self))
            g.scale = 1
        }

        @objc func handlePan(_ g: UIPanGestureRecognizer) {
            guard g.state == .changed || g.state == .began else { return }
            let t = g.translation(in: self)
            viewport.pan(by: CGSize(width: t.x, height: t.y))
            g.setTranslation(.zero, in: self)
        }

        @objc func handleHover(_ g: UIHoverGestureRecognizer) {
            switch g.state {
            case .began, .changed: tools.hover(viewport.toCanvas(g.location(in: self)))
            default: tools.hover(nil)
            }
        }

        @objc func handleDoubleTap(_ g: UITapGestureRecognizer) {
            // Two-finger double tap: fit canvas.
            viewport.hasFitted = false
        }

        func pencilInteractionDidTap(_ interaction: UIPencilInteraction) { onPencilDoubleTap() }

        // Trackpad / mouse wheel zoom.
        override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) { super.pressesBegan(presses, with: event) }
    }
}
