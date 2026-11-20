// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

struct NativeCluePattern: Codable, Equatable {
    var name: String
    var cells = Array(repeating: false, count: 81)
    var valid = false

    init(name: String) { self.name = name }

    init(_ bean: LegacyBean) throws {
        guard bean.className == "generator.GeneratorPattern" else { throw BoardFileError.invalid }
        name = bean["name"]?.scalar ?? ""
        if let pattern = bean["pattern"] {
            let flags = try pattern.integers(count: 81)
            guard flags.allSatisfy({ $0 == 0 || $0 == 1 }) else { throw BoardFileError.invalid }
            cells = flags.map { $0 == 1 }
        }
        valid = try bean.flag("valid")
    }

    var givens: Int { cells.filter { $0 }.count }

    mutating func toggle(_ cell: Int) {
        cells[cell].toggle()
        valid = false
    }

    func xml() throws -> String {
        let text = try NativePuzzleBeanWriter().value(LegacyBean("string", name))
        let positions = cells.indices.filter { cells[$0] }.map {
            "<void index=\"\($0)\"><boolean>true</boolean></void>"
        }.joined()
        return """
        <object class="generator.GeneratorPattern">
        <void property="name">\(text)</void>
        <void property="pattern"><array class="boolean" length="81">\(positions)</array></void>
        <void property="valid"><boolean>\(valid)</boolean></void></object>
        """
    }
}

/// The pattern library and its zero-based selection are one value in both Options and .hpat.
struct NativePatternSettings: Codable, Equatable {
    var patterns: [NativeCluePattern] = []
    var selection = -1

    init() {}

    init(list: LegacyBean?, selection: Int) throws {
        if let list = list {
            guard ["java.util.ArrayList", "default"].contains(list.className) else { throw BoardFileError.invalid }
            patterns = try list.elements.map { try NativeCluePattern($0) }
        }
        self.selection = selection
        try validate()
    }

    init(_ options: LegacyBean) throws {
        try self.init(list: options["generatorPatterns"], selection: options.number("generatorPatternIndex", -1))
    }

    func validate() throws {
        guard selection == -1 || patterns.indices.contains(selection),
              patterns.allSatisfy({ $0.cells.count == 81 }) else {
            throw WorkspaceProblem("给定数图案或所选序号无效。")
        }
    }

    var activeCells: [UInt8]? {
        guard patterns.indices.contains(selection), patterns[selection].valid else { return nil }
        return patterns[selection].cells.map { $0 ? 1 : 0 }
    }

    func listXML() throws -> String {
        try validate()
        return "<object class=\"java.util.ArrayList\">" + (try patterns.map {
            "<void method=\"add\">" + (try $0.xml()) + "</void>"
        }.joined()) + "</object>"
    }

    init(file data: Data) throws {
        guard data.count <= LegacySettingsFile.maxSize else { throw WorkspaceProblem("图案文件过大。") }
        let objects = try LegacySessionXML.objects(data)
        guard objects.count == 2, objects[0].className == "java.util.ArrayList", objects[1].className == "int" else {
            throw WorkspaceProblem("请选择 HoDoKu 给定数图案文件（.hpat）。")
        }
        try self.init(list: objects[0], selection: objects[1].int())
    }

    func fileData() throws -> Data {
        Data(try """
        <?xml version="1.0" encoding="UTF-8"?>
        <java class="java.beans.XMLDecoder">\(listXML())<int>\(selection)</int></java>
        """.utf8)
    }
}
