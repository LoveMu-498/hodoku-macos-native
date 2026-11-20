// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

enum LegacySessionError: LocalizedError {
    case invalid(String)
    var errorDescription: String? {
        switch self { case .invalid(let reason): return "无法导入 Java 文件。\(reason)" }
    }
}

/// A data-only representation of JavaBeans. Class and method names never reach a runtime.
final class LegacyBean {
    let className: String
    var scalar: String?
    var fields: [String: LegacyBean] = [:]
    var arguments: [LegacyBean] = []
    var elements: [LegacyBean] = []
    var entries: [(LegacyBean, LegacyBean)] = []
    var indexed: [Int: LegacyBean] = [:]
    var length: Int?
    var compact: Data?
    init(_ name: String, _ scalar: String? = nil) { self.className = name; self.scalar = scalar }
    subscript(_ key: String) -> LegacyBean? { fields[key] }
    func int(_ fallback: Int? = nil) throws -> Int {
        if let text = scalar, let n = Int(text) { return n }
        if className == "default", let n = fallback { return n }
        throw LegacySessionError.invalid("整数无效。")
    }
    func bool() throws -> Bool {
        if scalar == "true" { return true }
        if scalar == "false" { return false }
        throw LegacySessionError.invalid("布尔值无效。")
    }
    func number(_ key: String, _ fallback: Int = 0) throws -> Int { try fields[key]?.int(fallback) ?? fallback }
    func flag(_ key: String, _ fallback: Bool = false) throws -> Bool { try fields[key]?.bool() ?? fallback }
    static let widths = [1, 2, 4, 8, 4, 8, 1]
    func integers(count expected: Int? = nil, default fill: Int = 0) throws -> [Int] {
        let size = length ?? expected ?? 0
        guard size >= 0, size <= 1_000_000, expected == nil || expected == size else {
            throw LegacySessionError.invalid("数组长度不符。")
        }
        var result = Array(repeating: className == "default" ? fill : 0, count: size)
        if let raw = compact {
            let tag = Int(raw[5])
            guard [1, 2, 3, 4, 7].contains(tag) else { throw LegacySessionError.invalid("数组类型不符。") }
            let width = Self.widths[tag-1]
            for index in 0..<size {
                var bits: UInt64 = 0
                for b in raw[(10 + index*width)..<(10 + (index+1)*width)] { bits = bits << 8 | UInt64(b) }
                let shift = 64 - width*8
                result[index] = Int(Int64(bitPattern: bits << shift) >> shift)
            }
        }
        for (i, value) in indexed {
            guard result.indices.contains(i) else { throw LegacySessionError.invalid("数组索引越界。") }
            result[i] = value.className == "boolean" ? (try value.bool() ? 1 : 0) : try value.int()
        }
        return result
    }
}

private final class SessionXMLNode {
    let tag: String, attrs: [String: String]
    var content = ""
    var stringUnits: [UInt16]?
    var children: [SessionXMLNode] = []
    init(_ tag: String, _ attrs: [String: String]) { self.tag = tag; self.attrs = attrs }
}

private final class SessionXMLTree: NSObject, XMLParserDelegate {
    var stack: [SessionXMLNode] = []
    var root: SessionXMLNode?
    var count = 0
    var failure = false
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String]) {
        count += 1
        guard stack.count < 200, count < 4_000_000 else { failure = true; parser.abortParsing(); return }
        let node = SessionXMLNode(elementName, attributeDict)
        if let parent = stack.last {
            if parent.tag == "string", elementName == "char", parent.stringUnits == nil {
                parent.stringUnits = Array(parent.content.utf16)
                parent.content = ""
            }
            parent.children.append(node)
        } else { root = node }
        stack.append(node)
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard let node = stack.last else { return }
        if node.stringUnits != nil { node.stringUnits?.append(contentsOf: string.utf16) }
        else { node.content += string }
    }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let child = stack.popLast()
        if let parent = stack.last, parent.tag == "string", let child = child {
            guard child.tag == "char" else { failure = true; parser.abortParsing(); return }
            if let code = child.attrs["code"], code.hasPrefix("#"), let unit = UInt16(code.dropFirst(), radix: 16) {
                parent.stringUnits?.append(unit)
            } else if child.content.utf16.count == 1 { parent.stringUnits?.append(contentsOf: child.content.utf16) }
            else { failure = true; parser.abortParsing() }
        }
    }
}

final class LegacySessionXML {
    private var ids: [String: LegacyBean] = [:]
    private var building = Set<ObjectIdentifier>()
    static func objects(_ data: Data) throws -> [LegacyBean] {
        guard data.count <= 256 * 1024 * 1024, !data.isEmpty, !data.contains(0),
              data.range(of: Data("<!DOCTYPE".utf8)) == nil, data.range(of: Data("<!ENTITY".utf8)) == nil else {
            throw LegacySessionError.invalid("文件过大或包含不支持的 XML 声明。")
        }
        let tree = SessionXMLTree(), parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = tree
        guard parser.parse(), !tree.failure, tree.stack.isEmpty, let root = tree.root,
              root.tag == "java", root.attrs["class"] == "java.beans.XMLDecoder" else {
            throw LegacySessionError.invalid("Java XML 结构不完整。")
        }
        let reader = Self()
        return try root.children.map { try reader.value($0) }
    }

    private func remember(_ n: SessionXMLNode, _ v: LegacyBean) throws {
        if let id = n.attrs["id"] {
            guard ids[id] == nil else { throw LegacySessionError.invalid("对象编号重复。") }
            ids[id] = v
        }
    }
    private func value(_ n: SessionXMLNode) throws -> LegacyBean {
        if let id = n.attrs["idref"] {
            guard let v = ids[id], n.children.isEmpty, !building.contains(ObjectIdentifier(v)) else {
                throw LegacySessionError.invalid("对象引用无效。")
            }
            return v
        }
        let args = n.children.filter { $0.tag != "void" }
        let item: LegacyBean
        switch n.tag {
        case "null", "boolean", "byte", "short", "int", "long", "float", "double", "string", "class", "char":
            item = LegacyBean(n.tag, n.stringUnits.map { String(decoding: $0, as: UTF16.self) } ?? n.content)
        case "array":
            guard let type = n.attrs["class"], let length = n.attrs["length"].flatMap(Int.init), (0...16_777_216).contains(length)
            else { throw LegacySessionError.invalid("数组声明无效。") }
            item = LegacyBean(type + "[]"); item.length = length
        case "object":
            guard let name = n.attrs["class"] else { throw LegacySessionError.invalid("对象类型缺失。") }
            let arguments = try args.map(value)
            item = try construct(name, method: n.attrs["method"], field: n.attrs["field"], args: arguments)
        default: throw LegacySessionError.invalid("未知 XML 元素 \(n.tag)。")
        }
        try remember(n, item)
        building.insert(ObjectIdentifier(item))
        defer { building.remove(ObjectIdentifier(item)) }
        for op in n.children where op.tag == "void" { try apply(op, to: item) }
        return item
    }

    private func construct(_ name: String, method: String?, field: String?, args: [LegacyBean]) throws -> LegacyBean {
        if name == "sudoku.SessionPrimitiveArrays" {
            let methods = ["bytes", "shorts", "ints", "longs", "floats", "doubles", "booleans"]
            guard let method = method, let offset = methods.firstIndex(of: method), let text = args.first?.scalar,
                  text.utf8.count <= 89_478_488, let bytes = Data(base64Encoded: text), (10...67_108_864).contains(bytes.count),
                  bytes.prefix(6) == Data([72,83,65,49,1,UInt8(offset+1)]) else { throw LegacySessionError.invalid("压缩数组签名无效。") }
            let length = bytes[6..<10].reduce(0) { $0 << 8 | Int($1) }
            guard bytes.count - 10 == length * LegacyBean.widths[offset], offset != 6 || bytes.dropFirst(10).allSatisfy({ $0 <= 1 })
            else { throw LegacySessionError.invalid("压缩数组长度或数据无效。") }
            let item = LegacyBean(String(method.dropLast()) + "[]"); item.compact = bytes; item.length = length
            return item
        }
        if name == "sudoku.SessionInkCodec" { return try LegacySessionInk.factory(method, args) }
        if name == "java.lang.Enum", method == "valueOf", args.count == 2, let type = args[0].scalar {
            return LegacyBean(type, args[1].scalar)
        }
        let types = ["java.util.ArrayList", "java.util.LinkedList", "java.util.Stack", "java.util.TreeMap",
                     "java.util.HashMap", "java.util.Date", "java.util.Vector", "java.util.BitSet",
                     "java.awt.Color", "java.awt.Point", "java.awt.Dimension", "java.awt.Font",
                     "java.lang.String", "java.lang.Integer", "java.lang.Boolean", "java.lang.Long"]
        guard (name.hasPrefix("sudoku.") || name == "generator.GeneratorPattern" || types.contains(name)), method == nil || method == "new" else {
            throw LegacySessionError.invalid("不支持的 Java 对象 \(name)。")
        }
        let item = LegacyBean(name, field); item.arguments = args
        return item
    }

    private func apply(_ n: SessionXMLNode, to owner: LegacyBean) throws {
        // XMLEncoder may introduce getter ids inside a setter before using one as its argument.
        // Read only the two known public, derived arrays of Options. No reflection is performed.
        if n.attrs["class"] == "sudoku.Options", n.attrs["method"] == "getField",
           let source = n.children.first, source.tag == "string", ["solverSteps","solverStepsProgress"].contains(source.content) {
            let field = LegacyBean("options.field", source.content)
            try remember(n, field)
            for child in n.children where child.tag == "void" { try apply(child, to: field) }
            return
        }
        if owner.className == "options.field", n.attrs["method"] == "get", let key = owner.scalar,
           let ref = n.children.first?.attrs["idref"], let options = ids[ref], options.className == "sudoku.Options" {
            let array = options[key] ?? LegacySettingsDefaults.stepArray(key)
            options.fields[key] = array
            try remember(n, array)
            for child in n.children where child.tag == "void" { try apply(child, to: array) }
            return
        }
        if let ref = n.attrs["idref"] {
            guard let item = ids[ref] else { throw LegacySessionError.invalid("对象引用无效。") }
            for child in n.children where child.tag == "void" { try apply(child, to: item) }
            return
        }
        func binding(_ node: SessionXMLNode) -> Bool { node.attrs["class"] != nil || node.attrs["idref"] != nil }
        let children = n.children.filter { $0.tag == "void" }
        for child in children where binding(child) { try apply(child, to: owner) }
        let args = try n.children.filter { $0.tag != "void" }.map(value)
        let target: LegacyBean
        if let key = n.attrs["property"] {
            guard args.count <= 1 else { throw LegacySessionError.invalid("属性参数无效。") }
            target = args.first ?? owner[key] ?? defaultValue(owner.className, key)
            owner.fields[key] = target
        } else if let index = n.attrs["index"].flatMap(Int.init) {
            guard index >= 0, index < (owner.length ?? 16_777_216), args.count <= 1 else {
                throw LegacySessionError.invalid("数组索引无效。")
            }
            target = args.first ?? owner.indexed[index] ?? LegacyBean("default")
            owner.indexed[index] = target
        } else {
            switch n.attrs["method"] {
            case "add", "push":
                guard args.count == 1 else { throw LegacySessionError.invalid("列表元素无效。") }
                target = args[0]; owner.elements.append(target)
            case "put":
                guard args.count == 2 else { throw LegacySessionError.invalid("映射元素无效。") }
                target = args[1]; owner.entries.append((args[0], target))
            case "copy" where owner.className == "sudoku.DoodleStroke":
                target = LegacyBean(owner.className); target.fields = owner.fields; target.arguments = owner.arguments
            case let method? where args.isEmpty && method.hasPrefix("is"):
                let key = String(method.dropFirst(2))
                let property = key.prefix(1).lowercased() + key.dropFirst()
                target = owner[property] ?? defaultValue(owner.className, property)
            default: throw LegacySessionError.invalid("未支持的 JavaBeans 描述。")
            }
        }
        try remember(n, target)
        for child in children where !binding(child) { try apply(child, to: target) }
    }

    private func defaultValue(_ type: String, _ key: String) -> LegacyBean {
        if type == "sudoku.Options" {
            if let visual = NativeBoardAppearance.defaultBean(key) { return visual }
            switch key {
            case "orgSolverSteps", "solverSteps", "solverStepsProgress": return LegacySettingsDefaults.stepArray(key)
            case "actLevel": return LegacyBean("int","1")
            case "historySize": return LegacyBean("int","50")
            case "appearanceMode": return LegacyBean("string","SYSTEM")
            case "gameMode": return LegacyBean("sudoku.GameMode","PLAYING")
            default: break
            }
        }
        if type == "sudoku.SessionSnapshot" {
            switch key {
            case "formatVersion": return LegacyBean("int", "1")
            case "activeRow", "activeCol": return LegacyBean("int", "4")
            case "coloringMode", "completedLevel", "replayFrameCount": return LegacyBean("int", "0")
            case "completed", "historyEligible", "previouslySolved", "completionRecorded": return LegacyBean("boolean", "false")
            default: break
            }
        }
        if type == "sudoku.SolutionStep", ["potentialEliminations","potentialCannibalisticEliminations"].contains(key) {
            return LegacyBean("sudoku.SudokuSet")
        }
        if key == "initialized", type == "sudoku.SudokuSet" { return LegacyBean("boolean", "true") }
        if type == "sudoku.DoodleStroke" {
            if ["anchorCell","thoughtGroup"].contains(key) { return LegacyBean("int","-1") }
            if ["anchorDigit","hypothesisGroupKind","derivedSourceId","hypothesisConditionId","conclusionSourceMask"].contains(key) { return LegacyBean("int","0") }
        }
        return LegacyBean("default")
    }
}
