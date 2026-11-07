import Foundation

public enum ByteIOError: Error, CustomStringConvertible {
    case unexpectedEnd(offset: Int, needed: Int)
    case invalid(String)
    public var description: String {
        switch self {
        case let .unexpectedEnd(o, n): return "Unexpected end of data at offset \(o) (needed \(n) bytes)"
        case let .invalid(m): return m
        }
    }
}

/// Cursor over a byte array with big- and little-endian readers.
public struct ByteReader {
    public let bytes: [UInt8]
    public var offset: Int
    public let bigEndian: Bool

    public init(_ bytes: [UInt8], bigEndian: Bool = true, offset: Int = 0) {
        self.bytes = bytes; self.bigEndian = bigEndian; self.offset = offset
    }
    public init(_ data: Data, bigEndian: Bool = true) { self.init([UInt8](data), bigEndian: bigEndian) }

    public var remaining: Int { bytes.count - offset }
    public var isAtEnd: Bool { offset >= bytes.count }

    @inline(__always) mutating func need(_ n: Int) throws {
        if n < 0 || offset + n > bytes.count { throw ByteIOError.unexpectedEnd(offset: offset, needed: n) }
    }

    public mutating func u8() throws -> UInt8 { try need(1); defer { offset += 1 }; return bytes[offset] }
    public mutating func i8() throws -> Int8 { Int8(bitPattern: try u8()) }

    public mutating func u16() throws -> UInt16 {
        try need(2); defer { offset += 2 }
        let a = UInt16(bytes[offset]), b = UInt16(bytes[offset + 1])
        return bigEndian ? (a << 8 | b) : (b << 8 | a)
    }
    public mutating func i16() throws -> Int16 { Int16(bitPattern: try u16()) }

    public mutating func u32() throws -> UInt32 {
        try need(4); defer { offset += 4 }
        var v: UInt32 = 0
        if bigEndian { for i in 0..<4 { v = v << 8 | UInt32(bytes[offset + i]) } }
        else { for i in (0..<4).reversed() { v = v << 8 | UInt32(bytes[offset + i]) } }
        return v
    }
    public mutating func i32() throws -> Int32 { Int32(bitPattern: try u32()) }

    public mutating func u64() throws -> UInt64 {
        try need(8); defer { offset += 8 }
        var v: UInt64 = 0
        if bigEndian { for i in 0..<8 { v = v << 8 | UInt64(bytes[offset + i]) } }
        else { for i in (0..<8).reversed() { v = v << 8 | UInt64(bytes[offset + i]) } }
        return v
    }
    public mutating func f32() throws -> Float { Float(bitPattern: try u32()) }

    public mutating func bytes(_ n: Int) throws -> ArraySlice<UInt8> {
        try need(n); defer { offset += n }
        return bytes[offset..<offset + n]
    }
    public mutating func skip(_ n: Int) throws { try need(n); offset += n }
    public mutating func ascii(_ n: Int) throws -> String { String(decoding: try bytes(n), as: UTF8.self) }
    public mutating func string() throws -> String {
        let n = Int(try u32())
        return String(decoding: try bytes(n), as: UTF8.self)
    }
}

/// Growable byte buffer with big- and little-endian writers.
public struct ByteWriter {
    public private(set) var bytes: [UInt8] = []
    public let bigEndian: Bool
    public init(bigEndian: Bool = true) { self.bigEndian = bigEndian }

    public var count: Int { bytes.count }
    public var data: Data { Data(bytes) }

    public mutating func u8(_ v: UInt8) { bytes.append(v) }
    public mutating func u16(_ v: UInt16) {
        if bigEndian { bytes += [UInt8(v >> 8), UInt8(v & 0xff)] } else { bytes += [UInt8(v & 0xff), UInt8(v >> 8)] }
    }
    public mutating func i16(_ v: Int16) { u16(UInt16(bitPattern: v)) }
    public mutating func u32(_ v: UInt32) {
        let b = [UInt8(v >> 24), UInt8(v >> 16 & 0xff), UInt8(v >> 8 & 0xff), UInt8(v & 0xff)]
        bytes += bigEndian ? b : b.reversed()
    }
    public mutating func i32(_ v: Int32) { u32(UInt32(bitPattern: v)) }
    public mutating func u64(_ v: UInt64) {
        var b = [UInt8](repeating: 0, count: 8)
        for i in 0..<8 { b[i] = UInt8(v >> (56 - 8 * UInt64(i)) & 0xff) }
        bytes += bigEndian ? b : b.reversed()
    }
    public mutating func f32(_ v: Float) { u32(v.bitPattern) }
    public mutating func append<S: Sequence>(_ s: S) where S.Element == UInt8 { bytes.append(contentsOf: s) }
    public mutating func ascii(_ s: String) { bytes.append(contentsOf: Array(s.utf8)) }
    public mutating func string(_ s: String) { let u = Array(s.utf8); u32(UInt32(u.count)); bytes += u }
    public mutating func patchU32(at offset: Int, _ v: UInt32) {
        let b = [UInt8(v >> 24), UInt8(v >> 16 & 0xff), UInt8(v >> 8 & 0xff), UInt8(v & 0xff)]
        let o = bigEndian ? b : b.reversed()
        for i in 0..<4 { bytes[offset + i] = o[i] }
    }
}
