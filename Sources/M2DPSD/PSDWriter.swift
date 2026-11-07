import M2DCore

/// Minimal layered PSD writer (8-bit RGB, RLE). Used for round-trip tests,
/// sample generation and "export layers back to Photoshop".
public enum PSDWriter {
    public static func write(_ doc: PSDDocument) -> [UInt8] {
        var w = ByteWriter()
        w.ascii("8BPS"); w.u16(1); w.append([0, 0, 0, 0, 0, 0])
        w.u16(4); w.u32(UInt32(doc.height)); w.u32(UInt32(doc.width)); w.u16(8); w.u16(3)
        w.u32(0) // color mode data
        w.u32(0) // image resources

        // Flatten tree to bottom-to-top records with section dividers.
        var records: [(PSDLayer, Int)] = []
        func emit(_ layers: [PSDLayer]) {
            for l in layers.reversed() {
                if l.kind == .group {
                    records.append((PSDLayer(kind: .group, name: "</Layer group>"), 3))
                    emit(l.children)
                    records.append((l, l.collapsed ? 2 : 1))
                } else {
                    records.append((l, 0))
                }
            }
        }
        emit(doc.layers)

        var info = ByteWriter()
        info.i16(Int16(-records.count))
        var channelData: [[[UInt8]]] = []
        for (layer, section) in records {
            let img = section == 0 ? layer.image : nil
            let (t, l) = img == nil ? (0, 0) : (layer.top, layer.left)
            let (b, r) = img == nil ? (0, 0) : (layer.top + layer.height, layer.left + layer.width)
            info.i32(Int32(t)); info.i32(Int32(l)); info.i32(Int32(b)); info.i32(Int32(r))
            var chans: [[UInt8]] = []
            let ids: [Int16] = [-1, 0, 1, 2]
            for (ci, _) in ids.enumerated() {
                var cw = ByteWriter()
                if let img {
                    let srcChannel = ci == 0 ? 3 : ci - 1
                    var rows: [[UInt8]] = []
                    for y in 0..<img.height {
                        var row = [UInt8](repeating: 0, count: img.width)
                        for x in 0..<img.width { row[x] = img.pixels[(y * img.width + x) * 4 + srcChannel] }
                        rows.append(PackBits.encode(row[...]))
                    }
                    cw.u16(1)
                    for r in rows { cw.u16(UInt16(r.count)) }
                    for r in rows { cw.append(r) }
                } else {
                    cw.u16(0)
                }
                chans.append(cw.bytes)
            }
            info.u16(4)
            for (i, id) in ids.enumerated() { info.i16(id); info.u32(UInt32(chans[i].count)) }
            channelData.append(chans)
            info.ascii("8BIM")
            info.ascii(section == 0 || section == 3 ? (section == 3 ? "norm" : layer.blendMode.rawValue) : "pass")
            info.u8(UInt8(clamp(layer.opacity, 0, 1) * 255 + 0.5))
            info.u8(layer.clipped ? 1 : 0)
            info.u8(layer.visible ? 0x08 : 0x0A)
            info.u8(0)
            var extra = ByteWriter()
            extra.u32(0) // mask
            extra.u32(0) // blending ranges
            let ascii = Array(layer.name.utf8.map { $0 < 128 ? $0 : 63 }.prefix(255))
            extra.u8(UInt8(ascii.count)); extra.append(ascii)
            let padTo = (ascii.count + 1 + 3) & ~3
            extra.append([UInt8](repeating: 0, count: padTo - ascii.count - 1))
            // Unicode name
            var luni = ByteWriter()
            let u16 = Array(layer.name.utf16)
            luni.u32(UInt32(u16.count)); for u in u16 { luni.u16(u) }
            if luni.count % 4 != 0 { luni.append([UInt8](repeating: 0, count: 4 - luni.count % 4)) }
            extra.ascii("8BIM"); extra.ascii("luni"); extra.u32(UInt32(luni.count)); extra.append(luni.bytes)
            if section != 0 {
                extra.ascii("8BIM"); extra.ascii("lsct"); extra.u32(4); extra.u32(UInt32(section))
            }
            if let id = layer.layerID {
                extra.ascii("8BIM"); extra.ascii("lyid"); extra.u32(4); extra.u32(UInt32(id))
            }
            info.u32(UInt32(extra.count)); info.append(extra.bytes)
        }
        for chans in channelData { for c in chans { info.append(c) } }
        if info.count % 2 != 0 { info.u8(0) }

        w.u32(UInt32(info.count + 4 + 4))
        w.u32(UInt32(info.count)); w.append(info.bytes)
        w.u32(0) // global mask
        // Merged image: raw, blank.
        w.u16(0)
        w.append([UInt8](repeating: 0, count: doc.width * doc.height * 4))
        return w.bytes
    }
}
