// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// XMLEncoder stores patches to a new Options() instance, including references to its default solver arrays.
struct LegacySettingsFile {
    static let maxSize = 64*1024*1024
    let preferences: NativeWorkspacePreferences
    let steps: [Int: LegacyBean]
    let historyRows: [String]
    init(_ raw: Data) throws {
        guard raw.count <= Self.maxSize else { throw WorkspaceProblem("设置文件过大。") }
        let objects = try LegacySessionXML.objects(raw)
        guard objects.count == 1, let opts = objects.first, opts.className == "sudoku.Options" else {
            throw WorkspaceProblem("所选文件没有 HoDoKu 设置。")
        }
        var prefs = NativeWorkspacePreferences()
        prefs.legacyXML = raw
        prefs.generatorPatterns = try NativePatternSettings(opts)
        prefs.visual = try NativeBoardAppearance(opts)
        prefs.mouse = try NativeMouseOptions(opts)
        prefs.general = try NativeGeneralOptions(opts)
        let grade = try opts["actLevel"]?.int() ?? 1
        prefs.difficulty = (1...5).contains(grade) ? grade : 1
        prefs.historyLimit = max(0, try opts["historySize"]?.int() ?? 50)
        prefs.mode = opts["gameMode"]?.scalar ?? "PLAYING"
        let appearance = opts["appearanceMode"]?.scalar?.uppercased() ?? "SYSTEM"
        prefs.appearance = ["LIGHT","DARK"].contains(appearance) ? appearance : "SYSTEM"
        historyRows = opts["historyOfCreatedPuzzles"]?.elements.compactMap(\.scalar) ?? []
        // Options.getPuzzleHistoryEntries() filters malformed rows when reading, and trims only on insertion.
        prefs.history = historyRows.compactMap { try? NativePuzzleHistoryEntry.parse($0) }
        steps = (opts["orgSolverSteps"] ?? LegacySettingsDefaults.stepArray("orgSolverSteps")).indexed
        for step in steps.values where try step.flag("enabledTraining") {
            guard let kind = step["type"]?.scalar else { throw WorkspaceProblem("训练技巧缺少类型。") }
            prefs.training.insert(kind)
        }
        try prefs.validate()
        preferences = prefs
    }

    static func export(_ value: NativeWorkspacePreferences) throws -> Data {
        try value.validate()
        let raw = value.legacyXML ?? Data("<java class=\"java.beans.XMLDecoder\"><object class=\"sudoku.Options\"/></java>".utf8)
        let source = try LegacySettingsFile(raw)
        let original = source.preferences
        let doc = try XMLDocument(data: raw, options: [.nodeLoadExternalEntitiesNever, .nodePreserveAll])
        guard let root = doc.rootElement(), let options = root.elements(forName: "object").first else {
            throw WorkspaceProblem("设置文件结构不完整。")
        }
        // Java will instantiate these files. Export only plain configuration bean operations.
        try LegacySettingsXML.check(root)
        var edits = [String]()
        func append(_ key: String, _ contents: String) {
            edits.append("<void property=\"\(key)\">" + contents + "</void>")
        }
        let mouse = try value.resolvedMouseOptions()
        let oldMouse = try original.resolvedMouseOptions()
        let patterns = try value.resolvedPatterns()
        let before = try original.resolvedPatterns()
        if patterns.patterns != before.patterns { append("generatorPatterns", try patterns.listXML()) }
        if patterns.selection != before.selection { append("generatorPatternIndex", "<int>\(patterns.selection)</int>") }
        for (key, content) in try value.resolvedVisual().patches(comparedTo: original.resolvedVisual()) { append(key, content) }
        try value.resolvedGeneralOptions().changedProperties(comparedWith: original.resolvedGeneralOptions(), append: append)
        for (key, field) in [("operationSoundsEnabled", \NativeMouseOptions.operationSoundsEnabled), ("singleClickMode", \.singleClickMode),
                             ("showCandidates", \.showCandidates), ("showDeviations", \.showDeviations),
                             ("useShiftForRegionSelect", \.useShiftForRegionSelect), ("autoHighlighting", \.autoHighlighting),
                             ("useOrInsteadOfAndForFilter", \.useOrInsteadOfAndForFilter), ("onlySmallFilters", \.onlySmallFilters),
                             ("highlightingGivens", \.highlightingGivens), ("editModeAutoAdvance", \.editModeAutoAdvance)]
        where mouse[keyPath: field] != oldMouse[keyPath: field] {
            append(key, "<boolean>\(mouse[keyPath: field])</boolean>")
        }
        if value.difficulty != original.difficulty { append("actLevel", "<int>\(value.difficulty)</int>") }
        if value.mode != original.mode {
            append("gameMode","<object class=\"java.lang.Enum\" method=\"valueOf\"><class>sudoku.GameMode</class><string>\(value.mode)</string></object>")
        }
        if value.appearance != original.appearance { append("appearanceMode","<string>\(value.appearance)</string>") }
        if value.historyLimit != original.historyLimit { append("historySize", "<int>\(value.historyLimit)</int>") }
        if value.training != original.training {
            let changed = value.training.symmetricDifference(original.training)
            let known = Set(source.steps.values.compactMap { $0["type"]?.scalar })
            guard changed.isSubset(of: known) else { throw WorkspaceProblem("Java 配置中没有对应的训练技巧。") }
            var patches = ""
            for (index, step) in source.steps.sorted(by: { $0.key < $1.key }) {
                guard let kind = step["type"]?.scalar, changed.contains(kind) else { continue }
                let on = value.training.contains(kind)
                patches += "<void index=\"\(index)\"><void property=\"enabledTraining\"><boolean>\(on)</boolean></void></void>"
            }
            append("orgSolverSteps", patches)
        }
        if let solver = value.solverEdits {
            solver.appendJava(to: &edits, original: try NativeSolverConfig.read(original), steps: source.steps)
        }
        if value.history != original.history {
            let rows = source.editedHistory(value.history, limit: value.historyLimit)
            var xml = "<object class=\"java.util.ArrayList\">"
            for row in rows {
                let text = try NativePuzzleBeanWriter().value(LegacyBean("string", row))
                xml += "<void method=\"add\">" + text + "</void>"
            }
            append("historyOfCreatedPuzzles", xml + "</object>")
        }
        if edits.isEmpty { return raw }
        for patch in edits { options.addChild(try XMLElement(xmlString: patch)) }
        return doc.xmlData
    }

    /// Retain the original spelling of surviving rows. A legacy malformed row stays in its slot
    /// between neighboring survivors until capacity or an explicit history clear removes it.
    private func editedHistory(_ history: [NativePuzzleHistoryEntry], limit: Int) -> [String] {
        guard !history.isEmpty, limit > 0 else { return [] }
        var old = historyRows.map { ($0, try? NativePuzzleHistoryEntry.parse($0)) }
        var result = [String]()
        for entry in history {
            if let index = old.firstIndex(where: { $0.1 == entry }) {
                let match = old.remove(at: index)
                let precedingInvalid = old[..<index].indices.filter { old[$0].1 == nil }
                result += precedingInvalid.map { old[$0].0 }
                for i in precedingInvalid.reversed() { old.remove(at: i) }
                result.append(match.0)
            } else { result.append(entry.encode()) }
        }
        result += old.filter { $0.1 == nil }.map(\.0)
        return Array(result.prefix(limit))
    }
}

/// Validate the vocabulary before handing an edited or unchanged settings copy to a Java reader.
private enum LegacySettingsXML {
    private static let beans: Set<String> = ["sudoku.Options","sudoku.StepConfig","sudoku.DifficultyLevel",
        "sudoku.AnnotationPalettePreferences","sudoku.AnnotationPaletteSelection","generator.GeneratorPattern",
        "java.awt.Color","java.awt.Font","java.util.ArrayList","java.lang.String"]
    private static let enums: Set<String> = ["sudoku.SolutionType","sudoku.SolutionCategory","sudoku.GameMode","sudoku.DifficultyType"]
    private static let primitives: Set<String> = ["byte","short","int","long","float","double","boolean","char"]
    private static func checkNode(_ node: XMLElement) throws {
        let attributes = Set(node.attributes?.compactMap(\.name) ?? [])
        func a(_ key: String) -> String? { node.attribute(forName: key)?.stringValue }
        let children = (node.children ?? []).compactMap { $0 as? XMLElement }
        let allowed: Bool
        switch node.name {
        case "java": allowed = attributes.isSubset(of: ["class","version"]) && a("class") == "java.beans.XMLDecoder"
        case "class": allowed = attributes.isEmpty && enums.contains(node.stringValue ?? "")
        case "object":
            if let name = a("class") {
                if name == "java.lang.Enum" {
                    allowed = attributes.isSubset(of: ["class","id","method"]) && a("method") == "valueOf" &&
                        children.count == 2 && children[0].name == "class" && children[1].name == "string"
                } else {
                    allowed = beans.contains(name) && attributes.isSubset(of: ["class","method","id","field"]) &&
                        (a("method") == nil || a("method") == "new") &&
                        (a("field") == nil || name == "java.awt.Color")
                }
            } else { allowed = attributes == ["idref"] && children.isEmpty }
        case "void":
            if let cls = a("class") {
                allowed = attributes.isSubset(of: ["id","class","method"]) && cls == "sudoku.Options" && a("method") == "getField" &&
                    children.first?.name == "string" && ["solverSteps","solverStepsProgress"].contains(children.first?.stringValue ?? "")
            } else if let property = a("property") {
                allowed = attributes.isSubset(of: ["id","property"]) && LegacySettingsDefaults.properties.contains(property)
            } else if let method = a("method") {
                if method == "get" {
                    let parent = node.parent as? XMLElement
                    allowed = attributes.isSubset(of: ["id","method"]) && parent?.attribute(forName: "class")?.stringValue == "sudoku.Options" &&
                        parent?.attribute(forName: "method")?.stringValue == "getField" && children.first?.attribute(forName:"idref") != nil
                } else {
                    let suffix = method.dropFirst(2)
                    let property = suffix.prefix(1).lowercased() + suffix.dropFirst()
                    allowed = attributes.isSubset(of: ["id","method"]) && (method == "add" ||
                        (method.hasPrefix("is") && children.isEmpty && LegacySettingsDefaults.properties.contains(property)))
                }
            } else if let index = a("index").flatMap(Int.init) {
                allowed = attributes.isSubset(of: ["id","index"]) && (0..<1_000_000).contains(index)
            } else { allowed = attributes == ["idref"] }
        case "array":
            let type = a("class") ?? ""
            allowed = attributes.isSubset(of: ["class","length","id"]) && (beans.union(enums).union(primitives).contains(type) ||
                ["[Ljava.lang.String;","[I","[Z"].contains(type)) && (0..<1_000_000).contains(a("length").flatMap(Int.init) ?? -1)
        case "string": allowed = attributes.isSubset(of: ["id"]) && children.allSatisfy { $0.name == "char" }
        case "char": allowed = attributes.isSubset(of: ["id","code"]) && children.isEmpty
        case "null": allowed = attributes.isEmpty && children.isEmpty
        default: allowed = primitives.contains(node.name ?? "") && attributes.isSubset(of: ["id"]) && children.isEmpty
        }
        guard allowed else { throw WorkspaceProblem("这份设置包含当前无法写入 Java 副本的字段。") }
        for child in children { try checkNode(child) }
    }
    static func check(_ root: XMLElement) throws { try checkNode(root) }
}
