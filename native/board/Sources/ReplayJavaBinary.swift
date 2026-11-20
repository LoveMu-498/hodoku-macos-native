// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

enum ReplayJavaError: LocalizedError {
    case invalid, version, conversion, windows

    var errorDescription: String? {
        switch self {
        case .invalid: return "Java 回放的数据不完整或无效。"
        case .version: return "此 Java 回放版本不受支持。"
        case .windows: return "旧 Windows V3 无法完整表示此回放。请使用原样另存或 FRAME 格式。"
        case .conversion: return "这些帧包含 Java V3 无法完整保存的内容。请使用 FRAME 格式。"
        }
    }
}

// DataInputStream's writeUTF counts modified UTF-8 bytes of UTF-16 code units,
// including the two-byte representation of NUL and six bytes per surrogate pair.
struct ReplayJavaInput {
    let data: Data
    var offset = 0
    var remaining: Int { data.count - offset }

    mutating func byte() throws -> UInt8 {
        guard remaining > 0 else { throw ReplayJavaError.invalid }
        defer { offset += 1 }
        return data[data.startIndex + offset]
    }
    mutating func number(_ width: Int) throws -> UInt64 {
        guard remaining >= width else { throw ReplayJavaError.invalid }
        var value: UInt64 = 0
        for _ in 0..<width { value = try (value << 8) | UInt64(byte()) }
        return value
    }
    mutating func boolean() throws -> Bool { try byte() != 0 }
    mutating func int() throws -> Int { Int(Int32(bitPattern: UInt32(try number(4)))) }
    mutating func long() throws -> Int64 { Int64(bitPattern: try number(8)) }
    mutating func count(_ limit: Int) throws -> Int {
        let n = try int()
        guard (0...limit).contains(n) else { throw ReplayJavaError.invalid }
        return n
    }
    mutating func bytes(_ size: Int) throws -> Data {
        guard size >= 0, size <= remaining else { throw ReplayJavaError.invalid }
        let start = data.startIndex + offset
        offset += size
        return data[start..<start + size]
    }
    mutating func blob() throws -> Data { try bytes(count(4*1024*1024)) }
    mutating func utf(_ long: Bool = false) throws -> String {
        if long {
            guard let text = String(data: try blob(), encoding: .utf8) else { throw ReplayJavaError.invalid }
            return text
        }
        let payload = try bytes(Int(number(2)))
        if payload.allSatisfy({ $0 < 128 }) { return String(decoding: payload, as: UTF8.self) }
        var input = ReplayJavaInput(data: payload)
        var units: [UInt16] = []
        while input.remaining > 0 {
            let lead = try input.byte()
            if lead < 128 { units.append(UInt16(lead)); continue }
            guard lead & 0xe0 == 0xc0 || lead & 0xf0 == 0xe0 else { throw ReplayJavaError.invalid }
            let n = lead < 224 ? 1 : 2
            var unit = UInt16(lead & (n == 1 ? 31 : 15))
            for _ in 0..<n {
                let next = try input.byte()
                guard next & 0xc0 == 0x80 else { throw ReplayJavaError.invalid }
                unit = unit << 6 | UInt16(next & 63)
            }
            units.append(unit)
        }
        return String(decoding: units, as: UTF16.self)
    }
}

struct ReplayJavaOutput {
    var data = Data()
    mutating func byte(_ n: UInt8) { data.append(n) }
    mutating func number<T: FixedWidthInteger>(_ n: T) {
        var value = n.bigEndian
        withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
    }
    mutating func int(_ n: Int) { number(Int32(n)) }
    mutating func boolean(_ value: Bool) { byte(value ? 1 : 0) }
    mutating func utf(_ text: String, long: Bool = false) throws {
        if long {
            guard text.utf8.count <= 4*1024*1024 else { throw ReplayJavaError.invalid }
            int(text.utf8.count)
            data.append(contentsOf: text.utf8)
            return
        }
        var encoded = Data()
        for unit in text.utf16 {
            if (1...127).contains(unit) { encoded.append(UInt8(unit)) }
            else if unit < 2048 {
                encoded.append(UInt8(192 | unit >> 6))
                encoded.append(UInt8(128 | unit & 63))
            } else {
                encoded.append(UInt8(224 | unit >> 12))
                encoded.append(UInt8(128 | unit >> 6 & 63))
                encoded.append(UInt8(128 | unit & 63))
            }
            guard encoded.count <= 65535 else { throw ReplayJavaError.invalid }
        }
        number(UInt16(encoded.count))
        data.append(encoded)
    }
}
