import M2DCore

/// Photoshop blend modes, by their four-character keys.
public enum PSDBlendMode: String, Codable, Sendable, CaseIterable {
    case passThrough = "pass", normal = "norm", dissolve = "diss", darken = "dark", multiply = "mul ",
         colorBurn = "idiv", linearBurn = "lbrn", darkerColor = "dkCl", lighten = "lite", screen = "scrn",
         colorDodge = "div ", linearDodge = "lddg", lighterColor = "lgCl", overlay = "over", softLight = "sLit",
         hardLight = "hLit", vividLight = "vLit", linearLight = "lLit", pinLight = "pLit", hardMix = "hMix",
         difference = "diff", exclusion = "smud", subtract = "fsub", divide = "fdiv", hue = "hue ",
         saturation = "sat ", color = "colr", luminosity = "lum "
}

/// A node in the PSD layer tree, ordered top-to-bottom like Photoshop's Layers panel.
public struct PSDLayer: Sendable {
    public enum Kind: Sendable { case pixel, group }

    public var kind: Kind
    public var name: String
    /// Photoshop's persistent layer id ('lyid'), when present.
    public var layerID: Int?
    public var visible: Bool
    public var opacity: Float          // 0...1, includes fill opacity
    public var blendMode: PSDBlendMode
    /// True when this layer is a clipping mask onto the layer below it.
    public var clipped: Bool
    /// Pixel bounds in document coordinates (empty for groups / empty layers).
    public var left: Int, top: Int, width: Int, height: Int
    /// Straight-alpha RGBA pixels covering the bounds, with the layer mask applied.
    public var image: RGBAImage?
    /// Group was collapsed in Photoshop.
    public var collapsed: Bool
    public var children: [PSDLayer]

    public init(kind: Kind, name: String, layerID: Int? = nil, visible: Bool = true, opacity: Float = 1,
                blendMode: PSDBlendMode = .normal, clipped: Bool = false,
                left: Int = 0, top: Int = 0, width: Int = 0, height: Int = 0,
                image: RGBAImage? = nil, collapsed: Bool = false, children: [PSDLayer] = []) {
        self.kind = kind; self.name = name; self.layerID = layerID; self.visible = visible; self.opacity = opacity
        self.blendMode = blendMode; self.clipped = clipped
        self.left = left; self.top = top; self.width = width; self.height = height
        self.image = image; self.collapsed = collapsed; self.children = children
    }

    /// All pixel layers in this subtree, top to bottom.
    public var flattenedPixelLayers: [PSDLayer] {
        kind == .pixel ? [self] : children.flatMap(\.flattenedPixelLayers)
    }
}

public struct PSDDocument: Sendable {
    public var width: Int
    public var height: Int
    public var depth: Int
    public var colorMode: Int
    public var isPSB: Bool
    /// Root layers, top to bottom.
    public var layers: [PSDLayer]
    /// Non-fatal issues found during import (unsupported features, skipped data).
    public var warnings: [String]

    public init(width: Int, height: Int, depth: Int = 8, colorMode: Int = 3, isPSB: Bool = false,
                layers: [PSDLayer], warnings: [String] = []) {
        self.width = width; self.height = height; self.depth = depth; self.colorMode = colorMode
        self.isPSB = isPSB; self.layers = layers; self.warnings = warnings
    }

    public var pixelLayerCount: Int { layers.reduce(0) { $0 + $1.flattenedPixelLayers.count } }
}

public enum PSDError: Error, CustomStringConvertible {
    case notPSD, unsupportedVersion(Int), unsupportedColorMode(Int), unsupportedDepth(Int), corrupt(String)
    public var description: String {
        switch self {
        case .notPSD: return "This file is not a Photoshop document."
        case let .unsupportedVersion(v): return "Unsupported PSD version \(v)."
        case let .unsupportedColorMode(m):
            let names = [0: "Bitmap", 2: "Indexed", 4: "CMYK", 7: "Multichannel", 8: "Duotone", 9: "Lab"]
            return "\(names[m] ?? "Color mode \(m)") documents are not supported. Convert the document to RGB in your painting app and export again."
        case let .unsupportedDepth(d): return "Unsupported bit depth \(d)."
        case let .corrupt(m): return "The PSD appears to be damaged: \(m)"
        }
    }
}
