// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

extension NativeBoardAppearance {
    private static let named: [String: UInt32] = [
        "white": 0xffffff, "lightgray": 0xc0c0c0, "gray": 0x808080, "darkgray": 0x404040, "black": 0,
        "red": 0xff0000, "pink": 0xffafaf, "orange": 0xffc800, "yellow": 0xffff00, "green": 0x00ff00,
        "magenta": 0xff00ff, "cyan": 0x00ffff, "blue": 0x0000ff]
    private static func decodeColor(_ bean: LegacyBean) throws -> UInt32 {
        guard bean.className == "java.awt.Color" else { throw BoardFileError.invalid }
        if let field = bean.scalar?.replacingOccurrences(of: "_", with: "").lowercased(), let value = named[field] {
            return value | 0xff000000
        }
        let args = bean.arguments
        if args.count == 1 || args.count == 2 {
            let packed = UInt32(truncatingIfNeeded: try args[0].int())
            if args.count == 2, try args[1].bool() { return packed }
            return packed | 0xff000000
        }
        guard (3...4).contains(args.count) else { throw BoardFileError.invalid }
        let parts: [UInt32] = try args.map { part in
            if part.className == "float", let v = Double(part.scalar ?? ""), (0...1).contains(v) {
                return UInt32((v * 255).rounded())
            }
            guard let value = UInt8(exactly: try part.int()) else { throw BoardFileError.invalid }
            return UInt32(value)
        }
        return (parts.count == 4 ? parts[3] : 255) << 24 | parts[0] << 16 | parts[1] << 8 | parts[2]
    }

    // A getter id may later be used as the argument to a completely different Options setter.
    static func defaultBean(_ key: String) -> LegacyBean? {
        func colorBean(_ value: UInt32) -> LegacyBean {
            let bean = LegacyBean("java.awt.Color")
            bean.arguments = [LegacyBean("int", String(Int32(bitPattern: value))), LegacyBean("boolean", "true")]
            return bean
        }
        func array(_ type: String, _ values: [LegacyBean]) -> LegacyBean {
            let bean = LegacyBean(type + "[]")
            bean.length = values.count
            for (index, value) in values.enumerated() { bean.indexed[index] = value }
            return bean
        }
        if let values = colorDefaults[key] {
            return values.count == 1 ? colorBean(values[0]) : array("java.awt.Color", values.map(colorBean))
        }
        if let font = fontDefaults[key] {
            let bean = LegacyBean("java.awt.Font")
            bean.arguments = [LegacyBean("string", font.name), LegacyBean("int", String(font.style)), LegacyBean("int", String(font.size))]
            return bean
        }
        if let value = factorDefaults[key] { return LegacyBean("double", String(value)) }
        if key == "difficultyLevels" {
            return array("sudoku.DifficultyLevel", levelDefaults.map { value in
                let bean = LegacyBean("sudoku.DifficultyLevel")
                bean.fields["foregroundColor"] = colorBean(value.foreground)
                bean.fields["backgroundColor"] = colorBean(value.background)
                bean.fields["maxScore"] = LegacyBean("int", String(value.maxScore))
                return bean
            })
        }
        return nil
    }

    init(_ bean: LegacyBean) throws {
        self.init()
        for (key, defaults) in Self.colorDefaults {
            guard let value = bean[key] else { continue }
            if defaults.count == 1 { colors[key] = [try Self.decodeColor(value)] }
            else {
                if let count = value.length, count < defaults.count {
                    var lengths = legacyColorLengths ?? [:]
                    lengths[key] = count
                    legacyColorLengths = lengths
                }
                for (index, item) in value.indexed where defaults.indices.contains(index) && item.className != "null" {
                    colors[key]![index] = try Self.decodeColor(item)
                }
            }
        }
        for key in Self.fontDefaults.keys {
            guard let value = bean[key] else { continue }
            guard value.className == "java.awt.Font", value.arguments.count == 3,
                  let name = value.arguments[0].scalar else { throw BoardFileError.invalid }
            fonts[key] = try NativePaintFont(name: name, style: value.arguments[1].int(), size: value.arguments[2].int())
        }
        for key in Self.factorDefaults.keys {
            if let value = bean[key] {
                guard let d = Double(value.scalar ?? "") else { throw BoardFileError.invalid }
                factors[key] = d
            }
        }
        for (index, level) in bean["difficultyLevels"]?.indexed ?? [:] {
            guard levels.indices.contains(index) else { throw BoardFileError.invalid }
            if let v = level["maxScore"] {
                guard let score = Int32(exactly: try v.int()) else { throw BoardFileError.invalid }
                levels[index].maxScore = score
            }
            if let v = level["foregroundColor"] { levels[index].foreground = try Self.decodeColor(v) }
            if let v = level["backgroundColor"] { levels[index].background = try Self.decodeColor(v) }
        }
        try validate()
    }

    func patches(comparedTo old: Self) throws -> [(String, String)] {
        func colorXML(_ value: UInt32) -> String {
            let components = [value >> 16 & 255, value >> 8 & 255, value & 255, value >> 24]
            return "<object class=\"java.awt.Color\">" + components.map { "<int>\($0)</int>" }.joined() + "</object>"
        }
        var out = [(String, String)]()
        for key in colors.keys.sorted() where colors[key] != old.colors[key] {
            let group = colors[key]!
            if group.count == 1 { out.append((key, colorXML(group[0]))) }
            else {
                let changes = group.indices.filter { group[$0] != old.colors[key]![$0] }
                func slot(_ index: Int) -> String {
                    "<void index=\"\(index)\">" + colorXML(group[index]) + "</void>"
                }
                if let originalLength = old.legacyColorLengths?[key], changes.contains(where: { $0 >= originalLength }) {
                    let array = "<array class=\"java.awt.Color\" length=\"\(group.count)\">" + group.indices.map(slot).joined() + "</array>"
                    out.append((key, array))
                } else { out.append((key, changes.map(slot).joined())) }
            }
        }
        for key in fonts.keys.sorted() where fonts[key] != old.fonts[key] {
            let f = fonts[key]!
            let name = try NativePuzzleBeanWriter().value(LegacyBean("string", f.name))
            out.append((key, "<object class=\"java.awt.Font\">" + name + "<int>\(f.style)</int><int>\(f.size)</int></object>"))
        }
        for key in factors.keys.sorted() where factors[key] != old.factors[key] {
            out.append((key, "<double>\(factors[key]!)</double>"))
        }
        var levelChanges = ""
        for index in levels.indices where levels[index] != old.levels[index] {
            let level = levels[index], base = old.levels[index]
            var changes = ""
            if level.maxScore != base.maxScore { changes += "<void property=\"maxScore\"><int>\(level.maxScore)</int></void>" }
            if level.foreground != base.foreground { changes += "<void property=\"foregroundColor\">" + colorXML(level.foreground) + "</void>" }
            if level.background != base.background { changes += "<void property=\"backgroundColor\">" + colorXML(level.background) + "</void>" }
            levelChanges += "<void index=\"\(index)\">" + changes + "</void>"
        }
        if !levelChanges.isEmpty { out.append(("difficultyLevels", levelChanges)) }
        return out
    }
}
