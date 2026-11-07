import Foundation
import CoreGraphics
import M2DCore

private let thumbnailCache = NSCacheBox()

final class NSCacheBox {
    private var storage: [Int: CGImage] = [:]
    func get(_ k: Int) -> CGImage? { storage[k] }
    func set(_ k: Int, _ v: CGImage) { if storage.count > 400 { storage.removeAll() }; storage[k] = v }
}

extension RGBAImage {
    /// Straight-alpha RGBA → CGImage.
    func cgImage() -> CGImage? {
        let img = toPremultiplied()
        guard let provider = CGDataProvider(data: Data(img.pixels) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    /// Small cached thumbnail for list rows.
    func thumbnailCGImage(maxSize: Int) -> CGImage? {
        var h = Hasher(); h.combine(width); h.combine(height); h.combine(pixels.count)
        // Sample a few pixels for a cheap content key.
        for i in stride(from: 3, to: pixels.count, by: max(4, pixels.count / 64 / 4 * 4)) { h.combine(pixels[i]) }
        let key = h.finalize() ^ maxSize
        if let c = thumbnailCache.get(key) { return c }
        let s = Float(maxSize) / Float(max(width, height))
        let w = max(1, Int(Float(width) * min(1, s))), hh = max(1, Int(Float(height) * min(1, s)))
        var px = [UInt8](repeating: 0, count: w * hh * 4)
        let pm = toPremultiplied()
        for y in 0..<hh { for x in 0..<w {
            let c = pm.samplePremultiplied(u: (Float(x) + 0.5) / Float(w), v: (Float(y) + 0.5) / Float(hh))
            let o = (y * w + x) * 4
            px[o] = UInt8(min(255, c.x * 255)); px[o + 1] = UInt8(min(255, c.y * 255)); px[o + 2] = UInt8(min(255, c.z * 255)); px[o + 3] = UInt8(min(255, c.w * 255))
        }}
        let small = RGBAImage(width: w, height: hh, pixels: px, premultiplied: true)
        guard let cg = small.cgImage() else { return nil }
        thumbnailCache.set(key, cg)
        return cg
    }
}
