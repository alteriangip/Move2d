/// DEFLATE (RFC 1951) decoder plus zlib (RFC 1950) wrapper.
/// Used for PNG decoding and ZIP-compressed PSD channels.
public enum InflateError: Error { case invalidData(String) }

public enum Inflate {
    /// Decompress a zlib stream (2-byte header, deflate data, Adler-32).
    public static func zlib<C: Collection>(_ input: C, expectedSize: Int? = nil) throws -> [UInt8] where C.Element == UInt8 {
        let bytes = Array(input)
        guard bytes.count >= 2 else { throw InflateError.invalidData("zlib stream too short") }
        let cmf = bytes[0], flg = bytes[1]
        guard cmf & 0x0f == 8, (UInt16(cmf) << 8 | UInt16(flg)) % 31 == 0 else {
            throw InflateError.invalidData("bad zlib header")
        }
        guard flg & 0x20 == 0 else { throw InflateError.invalidData("zlib preset dictionary unsupported") }
        return try raw(bytes, start: 2, expectedSize: expectedSize)
    }

    /// Decompress raw deflate data.
    public static func raw(_ bytes: [UInt8], start: Int = 0, expectedSize: Int? = nil) throws -> [UInt8] {
        var s = State(input: bytes, pos: start)
        if let e = expectedSize { s.out.reserveCapacity(e) }
        var final = false
        while !final {
            final = try s.bits(1) == 1
            switch try s.bits(2) {
            case 0: try s.stored()
            case 1: try s.block(lit: fixedLit, dist: fixedDist)
            case 2:
                let (l, d) = try s.dynamicTables()
                try s.block(lit: l, dist: d)
            default: throw InflateError.invalidData("invalid block type")
            }
        }
        return s.out
    }

    struct Huffman {
        var counts = [UInt16](repeating: 0, count: 16)
        var symbols: [UInt16]
        init(lengths: [UInt8]) {
            symbols = [UInt16](repeating: 0, count: lengths.count)
            for l in lengths { counts[Int(l)] += 1 }
            counts[0] = 0
            var offs = [UInt16](repeating: 0, count: 16)
            for i in 1..<16 { offs[i] = offs[i - 1] + counts[i - 1] }
            for (sym, l) in lengths.enumerated() where l != 0 {
                symbols[Int(offs[Int(l)])] = UInt16(sym); offs[Int(l)] += 1
            }
        }
    }

    static let fixedLit: Huffman = {
        var l = [UInt8](repeating: 8, count: 288)
        for i in 144..<256 { l[i] = 9 }
        for i in 256..<280 { l[i] = 7 }
        return Huffman(lengths: l)
    }()
    static let fixedDist = Huffman(lengths: [UInt8](repeating: 5, count: 30))

    static let lenBase: [Int] = [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258]
    static let lenExtra: [Int] = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0]
    static let distBase: [Int] = [1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577]
    static let distExtra: [Int] = [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13]

    struct State {
        let input: [UInt8]
        var pos: Int
        var bitBuf: UInt32 = 0
        var bitCnt: Int = 0
        var out: [UInt8] = []

        init(input: [UInt8], pos: Int) { self.input = input; self.pos = pos }

        @inline(__always) mutating func bits(_ n: Int) throws -> Int {
            while bitCnt < n {
                guard pos < input.count else { throw InflateError.invalidData("unexpected end of stream") }
                bitBuf |= UInt32(input[pos]) << UInt32(bitCnt)
                pos += 1; bitCnt += 8
            }
            let v = Int(bitBuf & ((1 << UInt32(n)) - 1))
            bitBuf >>= UInt32(n); bitCnt -= n
            return v
        }

        @inline(__always) mutating func decode(_ h: Huffman) throws -> Int {
            var code = 0, first = 0, index = 0
            for len in 1..<16 {
                code |= try bits(1)
                let count = Int(h.counts[len])
                if code - count < first { return Int(h.symbols[index + (code - first)]) }
                index += count; first += count
                first <<= 1; code <<= 1
            }
            throw InflateError.invalidData("bad huffman code")
        }

        mutating func stored() throws {
            bitBuf = 0; bitCnt = 0
            guard pos + 4 <= input.count else { throw InflateError.invalidData("truncated stored block") }
            let len = Int(input[pos]) | Int(input[pos + 1]) << 8
            let nlen = Int(input[pos + 2]) | Int(input[pos + 3]) << 8
            guard len == (~nlen & 0xffff) else { throw InflateError.invalidData("stored block length mismatch") }
            pos += 4
            guard pos + len <= input.count else { throw InflateError.invalidData("truncated stored block") }
            out.append(contentsOf: input[pos..<pos + len]); pos += len
        }

        mutating func block(lit: Huffman, dist: Huffman) throws {
            while true {
                let sym = try decode(lit)
                if sym < 256 { out.append(UInt8(sym)); continue }
                if sym == 256 { return }
                let li = sym - 257
                guard li < 29 else { throw InflateError.invalidData("bad length symbol") }
                let length = Inflate.lenBase[li] + (try bits(Inflate.lenExtra[li]))
                let ds = try decode(dist)
                guard ds < 30 else { throw InflateError.invalidData("bad distance symbol") }
                let d = Inflate.distBase[ds] + (try bits(Inflate.distExtra[ds]))
                guard d <= out.count else { throw InflateError.invalidData("distance too far back") }
                let startIdx = out.count - d
                if d >= length {
                    out.append(contentsOf: out[startIdx..<startIdx + length])
                } else {
                    for i in 0..<length { out.append(out[startIdx + i]) }
                }
            }
        }

        mutating func dynamicTables() throws -> (Huffman, Huffman) {
            let hlit = try bits(5) + 257, hdist = try bits(5) + 1, hclen = try bits(4) + 4
            let order = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]
            var cl = [UInt8](repeating: 0, count: 19)
            for i in 0..<hclen { cl[order[i]] = UInt8(try bits(3)) }
            let clh = Huffman(lengths: cl)
            var lengths: [UInt8] = []
            lengths.reserveCapacity(hlit + hdist)
            while lengths.count < hlit + hdist {
                let sym = try decode(clh)
                switch sym {
                case 0..<16: lengths.append(UInt8(sym))
                case 16:
                    guard let prev = lengths.last else { throw InflateError.invalidData("repeat with no previous length") }
                    lengths += [UInt8](repeating: prev, count: 3 + (try bits(2)))
                case 17: lengths += [UInt8](repeating: 0, count: 3 + (try bits(3)))
                default: lengths += [UInt8](repeating: 0, count: 11 + (try bits(7)))
                }
            }
            guard lengths.count == hlit + hdist else { throw InflateError.invalidData("code lengths overflow") }
            return (Huffman(lengths: Array(lengths[0..<hlit])), Huffman(lengths: Array(lengths[hlit...])))
        }
    }
}
