import SwiftUI
import MetalKit
import QuartzCore
import M2DCore
import M2DRig
import M2DRender
import M2DMetal
import M2DEditor

/// Hosts the Metal-rendered character. Drives the editor clock (playback and
/// physics) from the display link so the preview is always live.
struct MetalCanvasView: UIViewRepresentable {
    let session: EditorSession
    let viewport: CanvasViewport

    func makeCoordinator() -> Coordinator { Coordinator(session: session, viewport: viewport) }

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView()
        view.device = context.coordinator.device
        view.colorPixelFormat = MetalRigRenderer.colorFormat
        view.depthStencilPixelFormat = MetalRigRenderer.depthStencilFormat
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        view.isOpaque = false
        view.backgroundColor = .clear
        view.preferredFramesPerSecond = 120
        view.delegate = context.coordinator
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ uiView: MTKView, context: Context) {}

    final class Coordinator: NSObject, MTKViewDelegate {
        let session: EditorSession
        let viewport: CanvasViewport
        let device: MTLDevice?
        let queue: MTLCommandQueue?
        var renderer: MetalRigRenderer?
        var lastTime: CFTimeInterval = CACurrentMediaTime()

        init(session: EditorSession, viewport: CanvasViewport) {
            self.session = session; self.viewport = viewport
            device = MTLCreateSystemDefaultDevice()
            queue = device?.makeCommandQueue()
            if let device { renderer = try? MetalRigRenderer(device: device) }
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

        func draw(in view: MTKView) {
            let now = CACurrentMediaTime()
            let dt = min(now - lastTime, 0.1)
            lastTime = now
            session.tick(dt: dt)
            guard let renderer, let queue, let pass = view.currentRenderPassDescriptor,
                  let drawable = view.currentDrawable, let cb = queue.makeCommandBuffer() else { return }
            renderer.syncTextures(session.bundle.textures, revision: session.textureRevision, commandQueue: queue)
            pass.stencilAttachment.clearStencil = 0
            guard let enc = cb.makeRenderCommandEncoder(descriptor: pass) else { return }
            let size = SIMD2<Float>(Float(view.bounds.width), Float(view.bounds.height))
            let clip = MetalRigRenderer.clipTransform(canvasToView: viewport.affine, viewSize: size)
            let commands = RenderListBuilder.build(model: session.rig, pose: session.pose)
            renderer.encode(commands, encoder: enc, canvasToClip: clip)
            enc.endEncoding()
            cb.present(drawable)
            cb.commit()
        }
    }
}
