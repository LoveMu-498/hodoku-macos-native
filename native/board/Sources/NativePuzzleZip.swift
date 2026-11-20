// SPDX-License-Identifier: GPL-3.0-or-later
import Compression
import Foundation

// HoDoKu reads the first ZIP member; its writer names that member SudokuData.
// Read in memory and never extract filenames to a directory.
enum NativePuzzleZip {
    static let maximumXMLBytes = 64 * 1024 * 1024
    private static let name = Data("SudokuData".utf8)
    private static let crcTable: [UInt32] = (0..<256).map { n in
        var x = UInt32(n)
        for _ in 0..<8 { x = x & 1 == 1 ? (x >> 1) ^ 0xedb88320 : x >> 1 }
        return x
    }
    private static func checksum(_ data: Data) -> UInt32 {
        ~data.reduce(UInt32.max) { value, byte in (value >> 8) ^ crcTable[Int((value ^ UInt32(byte)) & 255)] }
    }
    static func xml(_ data: Data) throws -> Data {
        func number(_ at: Int, _ length: Int) throws -> Int {
            guard at >= 0, at <= data.count - length else { throw NativePuzzleError.archive }
            return (0..<length).reduce(0) { $0 | Int(data[at + $1]) << ($1 * 8) }
        }
        guard data.count >= 22, data.count <= maximumXMLBytes else { throw NativePuzzleError.archive }
        guard let end = try stride(from: data.count - 22, through: max(0, data.count - 65557), by: -1)
            .first(where: { try number($0, 4) == 0x06054b50 && $0 + 22 + number($0 + 20, 2) == data.count }) else {
            throw NativePuzzleError.archive
        }
        let dir = try number(end + 16, 4)
        guard try number(end + 4, 4) == 0, try number(end + 8, 2) == 1, try number(end + 10, 2) == 1,
              try dir + number(end + 12, 4) == end, try number(dir, 4) == 0x02014b50 else { throw NativePuzzleError.archive }
        let flags = try number(dir + 8, 2), method = try number(dir + 10, 2)
        let crc = try number(dir + 16, 4), compressed = try number(dir + 20, 4), count = try number(dir + 24, 4)
        let local = try number(dir + 42, 4), directoryName = try number(dir + 28, 2)
        guard flags & 1 == 0, method == 0 || method == 8, (1...maximumXMLBytes).contains(count),
              dir + 46 + directoryName <= end, data[dir+46..<dir+46+directoryName] == name,
              try number(local, 4) == 0x04034b50, try number(local + 6, 2) == flags,
              try number(local + 8, 2) == method, try number(local + 26, 2) == name.count else { throw NativePuzzleError.archive }
        let start = try local + 30 + name.count + number(local + 28, 2)
        guard start + compressed <= dir, data[local+30..<local+30+name.count] == name else { throw NativePuzzleError.archive }
        let input = data[start..<start+compressed]
        let result: Data
        if method == 0 {
            guard compressed == count else { throw NativePuzzleError.archive }
            result = Data(input)
        } else {
            var output = Data(count: count + 1)
            let written = output.withUnsafeMutableBytes { dest in
                input.withUnsafeBytes { source in
                    guard let d = dest.bindMemory(to: UInt8.self).baseAddress,
                          let s = source.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                    return compression_decode_buffer(d, count + 1, s, compressed, nil, COMPRESSION_ZLIB)
                }
            }
            guard written == count else { throw NativePuzzleError.archive }
            output.removeLast()
            result = output
        }
        guard checksum(result) == UInt32(crc) else { throw NativePuzzleError.archive }
        return result
    }

    static func pack(_ xml: Data) throws -> Data {
        guard (1...maximumXMLBytes - 128).contains(xml.count) else { throw NativePuzzleError.archive }
        let crc = Int(checksum(xml))
        var result = Data()
        func put(_ value: Int, _ bytes: Int) {
            for i in 0..<bytes { result.append(UInt8(truncatingIfNeeded: value >> (8*i))) }
        }
        func entryHeader() {
            put(20, 2); put(0, 2); put(0, 2); put(0, 2); put(0x21, 2)
            put(crc, 4); put(xml.count, 4); put(xml.count, 4); put(name.count, 2); put(0, 2)
        }
        put(0x04034b50, 4); entryHeader(); result += name; result += xml
        let directory = result.count
        put(0x02014b50, 4); put(20, 2); entryHeader()
        put(0, 2); put(0, 2); put(0, 2); put(0, 4); put(0, 4); result += name
        let length = result.count - directory
        put(0x06054b50, 4); put(0, 2); put(0, 2); put(1, 2); put(1, 2)
        put(length, 4); put(directory, 4); put(0, 2)
        return result
    }
}
