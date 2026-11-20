// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Native edits are keyed by the stable Java technique ID. Keep the imported Java
/// document intact, including settings unknown to this release.
struct NativeSolverOverrides: Codable, Equatable {
    var rules = [String: NativeSolverConfig.Rule]()
    var options = [String: String]()

    func validate() throws {
        let kinds = Set(NativeSolverConfig.standard.rules.map(\.kind))
        for (key, rule) in rules {
            guard kinds.contains(key), key == rule.kind, (1...5).contains(rule.level),
                  (0...Int(Int32.max)).contains(rule.score),
                  (0...Int(Int32.max)).contains(rule.index), (0...Int(Int32.max)).contains(rule.progressIndex)
            else { throw BoardFileError.invalid }
        }
        for (key, value) in options {
            guard let field = SolverOption.byKey[key], field.accepts(value) else { throw BoardFileError.invalid }
        }
    }

    func appendJava(to edits: inout [String], original: NativeSolverConfig, steps: [Int: LegacyBean]) {
        for (key, value) in options.sorted(by: { $0.key < $1.key }) {
            guard let field = SolverOption.byKey[key], value != original.option(key) else { continue }
            let tag = field.tag
            edits.append("<void property=\"\(key)\"><\(tag)>\(value)</\(tag)></void>")
        }
        let byKind = Dictionary(original.rules.map { ($0.kind, $0) }, uniquingKeysWith: { a, _ in a })
        var patches = ""
        for (index, step) in steps.sorted(by: { $0.key < $1.key }) {
            guard let kind = step["type"]?.scalar, let rule = rules[kind], let old = byKind[kind] else { continue }
            var props = ""
            func write<T: Equatable>(_ key: String, _ value: T, _ prior: T, _ tag: String) {
                if value != prior { props += "<void property=\"\(key)\"><\(tag)>\(value)</\(tag)></void>" }
            }
            write("index", rule.index, old.index, "int")
            write("indexProgress", rule.progressIndex, old.progressIndex, "int")
            write("level", rule.level, old.level, "int")
            write("baseScore", rule.score, old.score, "int")
            write("enabled", rule.enabled, old.enabled, "boolean")
            write("enabledProgress", rule.progressEnabled, old.progressEnabled, "boolean")
            write("allStepsEnabled", rule.allEnabled, old.allEnabled, "boolean")
            if !props.isEmpty { patches += "<void index=\"\(index)\">\(props)</void>" }
        }
        if !patches.isEmpty { edits.append("<void property=\"orgSolverSteps\">" + patches + "</void>") }
    }
}

struct SolverOption {
    enum Control {
        case toggle, number(ClosedRange<Int>), choices([String]), digits
    }
    let key, name, initial: String
    let control: Control

    init(_ key: String, _ name: String, _ value: Bool) {
        self.key = key; self.name = name; initial = String(value); control = .toggle
    }
    init(_ key: String, _ name: String, _ value: Int, _ range: ClosedRange<Int>) {
        self.key = key; self.name = name; initial = String(value); control = .number(range)
    }
    init(_ key: String, _ name: String, _ value: Int, _ choices: [String]) {
        self.key = key; self.name = name; initial = String(value); control = .choices(choices)
    }
    init(digits key: String) {
        self.key = key; name = "参与搜索的数字"; initial = "111111111"; control = .digits
    }
    var tag: String {
        switch control { case .toggle: return "boolean"; case .digits: return "string"; default: return "int" }
    }
    func accepts(_ value: String) -> Bool {
        switch control {
        case .toggle: return Bool(value) != nil
        case .number(let range): return Int(value).map(range.contains) == true
        case .choices(let names): return Int(value).map(names.indices.contains) == true
        case .digits: return value.utf8.count == 9 && value.allSatisfy { $0 == "0" || $0 == "1" }
        }
    }
    static let fishTypes = ["基础鱼", "含 Franken 鱼", "含变异鱼"]
    static let groups: [(String, [SolverOption])] = [
        ("鱼形", [
            .init("maxFins", "最多鳍数", 5, 0...10), .init("maxEndoFins", "最多内鳍数", 2, 0...10),
            .init("checkTemplates", "用模板检查候选数", true), .init("onlyOneFishPerStep", "同一删数只保留最小鱼形", true),
            .init("fishDisplayMode", "鱼形证明", 0, ["标准", "统计数量", "统计格位"])
        ]),
        ("Kraken 鱼", [
            .init("krakenMaxFishType", "鱼形范围", 1, fishTypes), .init("krakenMaxFishSize", "最大阶数", 4, 2...7),
            .init("maxKrakenFins", "最多鳍数", 2, 0...10), .init("maxKrakenEndoFins", "最多内鳍数", 0, 0...10)
        ]),
        ("链与推理表", [
            .init("restrictChainSize", "限制链长度", true), .init("restrictChainLength", "最大链长", 20, 0...39),
            .init("maxTableEntryLength", "推理表条目上限", 1000, 0...Int(Int32.max)),
            .init("anzTableLookAhead", "推理表前瞻步数", 4, 0...Int(Int32.max)),
            .init("onlyOneChainPerStep", "同一删数只保留一条链", true),
            .init("allowAlsInTablingChains", "推理表链允许近锁定集", false)
        ]),
        ("近锁定集与矩形", [
            .init("allowAlsOverlap", "允许近锁定集重叠", false), .init("onlyOneAlsPerStep", "同一删数只保留一个近锁定集步骤", true),
            .init("allowErsWithOnlyTwoCandidates", "允许仅有两个候选格的空矩形", false),
            .init("allowDualsAndSiamese", "允许双重结构与连体鱼", false),
            .init("allowUniquenessMissingCandidates", "唯一性技巧允许缺失候选数", true)
        ]),
        ("题目文本", [.init("useZeroInsteadOfDot", "用 0 表示空格", false)])
    ]
    static let allGroups: [(String, [SolverOption])] = [
        ("鱼形搜索", [
            .init("allStepsSearchFish", "查找鱼形", true), .init("allStepsMaxFishType", "鱼形范围", 1, fishTypes),
            .init("allStepsMinFishSize", "最小阶数", 2, 2...7), .init("allStepsMaxFishSize", "最大阶数", 4, 2...7),
            .init("allStepsMaxFins", "最多鳍数", 5, 0...10), .init("allStepsMaxEndoFins", "最多内鳍数", 2, 0...10),
            .init("allStepsCheckTemplates", "用模板检查候选数", true), .init(digits: "allStepsFishCandidates")
        ]),
        ("Kraken 鱼搜索", [
            .init("allStepsKrakenMaxFishType", "鱼形范围", 1, fishTypes),
            .init("allStepsKrakenMinFishSize", "最小阶数", 2, 2...7), .init("allStepsKrakenMaxFishSize", "最大阶数", 4, 2...7),
            .init("allStepsMaxKrakenFins", "最多鳍数", 2, 0...10), .init("allStepsMaxKrakenEndoFins", "最多内鳍数", 0, 0...10),
            .init(digits: "allStepsKrakenFishCandidates")
        ]),
        ("近锁定集链", [
            .init("allStepsAlsChainLength", "最大链长", 6, 4...7),
            .init("allStepsAlsChainForwardOnly", "只沿正向搜索", true)
        ])
    ]
    static let byKey = Dictionary(uniqueKeysWithValues: (groups + allGroups).flatMap { $0.1 }.map { ($0.key, $0) })
}

extension NativeSolverConfig {
    func option(_ key: String) -> String {
        switch key {
        case "allowUniquenessMissingCandidates": return String(allowMissing)
        case "onlyOneAlsPerStep": return String(onlyOneALS)
        case "allowAlsOverlap": return String(allowOverlap)
        case "fishDisplayMode": return String(fishDisplayMode)
        case "useZeroInsteadOfDot": return String(useZero)
        default: return searchOptions[key] ?? SolverOption.byKey[key]?.initial ?? ""
        }
    }
    mutating func apply(option key: String, value: String) {
        switch key {
        case "allowUniquenessMissingCandidates": allowMissing = value == "true"
        case "onlyOneAlsPerStep": onlyOneALS = value == "true"
        case "allowAlsOverlap": allowOverlap = value == "true"
        case "fishDisplayMode": fishDisplayMode = Int(value) ?? 0
        case "useZeroInsteadOfDot": useZero = value == "true"
        default: searchOptions[key] = value
        }
    }
}

enum NativeSolverSection: String {
    case solver, steps, allSteps, progress, training

    func includes(_ rule: NativeSolverConfig.Rule) -> Bool {
        guard !["GIVE_UP", "INCOMPLETE"].contains(rule.kind) else { return false }
        switch self {
        case .progress: return rule.level <= 4
        case .training: return rule.enabled
        case .allSteps: return rule.kind != "BRUTE_FORCE" && !NativeFineHints.fish(rule.kind)
        default: return true
        }
    }
    var optionGroups: [(String, [SolverOption])] {
        switch self { case .allSteps: return SolverOption.allGroups; case .steps: return SolverOption.groups; default: return [] }
    }

    static let ssts = [("FULL_HOUSE", 100), ("NAKED_SINGLE", 200), ("HIDDEN_SINGLE", 300), ("LOCKED_PAIR", 1000),
        ("NAKED_PAIR", 1100), ("LOCKED_CANDIDATES", 1200), ("LOCKED_TRIPLE", 1300), ("NAKED_TRIPLE", 1400),
        ("NAKED_QUADRUPLE", 1500), ("HIDDEN_PAIR", 1600), ("X_WING", 2000), ("SWORDFISH", 2100),
        ("SIMPLE_COLORS", 2200), ("MULTI_COLORS", 2300), ("HIDDEN_TRIPLE", 2400), ("XY_WING", 2500),
        ("HIDDEN_QUADRUPLE", 2600)]
}

extension NativeWorkspacePreferences {
    mutating func changeSolver(_ config: NativeSolverConfig, _ mutate: (inout NativeSolverConfig) -> Void) {
        var next = config
        mutate(&next)
        var edits = solverEdits ?? NativeSolverOverrides()
        for (old, rule) in zip(config.rules, next.rules) where old != rule { edits.rules[rule.kind] = rule }
        for key in SolverOption.byKey.keys where next.option(key) != config.option(key) {
            edits.options[key] = next.option(key)
        }
        if !edits.rules.isEmpty || !edits.options.isEmpty { solverEdits = edits }
    }

    mutating func restoreSolverPage(_ page: NativeSolverSection, config: NativeSolverConfig) {
        let defaults = Dictionary(uniqueKeysWithValues: NativeSolverConfig.standard.rules.map { ($0.kind, $0) })
        if page == .training {
            let enabled = Set(config.rules.filter(page.includes).map(\.kind))
            training.subtract(enabled)
            for row in LegacySettingsDefaults.rows where row[9] == "1" && enabled.contains(row[0]) { training.insert(row[0]) }
            return
        }
        changeSolver(config) { next in
            for i in next.rules.indices where page.includes(next.rules[i]) {
                guard let old = defaults[next.rules[i].kind] else { continue }
                switch page {
                case .solver:
                    next.rules[i].index = old.index; next.rules[i].enabled = old.enabled
                    next.rules[i].score = old.score; next.rules[i].level = old.level
                case .allSteps: next.rules[i].allEnabled = old.allEnabled
                case .progress:
                    next.rules[i].progressIndex = old.progressIndex; next.rules[i].progressEnabled = old.progressEnabled
                default: break
                }
            }
            for (_, fields) in page.optionGroups {
                for field in fields { next.apply(option: field.key, value: field.initial) }
            }
        }
    }
}

extension NativeSolverConfig {
    mutating func progressPreset(level: Int?) {
        for i in rules.indices where NativeSolverSection.progress.includes(rules[i]) {
            rules[i].progressEnabled = level.map { rules[i].enabled && rules[i].level <= $0 } ?? false
        }
        guard level == nil else { return }
        for (kind, index) in NativeSolverSection.ssts {
            guard let i = rules.firstIndex(where: { $0.kind == kind }) else { continue }
            if let j = rules.firstIndex(where: { $0.kind != kind && $0.progressIndex == index }) {
                rules[j].progressIndex = rules[i].progressIndex
            }
            rules[i].progressIndex = index
            rules[i].progressEnabled = rules[i].enabled
        }
    }
}

struct NativeProgressScore: Equatable {
    var directSingles = 0
    var singles = 0
    var score: Int32 = 0

    /// SudokuSolver.getProgressScore applies the selected instance first. Its
    /// score counts only subsequent steps and uses the progress order.
    static func evaluate(_ step: NativeHintStep, on source: NativeBoardSnapshot, config: NativeSolverConfig,
                         cancelled: () -> Bool) throws -> Self {
        guard var board = step.applying(to: source) else { throw NativeHintError.engine }
        let kind = step.technique.key
        let placements = ["FORCING_CHAIN_VERITY", "FORCING_NET_VERITY", "TEMPLATE_SET"].contains(kind)
            ? step.logical?.indices.count ?? 0 : 0
        var result = Self(directSingles: placements, singles: placements)
        var direct = true
        let scores = Dictionary(config.rules.map { ($0.kind, Int32(clamping: $0.score)) }, uniquingKeysWith: { old,_ in old })
        var lookup = config
        // FindAllSteps disables template pre-checks while scoring the resulting board.
        lookup.apply(option: "checkTemplates", value: "false")
        var charged: Int32 = 0
        while board.values.contains(0) {
            if cancelled() { throw CancellationError() }
            let path = try NativeLogicalEngine.rate(board, config: lookup, firstOnly: true, progress: true, cancelled: cancelled)
            if path.ending == .cancelled { throw CancellationError() }
            guard path.ending != .unsupported && path.ending != .unrated && path.ending != .contradiction else { throw NativeHintError.engine }
            guard let follow = path.steps.first else { break }
            charged &+= Int32(clamping: path.score)
            if charged >= lookup.thresholds[5] { break }
            if ["FULL_HOUSE","NAKED_SINGLE","HIDDEN_SINGLE"].contains(follow.kind) {
                result.singles += 1
                if direct { result.directSingles += 1 }
            } else { direct = false }
            result.score &+= scores[follow.trainingKey] ?? scores[follow.kind] ?? 0
            if follow.kind == "GIVE_UP" { break }
            guard let next = follow.applying(to: board) else { throw NativeHintError.engine }
            board = next
        }
        return result
    }
}
