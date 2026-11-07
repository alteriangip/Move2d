#if canImport(Metal)
import Foundation
import Metal
import simd
import M2DCore
import M2DRig
import M2DRender

/// GPU renderer for deformed rigs. Deformation is evaluated on the CPU by
/// `RigEvaluator` (cheap, deterministic, shared with export and runtime);
/// this class streams the deformed vertices each frame and composites the
/// meshes with premultiplied alpha, blend modes and stencil clipping masks.
public final class MetalRigRenderer {
    public let device: MTLDevice
    public static let colorFormat: MTLPixelFormat = .bgra8Unorm
    public static let depthStencilFormat: MTLPixelFormat = .depth32Float_stencil8

    var pipelines: [BlendMode: MTLRenderPipelineState] = [:]
    var maskPipeline: MTLRenderPipelineState!
    var sampler: MTLSamplerState!
    var stencilOff: MTLDepthStencilState!
    var stencilWrite: MTLDepthStencilState!
    var stencilEqual: MTLDepthStencilState!
    var stencilNotEqual: MTLDepthStencilState!
    var textures: [ObjectID: MTLTexture] = [:]
    var textureRevision = -1

    struct Vertex { var position: SIMD2<Float>; var uv: SIMD2<Float> }
    struct Uniforms { var col0: SIMD2<Float>; var col1: SIMD2<Float>; var col2: SIMD2<Float>; var opacity: Float; var pad: Float = 0 }

    static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;
    struct VIn { float2 position [[attribute(0)]]; float2 uv [[attribute(1)]]; };
    struct VOut { float4 position [[position]]; float2 uv; };
    struct Uniforms { float2 col0; float2 col1; float2 col2; float opacity; float pad; };
    vertex VOut rig_vertex(VIn in [[stage_in]], constant Uniforms &u [[buffer(1)]]) {
        VOut o;
        float2 p = u.col0 * in.position.x + u.col1 * in.position.y + u.col2;
        o.position = float4(p, 0, 1);
        o.uv = in.uv;
        return o;
    }
    fragment float4 rig_fragment(VOut in [[stage_in]], texture2d<float> tex [[texture(0)]],
                                 sampler s [[sampler(0)]], constant Uniforms &u [[buffer(1)]]) {
        return tex.sample(s, in.uv) * u.opacity;
    }
    fragment float4 mask_fragment(VOut in [[stage_in]], texture2d<float> tex [[texture(0)]], sampler s [[sampler(0)]]) {
        float a = tex.sample(s, in.uv).a;
        if (a < 0.5) discard_fragment();
        return float4(0);
    }
    """

    public init(device: MTLDevice) throws {
        self.device = device
        let library = try device.makeLibrary(source: Self.shaderSource, options: nil)
        let vd = MTLVertexDescriptor()
        vd.attributes[0].format = .float2; vd.attributes[0].offset = 0; vd.attributes[0].bufferIndex = 0
        vd.attributes[1].format = .float2; vd.attributes[1].offset = 8; vd.attributes[1].bufferIndex = 0
        vd.layouts[0].stride = MemoryLayout<Vertex>.stride

        func pipeline(_ fragment: String, blend: BlendMode?, writeColor: Bool = true) throws -> MTLRenderPipelineState {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = library.makeFunction(name: "rig_vertex")
            d.fragmentFunction = library.makeFunction(name: fragment)
            d.vertexDescriptor = vd
            d.depthAttachmentPixelFormat = Self.depthStencilFormat
            d.stencilAttachmentPixelFormat = Self.depthStencilFormat
            let ca = d.colorAttachments[0]!
            ca.pixelFormat = Self.colorFormat
            ca.writeMask = writeColor ? .all : []
            if let blend {
                ca.isBlendingEnabled = true
                ca.alphaBlendOperation = .add; ca.rgbBlendOperation = .add
                ca.sourceAlphaBlendFactor = .one; ca.destinationAlphaBlendFactor = .oneMinusSourceAlpha
                switch blend {
                case .normal: ca.sourceRGBBlendFactor = .one; ca.destinationRGBBlendFactor = .oneMinusSourceAlpha
                case .additive:
                    ca.sourceRGBBlendFactor = .one; ca.destinationRGBBlendFactor = .one
                    ca.sourceAlphaBlendFactor = .one; ca.destinationAlphaBlendFactor = .one
                case .multiply: ca.sourceRGBBlendFactor = .destinationColor; ca.destinationRGBBlendFactor = .oneMinusSourceAlpha
                case .screen: ca.sourceRGBBlendFactor = .one; ca.destinationRGBBlendFactor = .oneMinusSourceColor
                }
            }
            return try device.makeRenderPipelineState(descriptor: d)
        }
        for mode in BlendMode.allCases { pipelines[mode] = try pipeline("rig_fragment", blend: mode) }
        maskPipeline = try pipeline("mask_fragment", blend: nil, writeColor: false)

        let sd = MTLSamplerDescriptor()
        sd.minFilter = .linear; sd.magFilter = .linear; sd.mipFilter = .linear
        sd.sAddressMode = .clampToEdge; sd.tAddressMode = .clampToEdge
        sampler = device.makeSamplerState(descriptor: sd)

        func stencil(_ compare: MTLCompareFunction, _ pass: MTLStencilOperation) -> MTLDepthStencilState {
            let s = MTLStencilDescriptor()
            s.stencilCompareFunction = compare; s.depthStencilPassOperation = pass
            s.stencilFailureOperation = .keep; s.depthFailureOperation = .keep
            let d = MTLDepthStencilDescriptor()
            d.frontFaceStencil = s; d.backFaceStencil = s
            return device.makeDepthStencilState(descriptor: d)!
        }
        stencilOff = stencil(.always, .keep)
        stencilWrite = stencil(.always, .replace)
        stencilEqual = stencil(.equal, .keep)
        stencilNotEqual = stencil(.notEqual, .keep)
    }

    /// Upload textures when their revision changes. Textures are stored premultiplied with mipmaps.
    public func syncTextures(_ images: [ObjectID: RGBAImage], revision: Int, commandQueue: MTLCommandQueue) {
        guard revision != textureRevision else { return }
        textureRevision = revision
        textures.removeAll()
        let blit = commandQueue.makeCommandBuffer()
        let encoder = blit?.makeBlitCommandEncoder()
        for (id, img) in images where img.width > 0 && img.height > 0 {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: img.width, height: img.height, mipmapped: true)
            d.usage = .shaderRead
            guard let t = device.makeTexture(descriptor: d) else { continue }
            let pm = img.toPremultiplied()
            pm.pixels.withUnsafeBytes { raw in
                t.replace(region: MTLRegionMake2D(0, 0, img.width, img.height), mipmapLevel: 0,
                          withBytes: raw.baseAddress!, bytesPerRow: img.width * 4)
            }
            encoder?.generateMipmaps(for: t)
            textures[id] = t
        }
        encoder?.endEncoding()
        blit?.commit()
    }

    /// Encode draw commands. `canvasToClip` maps canvas coordinates to Metal clip space.
    public func encode(_ commands: [DrawCommand], encoder: MTLRenderCommandEncoder, canvasToClip m: Affine2D) {
        guard !commands.isEmpty else { return }
        // Pack all geometry into one buffer per frame.
        var vertices: [Vertex] = []
        var indices: [UInt32] = []
        struct Range { var vStart: Int; var iStart: Int; var iCount: Int }
        func append(_ positions: [Vec2], _ uvs: [Vec2], _ idx: [UInt32]) -> Range {
            let r = Range(vStart: vertices.count, iStart: indices.count, iCount: idx.count)
            for i in 0..<min(positions.count, uvs.count) { vertices.append(Vertex(position: positions[i], uv: uvs[i])) }
            indices += idx
            return r
        }
        var ranges: [(Range, [Range])] = []
        for c in commands {
            let main = append(c.positions, c.uvs, c.indices)
            let masks = c.masks.map { append($0.positions, $0.uvs, $0.indices) }
            ranges.append((main, masks))
        }
        guard !vertices.isEmpty, !indices.isEmpty,
              let vb = device.makeBuffer(bytes: vertices, length: vertices.count * MemoryLayout<Vertex>.stride),
              let ib = device.makeBuffer(bytes: indices, length: indices.count * 4) else { return }

        var u = Uniforms(col0: SIMD2(m.a, m.b), col1: SIMD2(m.c, m.d), col2: SIMD2(m.tx, m.ty), opacity: 1)
        encoder.setFragmentSamplerState(sampler, index: 0)
        var stencilRef: UInt32 = 0
        for (ci, c) in commands.enumerated() {
            let (main, masks) = ranges[ci]
            guard let tex = textures[c.textureID], main.iCount > 0 else { continue }
            if !masks.isEmpty {
                stencilRef = stencilRef % 255 + 1
                encoder.setRenderPipelineState(maskPipeline)
                encoder.setDepthStencilState(stencilWrite)
                encoder.setStencilReferenceValue(stencilRef)
                for (mi, mr) in masks.enumerated() {
                    guard let mt = textures[c.masks[mi].textureID], mr.iCount > 0 else { continue }
                    u.opacity = 1
                    encoder.setVertexBuffer(vb, offset: mr.vStart * MemoryLayout<Vertex>.stride, index: 0)
                    encoder.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
                    encoder.setFragmentTexture(mt, index: 0)
                    encoder.drawIndexedPrimitives(type: .triangle, indexCount: mr.iCount, indexType: .uint32,
                                                  indexBuffer: ib, indexBufferOffset: mr.iStart * 4)
                }
                encoder.setDepthStencilState(c.invertMask ? stencilNotEqual : stencilEqual)
            } else {
                encoder.setDepthStencilState(stencilOff)
            }
            encoder.setRenderPipelineState(pipelines[c.blendMode]!)
            u.opacity = c.opacity
            encoder.setVertexBuffer(vb, offset: main.vStart * MemoryLayout<Vertex>.stride, index: 0)
            encoder.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
            encoder.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
            encoder.setFragmentTexture(tex, index: 0)
            encoder.drawIndexedPrimitives(type: .triangle, indexCount: main.iCount, indexType: .uint32,
                                          indexBuffer: ib, indexBufferOffset: main.iStart * 4)
        }
    }

    /// Canvas → clip-space transform for a view of `viewSize` points where the
    /// canvas is shown at `canvasToView` (points).
    public static func clipTransform(canvasToView: Affine2D, viewSize: SIMD2<Float>) -> Affine2D {
        let toClip = Affine2D(a: 2 / viewSize.x, b: 0, c: 0, d: -2 / viewSize.y, tx: -1, ty: 1)
        return toClip.concatenating(canvasToView)
    }
}
#endif
