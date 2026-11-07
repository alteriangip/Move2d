import Foundation
import M2DCore
import M2DPSD

/// Procedurally drawn layered character, used for the "Sample Character"
/// template, tests and demos. Built as a real PSD document so it exercises the
/// same import path as artwork from a painting app.
public enum SampleCharacter {
    struct Canvas {
        var img: RGBAImage
        init(_ w: Int, _ h: Int) { img = RGBAImage(width: w, height: h) }

        mutating func ellipse(cx: Float, cy: Float, rx: Float, ry: Float, color: (UInt8, UInt8, UInt8), alpha: Float = 1) {
            let x0 = max(0, Int(cx - rx - 2)), x1 = min(img.width - 1, Int(cx + rx + 2))
            let y0 = max(0, Int(cy - ry - 2)), y1 = min(img.height - 1, Int(cy + ry + 2))
            guard x0 <= x1, y0 <= y1 else { return }
            for y in y0...y1 { for x in x0...x1 {
                let dx = (Float(x) + 0.5 - cx) / rx, dy = (Float(y) + 0.5 - cy) / ry
                let d = (dx * dx + dy * dy).squareRoot()
                let edge = clamp((1 - d) * min(rx, ry), 0, 1) * alpha
                guard edge > 0 else { continue }
                over(x, y, color, edge)
            }}
        }

        mutating func rect(x: Float, y: Float, w: Float, h: Float, color: (UInt8, UInt8, UInt8), radius: Float = 0) {
            for py in max(0, Int(y))..<min(img.height, Int(y + h)) {
                for px in max(0, Int(x))..<min(img.width, Int(x + w)) {
                    var a: Float = 1
                    if radius > 0 {
                        let cx = clamp(Float(px) + 0.5, x + radius, x + w - radius), cy = clamp(Float(py) + 0.5, y + radius, y + h - radius)
                        let d = Vec2(Float(px) + 0.5 - cx, Float(py) + 0.5 - cy).length
                        a = clamp(radius - d + 0.5, 0, 1)
                    }
                    if a > 0 { over(px, py, color, a) }
                }
            }
        }

        mutating func over(_ x: Int, _ y: Int, _ c: (UInt8, UInt8, UInt8), _ a: Float) {
            let i = (y * img.width + x) * 4
            let da = Float(img.pixels[i + 3]) / 255
            let oa = a + da * (1 - a)
            guard oa > 0 else { return }
            func mix(_ s: UInt8, _ d: UInt8) -> UInt8 { UInt8(clamp((Float(s) * a + Float(d) * da * (1 - a)) / oa, 0, 255)) }
            img.pixels[i] = mix(c.0, img.pixels[i]); img.pixels[i + 1] = mix(c.1, img.pixels[i + 1]); img.pixels[i + 2] = mix(c.2, img.pixels[i + 2])
            img.pixels[i + 3] = UInt8(clamp(oa * 255, 0, 255))
        }
    }

    static var nextID = 100

    static func layer(_ name: String, _ w: Int, _ h: Int, _ draw: (inout Canvas) -> Void) -> PSDLayer {
        var c = Canvas(w, h)
        draw(&c)
        nextID += 1
        return PSDLayer(kind: .pixel, name: name, layerID: nextID, left: 0, top: 0, width: w, height: h, image: c.img)
    }

    /// A 1024×1024 character with head, eyes, mouth, brows, hair and body in groups.
    public static func document(size: Int = 1024) -> PSDDocument {
        nextID = 100
        let s = Float(size) / 1024
        let W = size, H = size
        let skin: (UInt8, UInt8, UInt8) = (252, 226, 208)
        let hair: (UInt8, UInt8, UInt8) = (86, 72, 160)
        let hairDark: (UInt8, UInt8, UInt8) = (60, 48, 120)
        let eyeWhite: (UInt8, UInt8, UInt8) = (255, 255, 255)
        let iris: (UInt8, UInt8, UInt8) = (60, 150, 210)

        let hairBack = layer("Hair Back", W, H) { c in
            c.ellipse(cx: 512 * s, cy: 420 * s, rx: 230 * s, ry: 250 * s, color: hairDark)
            c.rect(x: 290 * s, y: 420 * s, w: 444 * s, h: 330 * s, color: hairDark, radius: 60 * s)
        }
        let body = layer("Body", W, H) { c in
            c.rect(x: 470 * s, y: 600 * s, w: 84 * s, h: 80 * s, color: skin)
            c.rect(x: 340 * s, y: 660 * s, w: 344 * s, h: 360 * s, color: (230, 90, 110), radius: 80 * s)
            c.rect(x: 470 * s, y: 660 * s, w: 84 * s, h: 50 * s, color: (255, 255, 255), radius: 20 * s)
        }
        let face = layer("Face", W, H) { c in c.ellipse(cx: 512 * s, cy: 430 * s, rx: 180 * s, ry: 200 * s, color: skin) }
        let blush = layer("Blush", W, H) { c in
            c.ellipse(cx: 420 * s, cy: 500 * s, rx: 34 * s, ry: 16 * s, color: (255, 150, 160), alpha: 0.6)
            c.ellipse(cx: 604 * s, cy: 500 * s, rx: 34 * s, ry: 16 * s, color: (255, 150, 160), alpha: 0.6)
        }
        func eye(_ name: String, _ cx: Float) -> PSDLayer {
            PSDLayer(kind: .group, name: name, children: [
                layer("\(name) Iris", W, H) { c in
                    c.ellipse(cx: cx * s, cy: 445 * s, rx: 26 * s, ry: 34 * s, color: iris)
                    c.ellipse(cx: cx * s, cy: 445 * s, rx: 12 * s, ry: 16 * s, color: (20, 40, 80))
                    c.ellipse(cx: (cx - 8) * s, cy: 433 * s, rx: 7 * s, ry: 7 * s, color: (255, 255, 255))
                },
                layer("\(name) White", W, H) { c in c.ellipse(cx: cx * s, cy: 445 * s, rx: 44 * s, ry: 38 * s, color: eyeWhite) },
            ])
        }
        var eyeL = eye("Eye L", 440), eyeR = eye("Eye R", 584)
        // Iris is clipped to the eye white, like a typical PSD setup.
        eyeL.children[0].clipped = true; eyeR.children[0].clipped = true
        let lashes = layer("Eyelashes", W, H) { c in
            c.rect(x: 392 * s, y: 400 * s, w: 96 * s, h: 9 * s, color: (40, 30, 60), radius: 4 * s)
            c.rect(x: 536 * s, y: 400 * s, w: 96 * s, h: 9 * s, color: (40, 30, 60), radius: 4 * s)
        }
        let brows = PSDLayer(kind: .group, name: "Brows", children: [
            layer("Brow L", W, H) { c in c.rect(x: 400 * s, y: 368 * s, w: 80 * s, h: 10 * s, color: hairDark, radius: 5 * s) },
            layer("Brow R", W, H) { c in c.rect(x: 544 * s, y: 368 * s, w: 80 * s, h: 10 * s, color: hairDark, radius: 5 * s) },
        ])
        let mouth = layer("Mouth", W, H) { c in
            c.ellipse(cx: 512 * s, cy: 545 * s, rx: 30 * s, ry: 12 * s, color: (190, 70, 90))
        }
        let hairFront = layer("Hair Front", W, H) { c in
            c.ellipse(cx: 512 * s, cy: 300 * s, rx: 200 * s, ry: 110 * s, color: hair)
            c.ellipse(cx: 360 * s, cy: 400 * s, rx: 50 * s, ry: 140 * s, color: hair)
            c.ellipse(cx: 664 * s, cy: 400 * s, rx: 50 * s, ry: 140 * s, color: hair)
        }
        let head = PSDLayer(kind: .group, name: "Head", children: [hairFront, mouth, brows, lashes, eyeR, eyeL, blush, face])
        return PSDDocument(width: W, height: H, depth: 8, colorMode: 3, isPSB: false,
                           layers: [head, body, hairBack], warnings: [])
    }

    /// The sample as PSD file bytes.
    public static func psdData(size: Int = 1024) -> [UInt8] { PSDWriter.write(document(size: size)) }
}
