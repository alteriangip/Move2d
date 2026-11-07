public enum CRC32 {
    static let table: [UInt32] = (0..<256).map { n -> UInt32 in
        var c = UInt32(n)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }
    public static func update<C: Collection>(_ crc: UInt32, _ bytes: C) -> UInt32 where C.Element == UInt8 {
        var c = crc ^ 0xFFFF_FFFF
        for b in bytes { c = table[Int((c ^ UInt32(b)) & 0xff)] ^ (c >> 8) }
        return c ^ 0xFFFF_FFFF
    }
    public static func checksum<C: Collection>(_ bytes: C) -> UInt32 where C.Element == UInt8 { update(0, bytes) }
}

public enum Adler32 {
    public static func checksum<C: Collection>(_ bytes: C) -> UInt32 where C.Element == UInt8 {
        var a: UInt32 = 1, b: UInt32 = 0
        var n = 0
        for byte in bytes {
            a += UInt32(byte); b += a
            n += 1
            if n == 5552 { a %= 65521; b %= 65521; n = 0 }
        }
        return (b % 65521) << 16 | (a % 65521)
    }
}
