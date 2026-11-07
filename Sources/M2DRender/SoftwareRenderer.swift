import Foundation
import M2DCore
import M2DRig

/// CPU rasteriser producing exactly the same composition rules as the Metal
/// renderer. Used for export, thumbnails, tests and as a fallback.
public final class SoftwareRenderer {
    public private(set) var textures: [ObjectID: RGBAImage] = [:]
    /// Supersampling factor per axis (1 = none, 2 = 4x SSAA).
    public var supersample: Int = 1

    public init() {}

    public func setTexture(_ id: ObjectID, _ image: RGBAImage) { textures[id] = image.toPremultiplied() }
    public func removeTexture(_ id: ObjectID) { textures[id] = nil }

    /// Render to a premultiplied RGBA image.
    /// - transform: canvas → output pixel coordinates.
    /// - background: premultiplied RGBA 0…1 (alpha 0 for transparent output).
    public func render(_ commands: [DrawCommand], width: Int, height: Int, transform: Affine2D = .identity,
                       background: SIMD4<Float> = .zero) -> RGBAImage {
        let ss = max(1, supersample)
        let w = width * ss, h = height * ss
        var buf = [SIMD4<Float>](repeating: background, count: w * h)
        let xf = Affine2D.scale(Float(ss)).concatenating(transform)
        var mask = [Float]()
        for cmd in commands {
            guard let tex = textures[cmd.textureID] else { continue }
            var hasMask = false
            if !cmd.masks.isEmpty {
                hasMask = true
                mask = [Float](repeating: 0, count: w * h)
                for m in cmd.masks {
                    guard let mt = textures[m.textureID] else { continue }
                    rasterize(positions: m.positions.map(xf.apply), uvs: m.uvs, indices: m.indices, width: w, height: h) { i, u, v in
                        let a = mt.samplePremultiplied(u: u, v: v).w
                        mask[i] = max(mask[i], a)
                    }
                }
            }
            let op = cmd.opacity
            let blend = cmd.blendMode
            let invert = cmd.invertMask
            rasterize(positions: cmd.positions.map(xf.apply), uvs: cmd.uvs, indices: cmd.indices, width: w, height: h) { i, u, v in
                var src = tex.samplePremultiplied(u: u, v: v) * op
                if hasMask { src *= invert ? 1 - mask[i] : mask[i] }
                guard src.w > 0.0005 || blend == .additive else { return }
                let dst = buf[i]
                switch blend {
                case .normal: buf[i] = src + dst * (1 - src.w)
                case .additive:
                    buf[i] = SIMD4(min(dst.x + src.x, 1), min(dst.y + src.y, 1), min(dst.z + src.z, 1), min(dst.w + src.w, 1))
                case .multiply:
                    let rgb = SIMD3(src.x, src.y, src.z) * SIMD3(dst.x, dst.y, dst.z)
                        + SIMD3(src.x, src.y, src.z) * (1 - dst.w) + SIMD3(dst.x, dst.y, dst.z) * (1 - src.w)
                    buf[i] = SIMD4(rgb.x, rgb.y, rgb.z, src.w + dst.w * (1 - src.w))
                case .screen:
                    let s3 = SIMD3(src.x, src.y, src.z), d3 = SIMD3(dst.x, dst.y, dst.z)
                    let rgb = s3 + d3 - s3 * d3
                    buf[i] = SIMD4(rgb.x, rgb.y, rgb.z, src.w + dst.w * (1 - src.w))
                }
            }
        }
        // Resolve.
        var px = [UInt8](repeating: 0, count: width * height * 4)
        let inv = 1 / Float(ss * ss)
        for y in 0..<height {
            for x in 0..<width {
                var acc = SIMD4<Float>.zero
                for sy in 0..<ss { for sx in 0..<ss { acc += buf[(y * ss + sy) * w + x * ss + sx] } }
                acc *= inv
                let o = (y * width + x) * 4
                px[o] = UInt8(clamp(acc.x * 255 + 0.5, 0, 255))
                px[o + 1] = UInt8(clamp(acc.y * 255 + 0.5, 0, 255))
                px[o + 2] = UInt8(clamp(acc.z * 255 + 0.5, 0, 255))
                px[o + 3] = UInt8(clamp(acc.w * 255 + 0.5, 0, 255))
            }
        }
        return RGBAImage(width: width, height: height, pixels: px, premultiplied: true)
    }

    @inline(__always) static func ownsEdge(_ d: Vec2) -> Bool { d.y > 0 || (d.y == 0 && d.x < 0) }

    /// Scan-convert triangles, invoking `shade(pixelIndex, u, v)` for covered pixel centres.
    func rasterize(positions: [Vec2], uvs: [Vec2], indices: [UInt32], width: Int, height: Int,
                   shade: (Int, Float, Float) -> Void) {
        let triCount = indices.count / 3
        for t in 0..<triCount {
            let ia = Int(indices[t * 3]), ib = Int(indices[t * 3 + 1]), ic = Int(indices[t * 3 + 2])
            guard ia < positions.count, ib < positions.count, ic < positions.count else { continue }
            let a = positions[ia]
            var b = positions[ib], c = positions[ic]
            var ub = uvs[ib], uc = uvs[ic]
            var area = (b - a).cross(c - a)
            guard abs(area) > 1e-8 else { continue }
            if area < 0 { swap(&b, &c); swap(&ub, &uc); area = -area }
            let minX = max(0, Int(min(a.x, b.x, c.x).rounded(.down)))
            let maxX = min(width - 1, Int(max(a.x, b.x, c.x).rounded(.up)))
            let minY = max(0, Int(min(a.y, b.y, c.y).rounded(.down)))
            let maxY = min(height - 1, Int(max(a.y, b.y, c.y).rounded(.up)))
            guard minX <= maxX, minY <= maxY else { continue }
            let ua = uvs[ia]
            let invArea = 1 / area
            for y in minY...maxY {
                let py = Float(y) + 0.5
                for x in minX...maxX {
                    let p = Vec2(Float(x) + 0.5, py)
                    let w0 = (c - b).cross(p - b) * invArea
                    let w1 = (a - c).cross(p - c) * invArea
                    let w2 = (b - a).cross(p - a) * invArea
                    // Fill rule: pixels exactly on an edge belong to one triangle only.
                    if w0 < 0 || w1 < 0 || w2 < 0 { continue }
                    if w0 == 0 && !Self.ownsEdge(c - b) { continue }
                    if w1 == 0 && !Self.ownsEdge(a - c) { continue }
                    if w2 == 0 && !Self.ownsEdge(b - a) { continue }
                    let uv = ua * w0 + ub * w1 + uc * w2
                    shade(y * width + x, uv.x, uv.y)
                }
            }
        }
    }
}

public extension SoftwareRenderer {
    /// Convenience: evaluate + render a model at given parameter values, fitting the canvas into the output.
    func renderModel(_ model: RigModel, evaluator: RigEvaluator? = nil, values: ParameterValues,
                     width: Int, height: Int, region: Rect? = nil, background: SIMD4<Float> = .zero) -> RGBAImage {
        let ev = evaluator ?? RigEvaluator(model: model)
        let pose = ev.evaluate(values)
        let cmds = RenderListBuilder.build(model: model, pose: pose)
        let r = region ?? model.canvasRect
        let s = min(Float(width) / r.width, Float(height) / r.height)
        let off = Vec2((Float(width) - r.width * s) / 2, (Float(height) - r.height * s) / 2)
        let xf = Affine2D.translation(off).concatenating(.scale(s)).concatenating(.translation(-r.origin))
        return render(cmds, width: width, height: height, transform: xf, background: background)
    }
}
