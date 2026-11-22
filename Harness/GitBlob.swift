import Foundation

/// Git object hashing without CryptoKit, so the same code runs on Linux.
/// SHA-1 is Git's content address here, not a security primitive of ours:
/// it proves a file's bytes are the bytes the pinned tree names.
public enum GitBlob {
    /// SHA-1 of the Git object `blob <size>\0<bytes>`, as 40 lowercase hex digits.
    public static func sha(_ data: Data) -> String {
        var hash = GitSHA1()
        hash.update(Array("blob \(data.count)\0".utf8))
        data.withUnsafeBytes { hash.update($0.bindMemory(to: UInt8.self)) }
        return hash.finalize()
    }

    public static func sha(_ text: String) -> String { sha(Data(text.utf8)) }

    public static func isSHA(_ value: String) -> Bool {
        value.utf8.count == 40 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}

struct GitSHA1 {
    private var state: [UInt32] = [0x6745_2301, 0xEFCD_AB89, 0x98BA_DCFE, 0x1032_5476, 0xC3D2_E1F0]
    private var buffer = [UInt8]()
    private var length: UInt64 = 0
    private var words = [UInt32](repeating: 0, count: 80)

    init() { buffer.reserveCapacity(64) }

    mutating func update(_ bytes: [UInt8]) {
        bytes.withUnsafeBufferPointer { update($0) }
    }

    mutating func update(_ bytes: UnsafeBufferPointer<UInt8>) {
        length &+= UInt64(bytes.count)
        var offset = 0
        if !buffer.isEmpty {
            let take = min(64 - buffer.count, bytes.count)
            buffer.append(contentsOf: bytes[0..<take])
            offset = take
            if buffer.count == 64 {
                buffer.withUnsafeBufferPointer { block($0.baseAddress!) }
                buffer.removeAll(keepingCapacity: true)
            }
        }
        while bytes.count - offset >= 64 {
            block(bytes.baseAddress! + offset)
            offset += 64
        }
        if offset < bytes.count { buffer.append(contentsOf: bytes[offset..<bytes.count]) }
    }

    mutating func finalize() -> String {
        let bits = length &* 8
        var tail: [UInt8] = [0x80]
        let used = (buffer.count + 1) % 64
        tail.append(contentsOf: [UInt8](repeating: 0, count: used <= 56 ? 56 - used : 120 - used))
        for shift in stride(from: 56, through: 0, by: -8) { tail.append(UInt8((bits >> UInt64(shift)) & 0xFF)) }
        let saved = length
        update(tail)
        length = saved
        return state.map { String(format: "%08x", $0) }.joined()
    }

    private mutating func block(_ pointer: UnsafePointer<UInt8>) {
        for index in 0..<16 {
            let base = index * 4
            words[index] = UInt32(pointer[base]) << 24 | UInt32(pointer[base + 1]) << 16
                | UInt32(pointer[base + 2]) << 8 | UInt32(pointer[base + 3])
        }
        for index in 16..<80 {
            let value = words[index - 3] ^ words[index - 8] ^ words[index - 14] ^ words[index - 16]
            words[index] = value << 1 | value >> 31
        }
        var a = state[0], b = state[1], c = state[2], d = state[3], e = state[4]
        for index in 0..<80 {
            let function: UInt32, constant: UInt32
            switch index {
            case 0..<20: function = (b & c) | (~b & d); constant = 0x5A82_7999
            case 20..<40: function = b ^ c ^ d; constant = 0x6ED9_EBA1
            case 40..<60: function = (b & c) | (b & d) | (c & d); constant = 0x8F1B_BCDC
            default: function = b ^ c ^ d; constant = 0xCA62_C1D6
            }
            let next = (a << 5 | a >> 27) &+ function &+ e &+ constant &+ words[index]
            e = d; d = c; c = b << 30 | b >> 2; b = a; a = next
        }
        state[0] &+= a; state[1] &+= b; state[2] &+= c; state[3] &+= d; state[4] &+= e
    }
}
