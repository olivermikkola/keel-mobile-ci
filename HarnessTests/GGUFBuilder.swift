import Foundation

/// Writes GGUF header bytes for tests: magic, version, counts, then typed
/// metadata entries, little-endian as llama.cpp writes them.
struct GGUFBuilder {
    var data = Data()

    init(version: UInt32 = 3, tensorCount: UInt64 = 291, metadataCount: UInt64) {
        data.append(contentsOf: [0x47, 0x47, 0x55, 0x46]) // "GGUF"
        appendUInt32(version)
        appendUInt64(tensorCount)
        appendUInt64(metadataCount)
    }

    mutating func appendUInt8(_ v: UInt8) {
        data.append(v)
    }

    mutating func appendUInt32(_ v: UInt32) {
        var le = v.littleEndian
        withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
    }

    mutating func appendInt32(_ v: Int32) {
        appendUInt32(UInt32(bitPattern: v))
    }

    mutating func appendUInt64(_ v: UInt64) {
        var le = v.littleEndian
        withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
    }

    mutating func appendRawString(_ s: String) {
        let utf8 = Array(s.utf8)
        appendUInt64(UInt64(utf8.count))
        data.append(contentsOf: utf8)
    }

    mutating func addString(_ key: String, _ value: String) {
        appendRawString(key)
        appendUInt32(8) // GGUF_TYPE_STRING
        appendRawString(value)
    }

    mutating func addUInt32(_ key: String, _ value: UInt32) {
        appendRawString(key)
        appendUInt32(4) // GGUF_TYPE_UINT32
        appendUInt32(value)
    }

    mutating func addInt32(_ key: String, _ value: Int32) {
        appendRawString(key)
        appendUInt32(5) // GGUF_TYPE_INT32
        appendInt32(value)
    }

    mutating func addUInt64(_ key: String, _ value: UInt64) {
        appendRawString(key)
        appendUInt32(10) // GGUF_TYPE_UINT64
        appendUInt64(value)
    }

    mutating func addUInt32Array(_ key: String, _ values: [UInt32]) {
        appendRawString(key)
        appendUInt32(9) // GGUF_TYPE_ARRAY
        appendUInt32(4) // element type UINT32
        appendUInt64(UInt64(values.count))
        for v in values { appendUInt32(v) }
    }
}
