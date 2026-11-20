// Copyright (C) 2026 HoDoKu contributors. GPL-3.0-or-later.
import Foundation

struct ReplayExchangeError: LocalizedError {
    let detail: String
    init(_ detail: String) { self.detail = detail }
    var errorDescription: String? { "无法读取或导出回放（\(detail)）。" }
}

func exchangeRequire(_ condition: Bool, _ message: String) throws {
    guard condition else { throw ReplayExchangeError(message) }
}

// Dictionary keys are scalar-exact UTF-8. Swift String equality would merge
// composed and decomposed keys in opaque optional objects, invalidating a binding.
enum FrameJSON {
    case object([Data: Self])
    case array([Self])
    case string(String)
    case int(Int)
    case bool(Bool)
    case null

    static func record(_ fields: [String: Self]) -> Self {
        .object(Dictionary(uniqueKeysWithValues: fields.map { (Data($0.key.utf8), $0.value) }))
    }

    var fields: [Data: Self] {
        get throws {
            guard case .object(let v) = self else { throw ReplayExchangeError("应为对象") }
            return v
        }
    }
    subscript(_ key: String) -> Self {
        if case .object(let o) = self, let v = o[Data(key.utf8)] { return v }
        return .null
    }
    var isNull: Bool {
        if case .null = self { return true }
        return false
    }
    func exact(_ names: String) throws {
        let expected = Set(names.split(separator: " ").map { Data($0.utf8) })
        try exchangeRequire(Set(try fields.keys) == expected, "字段错误")
    }
    func list(_ range: ClosedRange<Int>) throws -> [Self] {
        guard case .array(let items) = self, range.contains(items.count) else { throw ReplayExchangeError("数组长度错误") }
        return items
    }
    func number(_ range: ClosedRange<Int>) throws -> Int {
        guard case .int(let n) = self, range.contains(n) else { throw ReplayExchangeError("整数范围错误") }
        return n
    }
    func text(_ limit: Int = 65535) throws -> String {
        guard case .string(let s) = self, s.utf8.count <= limit else { throw ReplayExchangeError("文本类型或长度错误") }
        return s
    }
    func flag() throws -> Bool {
        guard case .bool(let v) = self else { throw ReplayExchangeError("应为布尔值") }
        return v
    }
    func identifier() throws -> String {
        let s = try text(128)
        try exchangeRequire(!s.isEmpty && s.utf8.allSatisfy { (33...126).contains($0) }, "标识符错误")
        return s
    }
    func choice(_ choices: String) throws -> String {
        let s = try text()
        try exchangeRequire(choices.split(separator: " ").contains(Substring(s)), "未知枚举值")
        return s
    }
    func boundedStrings() throws {
        switch self {
        case .object(let pairs):
            for (key, value) in pairs {
                try exchangeRequire(key.count <= 65535, "键过长")
                try value.boundedStrings()
            }
        case .array(let items): for item in items { try item.boundedStrings() }
        case .string: _ = try text()
        default: break
        }
    }
    static let safeInteger = 9_007_199_254_740_991

    func canonical() -> Data {
        var data = Data()
        append(to: &data)
        return data
    }
    private func append(to data: inout Data) {
        func quoted(_ bytes: some Sequence<UInt8>, _ data: inout Data) {
            let hex = Array("0123456789abcdef".utf8)
            data.append(34)
            for b in bytes {
                switch b {
                case 34, 92:
                    data.append(92)
                    data.append(b)
                case 8: data.append(contentsOf: [92, 98])
                case 12: data.append(contentsOf: [92, 102])
                case 10: data.append(contentsOf: [92, 110])
                case 13: data.append(contentsOf: [92, 114])
                case 9: data.append(contentsOf: [92, 116])
                case 0..<32: data.append(contentsOf: [92, 117, 48, 48, hex[Int(b >> 4)], hex[Int(b & 15)]])
                default: data.append(b)
                }
            }
            data.append(34)
        }
        switch self {
        case .object(let pairs):
            data.append(123)
            for (i, key) in pairs.keys.sorted(by: { $0.lexicographicallyPrecedes($1) }).enumerated() {
                if i != 0 { data.append(44) }
                quoted(key, &data)
                data.append(58)
                pairs[key]?.append(to: &data)
            }
            data.append(125)
        case .array(let items):
            data.append(91)
            for (i, item) in items.enumerated() {
                if i != 0 { data.append(44) }
                item.append(to: &data)
            }
            data.append(93)
        case .string(let s): quoted(s.utf8, &data)
        case .int(let n): data.append(contentsOf: String(n).utf8)
        case .bool(let flag): data.append(contentsOf: (flag ? "true" : "false").utf8)
        case .null: data.append(contentsOf: "null".utf8)
        }
    }
}

// Accept legal JSON whitespace and escapes; reject duplicate keys, non-integral
// number syntax, malformed UTF-8 / surrogate escapes and excessive nesting.
struct FrameJSONReader {
    private let bytes: Data
    private var index: Int
    init(_ data: Data) {
        bytes = data
        index = data.startIndex
    }
    mutating func read() throws -> FrameJSON {
        let root = try value(depth: 0)
        whitespace()
        try exchangeRequire(index == bytes.endIndex, "JSON 尾部多余数据")
        return root
    }
    private var next: UInt8? { index < bytes.endIndex ? bytes[index] : nil }
    private mutating func take(_ b: UInt8) -> Bool {
        guard next == b else { return false }
        index += 1
        return true
    }
    private mutating func expect(_ b: UInt8) throws { try exchangeRequire(take(b), "JSON 结构错误") }
    private mutating func whitespace() { while let b = next, b == 32 || b == 10 || b == 13 || b == 9 { index += 1 } }
    private mutating func value(depth: Int) throws -> FrameJSON {
        try exchangeRequire(depth <= 64, "JSON 嵌套过深")
        whitespace()
        guard let token = next else { throw ReplayExchangeError("JSON 被截断") }
        switch token {
        case 123:
            index += 1
            whitespace()
            var result = [Data: FrameJSON]()
            if take(125) { return .object(result) }
            repeat {
                whitespace()
                let key = Data(try string().utf8)
                try exchangeRequire(key.count <= 65535 && result[key] == nil, "键重复或过长")
                whitespace()
                try expect(58)
                result[key] = try value(depth: depth + 1)
                whitespace()
                if take(125) { return .object(result) }
            } while take(44)
        case 91:
            index += 1
            whitespace()
            var result = [FrameJSON]()
            if take(93) { return .array(result) }
            repeat {
                result.append(try value(depth: depth + 1))
                whitespace()
                if take(93) { return .array(result) }
            } while take(44)
        case 34: return .string(try string())
        case 116, 102, 110:
            let literal = next == 116 ? "true" : next == 102 ? "false" : "null"
            for b in literal.utf8 { try expect(b) }
            return literal == "null" ? .null : .bool(literal == "true")
        case 45, 48...57:
            let start = index
            _ = take(45)
            if !take(48) {
                guard let b = next, (49...57).contains(b) else { throw ReplayExchangeError("无效整数") }
                while let b = next, (48...57).contains(b) { index += 1 }
            }
            guard index - start <= 17, let n = Int(String(decoding: bytes[start..<index], as: UTF8.self)),
                (-FrameJSON.safeInteger...FrameJSON.safeInteger).contains(n)
            else { throw ReplayExchangeError("整数超界") }
            return .int(n)
        default: break
        }
        throw ReplayExchangeError("无效 JSON")
    }
    private mutating func string() throws -> String {
        try expect(34)
        var decoded = Data()
        while true {
            let start = index
            while let b = next, b >= 32 && b != 34 && b != 92 { index += 1 }
            try exchangeRequire(index - start <= 16 * 1024 * 1024 - decoded.count, "字符串过长")
            if decoded.isEmpty, next == 34 {
                index += 1
                guard let s = String(data: bytes[start..<(index - 1)], encoding: .utf8) else {
                    throw ReplayExchangeError("无效 UTF-8")
                }
                return s
            }
            decoded.append(bytes[start..<index])
            if take(34) { break }
            try expect(92)
            guard let b = next else { throw ReplayExchangeError("转义被截断") }
            index += 1
            switch b {
            case 34, 47, 92: decoded.append(b)
            case 98: decoded.append(8)
            case 102: decoded.append(12)
            case 110: decoded.append(10)
            case 114: decoded.append(13)
            case 116: decoded.append(9)
            case 117:
                var n = try hexQuad()
                if (0xD800...0xDBFF).contains(n) {
                    try expect(92)
                    try expect(117)
                    let low = try hexQuad()
                    try exchangeRequire((0xDC00...0xDFFF).contains(low), "无效代理对")
                    n = 0x10000 + (n - 0xD800) * 1024 + low - 0xDC00
                }
                guard let scalar = Unicode.Scalar(n) else { throw ReplayExchangeError("无效 Unicode") }
                decoded.append(contentsOf: String(scalar).utf8)
            default: throw ReplayExchangeError("无效 JSON 转义")
            }
        }
        guard let result = String(data: decoded, encoding: .utf8) else { throw ReplayExchangeError("无效 UTF-8") }
        return result
    }
    private mutating func hexQuad() throws -> Int {
        var n = 0
        for _ in 0..<4 {
            guard let b = next else { throw ReplayExchangeError("Unicode 转义被截断") }
            switch b {
            case 48...57: n = n * 16 + Int(b) - 48
            case 65...70: n = n * 16 + Int(b) - 55
            case 97...102: n = n * 16 + Int(b) - 87
            default: throw ReplayExchangeError("Unicode 转义错误")
            }
            index += 1
        }
        return n
    }
}
