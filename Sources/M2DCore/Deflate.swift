/// DEFLATE encoder: LZ77 with hash chains, emitted with the fixed Huffman code.
/// Not as tight as zlib level 9 but small, dependency free and fast enough for
/// texture and frame export.
public enum Deflate {
    public static func zlib(_ input: [UInt8]) -> [UInt8] {
        var out: [UInt8] = [0x78, 0x9c]
        out += raw(input)
        let a = Adler32.checksum(input)
        out += [UInt8(a >> 24), UInt8(a >> 16 & 0xff), UInt8(a >> 8 & 0xff), UInt8(a & 0xff)]
        return out
    }

    struct BitWriter {
        var out: [UInt8] = []
        var buf: UInt32 = 0
        var cnt: UInt32 = 0
        @inline(__always) mutating func write(_ value: UInt32, _ n: UInt32) {
            buf |= value << cnt; cnt += n
            while cnt >= 8 { out.append(UInt8(buf & 0xff)); buf >>= 8; cnt -= 8 }
        }
        /// Huffman codes are written most-significant bit first.
        @inline(__always) mutating func writeCode(_ code: UInt32, _ n: UInt32) {
            var rev: UInt32 = 0, c = code
            for _ in 0..<n { rev = rev << 1 | (c & 1); c >>= 1 }
            write(rev, n)
        }
        mutating func flush() { if cnt > 0 { out.append(UInt8(buf & 0xff)); buf = 0; cnt = 0 } }
    }

    @inline(__always) static func writeLiteral(_ w: inout BitWriter, _ sym: Int) {
        switch sym {
        case 0..<144: w.writeCode(UInt32(0x30 + sym), 8)
        case 144..<256: w.writeCode(UInt32(0x190 + sym - 144), 9)
        case 256..<280: w.writeCode(UInt32(sym - 256), 7)
        default: w.writeCode(UInt32(0xC0 + sym - 280), 8)
        }
    }

    static func writeMatch(_ w: inout BitWriter, length: Int, distance: Int) {
        var li = 28
        while Inflate.lenBase[li] > length { li -= 1 }
        writeLiteral(&w, 257 + li)
        if Inflate.lenExtra[li] > 0 { w.write(UInt32(length - Inflate.lenBase[li]), UInt32(Inflate.lenExtra[li])) }
        var di = 29
        while Inflate.distBase[di] > distance { di -= 1 }
        w.writeCode(UInt32(di), 5)
        if Inflate.distExtra[di] > 0 { w.write(UInt32(distance - Inflate.distBase[di]), UInt32(Inflate.distExtra[di])) }
    }

    public static func raw(_ input: [UInt8]) -> [UInt8] {
        var w = BitWriter()
        w.out.reserveCapacity(input.count / 2 + 16)
        w.write(1, 1) // final block
        w.write(1, 2) // fixed Huffman
        let n = input.count
        let hashBits = 15, hashSize = 1 << hashBits, window = 32768, maxChain = 32
        var head = [Int32](repeating: -1, count: hashSize)
        var prev = [Int32](repeating: -1, count: window)
        @inline(__always) func hash(_ i: Int) -> Int {
            ((Int(input[i]) << 10) ^ (Int(input[i + 1]) << 5) ^ Int(input[i + 2])) & (hashSize - 1)
        }
        @inline(__always) func insert(_ i: Int) {
            let h = hash(i)
            prev[i & (window - 1)] = head[h]
            head[h] = Int32(i)
        }
        var i = 0
        while i < n {
            var bestLen = 0, bestDist = 0
            if i + 2 < n {
                var cand = Int(head[hash(i)])
                var chain = 0
                let maxLen = min(258, n - i)
                while cand >= 0, i - cand <= window - 1, chain < maxChain {
                    if input[cand + bestLen] == input[i + bestLen] || bestLen == 0 {
                        var l = 0
                        while l < maxLen, input[cand + l] == input[i + l] { l += 1 }
                        if l > bestLen { bestLen = l; bestDist = i - cand; if l == maxLen { break } }
                    }
                    let p = Int(prev[cand & (window - 1)])
                    if p >= cand { break }
                    cand = p; chain += 1
                }
                insert(i)
            }
            if bestLen >= 3 {
                writeMatch(&w, length: bestLen, distance: bestDist)
                var k = 1
                while k < bestLen { if i + k + 2 < n { insert(i + k) }; k += 1 }
                i += bestLen
            } else {
                writeLiteral(&w, Int(input[i])); i += 1
            }
        }
        writeLiteral(&w, 256)
        w.flush()
        return w.out
    }
}
