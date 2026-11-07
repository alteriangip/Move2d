import Foundation

/// An 8-bit RGBA bitmap stored row-major, top-left origin.
/// `premultiplied` records whether colour channels are multiplied by alpha.
public struct RGBAImage: Hashable, Sendable {
    public var width: Int
    public var height: Int
    public var pixels: [UInt8]
    public var premultiplied: Bool

    public init(width: Int, height: Int, pixels: [UInt8], premultiplied: Bool = false) {
        precondition(pixels.count == width * height * 4, "pixel buffer size mismatch")
        self.width = width; self.height = height; self.pixels = pixels; self.premultiplied = premultiplied
    }

    public init(width: Int, height: Int, fill: (UInt8, UInt8, UInt8, UInt8) = (0, 0, 0, 0)) {
        self.width = width; self.height = height; premultiplied = false
        pixels = [UInt8](repeating: 0, count: width * height * 4)
        if fill != (0, 0, 0, 0) {
            for i in stride(from: 0, to: pixels.count, by: 4) {
                pixels[i] = fill.0; pixels[i + 1] = fill.1; pixels[i + 2] = fill.2; pixels[i + 3] = fill.3
            }
        }
    }

    @inlinable public func pixel(_ x: Int, _ y: Int) -> (UInt8, UInt8, UInt8, UInt8) {
        let i = (y * width + x) * 4
        return (pixels[i], pixels[i + 1], pixels[i + 2], pixels[i + 3])
    }

    @inlinable public func alpha(_ x: Int, _ y: Int) -> UInt8 { pixels[(y * width + x) * 4 + 3] }

    public func toPremultiplied() -> RGBAImage {
        if premultiplied { return self }
        var out = pixels
        for i in stride(from: 0, to: out.count, by: 4) {
            let a = UInt16(out[i + 3])
            if a == 255 { continue }
            out[i] = UInt8((UInt16(out[i]) * a + 127) / 255)
            out[i + 1] = UInt8((UInt16(out[i + 1]) * a + 127) / 255)
            out[i + 2] = UInt8((UInt16(out[i + 2]) * a + 127) / 255)
        }
        return RGBAImage(width: width, height: height, pixels: out, premultiplied: true)
    }

    public func toStraight() -> RGBAImage {
        if !premultiplied { return self }
        var out = pixels
        for i in stride(from: 0, to: out.count, by: 4) {
            let a = UInt32(out[i + 3])
            if a == 0 || a == 255 { continue }
            out[i] = UInt8(min(255, (UInt32(out[i]) * 255 + a / 2) / a))
            out[i + 1] = UInt8(min(255, (UInt32(out[i + 1]) * 255 + a / 2) / a))
            out[i + 2] = UInt8(min(255, (UInt32(out[i + 2]) * 255 + a / 2) / a))
        }
        return RGBAImage(width: width, height: height, pixels: out, premultiplied: false)
    }

    /// Smallest rectangle containing pixels with alpha > threshold, or nil if fully transparent.
    public func opaqueBounds(threshold: UInt8 = 0) -> (x: Int, y: Int, width: Int, height: Int)? {
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            var row = y * width * 4 + 3
            for x in 0..<width {
                if pixels[row] > threshold {
                    if x < minX { minX = x }
                    if x > maxX { maxX = x }
                    if y < minY { minY = y }
                    if y > maxY { maxY = y }
                }
                row += 4
            }
        }
        guard maxX >= 0 else { return nil }
        return (minX, minY, maxX - minX + 1, maxY - minY + 1)
    }

    public func cropped(x: Int, y: Int, width w: Int, height h: Int) -> RGBAImage {
        var out = [UInt8](repeating: 0, count: w * h * 4)
        for row in 0..<h {
            let sy = y + row
            guard sy >= 0, sy < height else { continue }
            for col in 0..<w {
                let sx = x + col
                guard sx >= 0, sx < width else { continue }
                let s = (sy * width + sx) * 4, d = (row * w + col) * 4
                out[d] = pixels[s]; out[d + 1] = pixels[s + 1]; out[d + 2] = pixels[s + 2]; out[d + 3] = pixels[s + 3]
            }
        }
        return RGBAImage(width: w, height: h, pixels: out, premultiplied: premultiplied)
    }

    /// Bilinear sample in normalized coordinates, returned premultiplied, 0...1.
    @inlinable public func samplePremultiplied(u: Float, v: Float) -> SIMD4<Float> {
        let fx = u * Float(width) - 0.5, fy = v * Float(height) - 0.5
        let x0 = Int(fx.rounded(.down)), y0 = Int(fy.rounded(.down))
        let tx = fx - Float(x0), ty = fy - Float(y0)
        let c00 = texel(x0, y0), c10 = texel(x0 + 1, y0), c01 = texel(x0, y0 + 1), c11 = texel(x0 + 1, y0 + 1)
        let top = c00 + (c10 - c00) * tx
        let bottom = c01 + (c11 - c01) * tx
        return top + (bottom - top) * ty
    }

    /// Texel fetch with clamp-to-edge addressing (matches the GPU sampler).
    @inlinable func texel(_ x: Int, _ y: Int) -> SIMD4<Float> {
        guard width > 0, height > 0 else { return .zero }
        let i = (min(max(y, 0), height - 1) * width + min(max(x, 0), width - 1)) * 4
        let a = Float(pixels[i + 3]) / 255
        let c = SIMD4<Float>(Float(pixels[i]), Float(pixels[i + 1]), Float(pixels[i + 2]), 255) / 255
        if premultiplied { return SIMD4(c.x, c.y, c.z, a) }
        return SIMD4(c.x * a, c.y * a, c.z * a, a)
    }
}
