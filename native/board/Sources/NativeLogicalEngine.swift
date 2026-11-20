// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import HodokuEngine

struct NativeSolverConfig: Equatable {
  struct Rule: Codable, Equatable {
    var kind: String
    var index, progressIndex, level, score: Int
    var enabled, progressEnabled, allEnabled: Bool
  }
  var rules: [Rule]
  var thresholds: [Int32]
  var useZero = false
  var fishDisplayMode = 0
  var allowMissing = true
  var allowOverlap = false
  var onlyOneALS = true
  var searchOptions = [String: String]()
  static let optionKeys = [
    "krakenMaxFishType", "krakenMaxFishSize", "maxKrakenFins", "maxKrakenEndoFins",
    "allStepsAllowAlsOverlap", "allStepsOnlyOneAlsPerStep", "allStepsAlsChainForwardOnly",
    "allStepsAlsChainLength",
    "restrictChainSize", "restrictChainLength", "allowErsWithOnlyTwoCandidates",
    "allowDualsAndSiamese",
    "maxFins", "maxEndoFins", "checkTemplates", "onlyOneFishPerStep", "allStepsSearchFish",
    "allStepsMinFishSize", "allStepsMaxFishSize", "allStepsMaxFishType", "allStepsMaxFins",
    "allStepsMaxEndoFins", "allStepsCheckTemplates", "allStepsFishCandidates",
    "maxTableEntryLength", "anzTableLookAhead", "onlyOneChainPerStep",
    "allStepsKrakenMaxFishType", "allStepsKrakenMinFishSize", "allStepsKrakenMaxFishSize",
    "allStepsMaxKrakenFins",
    "allStepsMaxKrakenEndoFins", "allStepsKrakenFishCandidates", "allowAlsInTablingChains",
    "allStepsAllowAlsInTablingChains",
  ]
  static let standard: Self = {
    let rules = LegacySettingsDefaults.rows.map { row in
      Rule(
        kind: row[0], index: Int(row[1])!, progressIndex: Int(row[2])!, level: Int(row[3])!,
        score: Int(row[4])!, enabled: row[6] == "1", progressEnabled: row[8] == "1",
        allEnabled: row[7] == "1")
    }
    return Self(rules: rules, thresholds: [0, 800, 1000, 1600, 1800, .max])
  }()

  static func read(_ preferences: NativeWorkspacePreferences) throws -> Self {
    var result = try baseline(preferences.legacyXML)
    if let edits = preferences.solverEdits {
      try edits.validate()
      result.rules = result.rules.map { edits.rules[$0.kind] ?? $0 }
      for (key, value) in edits.options { result.apply(option: key, value: value) }
    }
    if let visual = preferences.visual { result.thresholds = visual.levels.map(\.maxScore) }
    // Options.readOptions repairs legacy difficulty bands in ascending order.
    for i in 2..<result.thresholds.count where result.thresholds[i] <= result.thresholds[i - 1] {
      let (next, overflow) = result.thresholds[i - 1].addingReportingOverflow(100)
      guard !overflow else { throw BoardFileError.invalid }
      result.thresholds[i] = next
    }
    return result
  }

  private static func baseline(_ data: Data?) throws -> Self {
    guard let xml = data else { return standard }
    var config = standard
    let objects = try LegacySessionXML.objects(xml)
    guard objects.count == 1, let opts = objects.first, opts.className == "sudoku.Options" else {
      throw BoardFileError.invalid
    }
    config.useZero = try opts.flag("useZeroInsteadOfDot", false)
    config.fishDisplayMode = try opts.number("fishDisplayMode", 0)
    config.allowMissing = try opts.flag("allowUniquenessMissingCandidates", true)
    config.onlyOneALS = try opts.flag("onlyOneAlsPerStep", true)
    config.allowOverlap = try opts.flag("allowAlsOverlap", false)
    for key in optionKeys {
      if let value = opts[key]?.scalar { config.searchOptions[key] = value }
    }
    for (i, bean) in opts["orgSolverSteps"]?.indexed ?? [:] {
      guard config.rules.indices.contains(i) else { throw BoardFileError.invalid }
      let old = config.rules[i]
      config.rules[i] = try Rule(
        kind: bean["type"]?.scalar ?? old.kind, index: bean.number("index", old.index),
        progressIndex: bean.number("indexProgress", old.progressIndex),
        level: bean.number("level", old.level),
        score: bean.number("baseScore", old.score), enabled: bean.flag("enabled", old.enabled),
        progressEnabled: bean.flag("enabledProgress", old.progressEnabled),
        allEnabled: bean.flag("allStepsEnabled", old.allEnabled))
    }
    for (i, bean) in opts["difficultyLevels"]?.indexed ?? [:] {
      guard config.thresholds.indices.contains(i),
        let limit = Int32(exactly: try bean.number("maxScore", Int(config.thresholds[i])))
      else { throw BoardFileError.invalid }
      config.thresholds[i] = limit
    }
    return config
  }

  func requestedLevel(_ selection: Int, mode: String, training: Set<String>) -> Int {
    guard mode != "PLAYING" else { return selection }
    return rules.filter { training.contains($0.kind) }.reduce(selection) { max($0, $1.level) }
  }

  func wire(progress: Bool, training: Set<String>, only: String? = nil) -> String {
    let enabled = rules.enumerated().filter { row in
      if let kind = only { return row.element.kind == kind }
      return progress ? row.element.progressEnabled : row.element.enabled
    }.sorted { a, b in
      let x = progress ? a.element.progressIndex : a.element.index
      let y = progress ? b.element.progressIndex : b.element.index
      return x == y ? a.offset < b.offset : x < y
    }
    var rows = enabled.map { _, r in
      "\(r.kind),\(r.level),\(r.score),\(training.contains(r.kind) ? 1 : 0)"
    }
    if let only = only, rows.isEmpty { rows.append("\(only),0,0,0") }
    rows.append(
      contentsOf: searchOptions.keys.sorted().compactMap { key in
        searchOptions[key].map { "%" + key + "=" + $0 }
      })
    rows.append(contentsOf: training.sorted().map { "@" + $0 })
    return rows.joined(separator: "\n")
  }
}

struct NativeLogicalStep: Equatable {
  struct Candidate: Equatable {
    let cell: Int
    let digit: UInt8
  }
  var fishDisplayMode = 0
  let kind, trainingKey: String
  let indices: [Int]
  let values: [UInt8]
  var deletes: [Candidate]
  let fins, endoFins, potential, cannibalistic: [Candidate]
  let bases, covers: [Int]
  let chains: [[Int32]]
  let house: Int?
  let colors: [Int: Int]
  let entity: [Int]
  let subtype: String?
  let siamese: Bool
  let potentialCannibalistic: [Candidate]
  let alsCells, alsDigits, restricted: [[Int]]

  init(record: Substring) throws {
    let f = record.split(separator: "|", omittingEmptySubsequences: false)
    guard f.count == 20, !f[0].isEmpty else { throw NativeHintError.engine }
    func ints(_ s: Substring, range: ClosedRange<Int>) throws -> [Int] {
      try s.split(separator: ",").map {
        guard let n = Int($0), range.contains(n) else { throw NativeHintError.engine }
        return n
      }
    }
    func pairs(_ s: Substring) throws -> [Candidate] {
      try ints(s, range: 1...809).map {
        guard $0 % 10 != 0 else { throw NativeHintError.engine }
        return Candidate(cell: $0 / 10, digit: UInt8($0 % 10))
      }
    }
    entity = try ints(f[16], range: -1...81)
    guard entity.isEmpty || entity.count == 2 else { throw NativeHintError.engine }
    subtype = f[17].isEmpty ? nil : String(f[17])
    guard f[18] == "0" || f[18] == "1" else { throw NativeHintError.engine }
    siamese = f[18] == "1"
    potentialCannibalistic = try pairs(f[19])
    kind = String(f[0])
    indices = try ints(f[1], range: 0...80)
    values = try ints(f[2], range: 1...9).map(UInt8.init)
    deletes = try pairs(f[3])
    fins = try pairs(f[4])
    endoFins = try pairs(f[5])
    bases = try ints(f[6], range: 0...26)
    covers = try ints(f[7], range: 0...26)
    chains = try f[8].split(separator: ";").map {
      try ints($0, range: Int(Int32.min)...Int(Int32.max)).map(Int32.init)
    }
    potential = try pairs(f[9])
    cannibalistic = try pairs(f[10])
    house = try ints(f[11], range: 0...26).first
    trainingKey = String(f[12])
    var decodedColors = [Int: Int]()
    for pair in f[13].split(separator: ",") {
      let fields = pair.split(separator: ":")
      guard fields.count == 2, let c = Int(fields[0]), (0..<81).contains(c), let k = Int(fields[1])
      else { throw NativeHintError.engine }
      decodedColors[c] = k
    }
    colors = decodedColors
    var cells = [[Int]]()
    var digits = [[Int]]()
    for item in f[14].split(separator: ";") {
      let parts = item.split(separator: ":", omittingEmptySubsequences: false)
      guard parts.count == 2 else { throw NativeHintError.engine }
      cells.append(try ints(parts[0], range: 0...80))
      digits.append(try ints(parts[1], range: 1...9))
    }
    alsCells = cells
    alsDigits = digits
    restricted = try f[15].split(separator: ";").map { try ints($0, range: 0...Int(Int32.max)) }
  }

  func applying(to snapshot: NativeBoardSnapshot) -> NativeBoardSnapshot? {
    var board = snapshot
    if !deletes.isEmpty {
      for candidate in deletes {
        let bit = NativeBoardSnapshot.bit(candidate.digit)
        guard snapshot.values[candidate.cell] == 0, snapshot.candidates[candidate.cell] & bit != 0
        else { return nil }
        board.candidates[candidate.cell] &= ~bit
      }
    } else {
      let broadcast = kind == "TEMPLATE_SET" && values.count == 1
      guard !indices.isEmpty, broadcast || values.count == indices.count else { return nil }
      for (index, cell) in indices.enumerated() {
        let digit = values[broadcast ? 0 : index]
        guard !board.fixed[cell], board.values[cell] == 0,
          board.candidates[cell] & NativeBoardSnapshot.bit(digit) != 0
        else { return nil }
        board.setValue(digit, at: cell)
      }
    }
    return board == snapshot ? nil : board
  }
}

struct NativeLogicalPath {
  enum Ending: UInt32 {
    case solved, stalled, unsupported, rejected, cancelled, firstStep, contradiction, unrated
  }
  let ending: Ending
  let difficulty, score: Int
  let steps: [NativeLogicalStep]
  let missing: String?
  var solved: Bool { ending == .solved }
}

private final class LogicalCall {
  let cancelled: () -> Bool
  var bytes = Data()
  init(_ cancelled: @escaping () -> Bool) { self.cancelled = cancelled }
}

enum NativeLogicalEngine {
  static func rate(
    _ board: NativeBoardSnapshot, config: NativeSolverConfig = .standard, fromClues: Bool = false,
    maxLevel: Int = 5, rejectTooLowScore: Bool = false, training: Set<String> = [],
    firstOnly: Bool = false, progress: Bool = false, only: String? = nil, catalogue: Bool = false,
    cancelled: () -> Bool
  ) throws -> NativeLogicalPath {
    try board.validate()
    guard (1...5).contains(maxLevel), config.thresholds.count == 6 else {
      throw NativeHintError.engine
    }
    let rules = Array(config.wire(progress: progress, training: training, only: only).utf8)
    var result = HodokuLogicResult()
    var flags: UInt32 =
      (fromClues ? 1 : 0) | (rejectTooLowScore ? 2 : 0) | (firstOnly ? 4 : 0)
      | (config.allowMissing ? 0 : 8) | (config.allowOverlap ? 16 : 0)
      | (config.onlyOneALS ? 0 : 32)
    if catalogue { flags |= 64 }
    let bytes = try withoutActuallyEscaping(cancelled) { check -> Data in
      let job = LogicalCall(check)
      let code = withExtendedLifetime(job) {
        hodoku_logic_v1(
          board.values, board.candidates, board.fixed.map { $0 ? 1 : 0 }, 81,
          rules.isEmpty ? [0] : rules, rules.count,
          config.thresholds, 6, UInt32(maxLevel), flags, Unmanaged.passUnretained(job).toOpaque(),
          { p in
            guard let p = p else { return 1 }
            return Unmanaged<LogicalCall>.fromOpaque(p).takeUnretainedValue().cancelled() ? 1 : 0
          },
          { p, b, n in
            guard let p = p, let b = b else { return }
            Unmanaged<LogicalCall>.fromOpaque(p).takeUnretainedValue().bytes = Data(
              bytes: b, count: n)
          },
          &result)
      }
      guard code == 0 else {
        throw code == 1 ? NativeHintError.contradiction : NativeHintError.engine
      }
      return job.bytes
    }
    guard let ending = NativeLogicalPath.Ending(rawValue: result.ending) else { throw NativeHintError.engine }
    // A catalogue with alternative chain proofs can exceed 10 MB. Decode one
    // complete wire record at a time so an edit can interrupt Swift as well as Rust.
    var steps = [NativeLogicalStep]()
    var missing: String?
    let newline = Data([10])
    var start = bytes.startIndex
    while start < bytes.endIndex {
      if catalogue && cancelled() {
        return NativeLogicalPath(ending: .cancelled, difficulty: 0, score: 0, steps: [], missing: nil)
      }
      let end = bytes.range(of: newline, in: start..<bytes.endIndex)?.lowerBound ?? bytes.endIndex
      if end > start {
        guard let record = String(data: bytes[start..<end], encoding: .utf8) else { throw NativeHintError.engine }
        if (ending == .unsupported || ending == .unrated) && end == bytes.endIndex && record.first == "@" {
          missing = String(record.dropFirst())
        } else {
          var step = try NativeLogicalStep(record: record[...])
          step.fishDisplayMode = config.fishDisplayMode
          steps.append(step)
        }
      }
      start = end == bytes.endIndex ? end : end + 1
    }
    return NativeLogicalPath(
      ending: ending, difficulty: Int(result.difficulty), score: Int(result.score),
      steps: steps, missing: missing)
  }
}

extension NativeLogicalStep {
  private var mask: UInt16 { values.reduce(0) { $0 | NativeBoardSnapshot.bit($1) } }
  func nodes(_ chain: [Int32]) -> [(NativeHintReference, String)] {
    var result = [(NativeHintReference, String)]()
    var branch = false
    for entry in chain {
      if entry == .min {
        if branch, !result.isEmpty { result[result.count - 1].1 += "）" }
        branch = false
        continue
      }
      let raw = Int(abs(entry))
      let digit = raw & 15
      let cell = (raw >> 5) & 127
      guard (1...9).contains(digit), cell < 81 else { continue }
      let type = (raw >> 26) & 3
      let als = (raw >> 12) & 0x3fff
      var cells = [cell]
      if type == 1 {
        cells.append(contentsOf: [raw >> 12 & 127, raw >> 19 & 127].filter { $0 < 81 })
      } else if type == 2, alsCells.indices.contains(als) {
        cells = alsCells[als]
      }
      let label = cells.map { NativeHintReference.cell($0).label }.joined(separator: "、")
      let ref = NativeHintReference(
        label: cells.count > 1 ? "〔" + label + "〕" : label,
        cells: cells, digits: NativeBoardSnapshot.bit(UInt8(digit)))
      let sign = result.isEmpty ? "" : (raw & 16 == 0 ? "－" : "＝")
      let prefix = entry < 0 && !branch ? "（分支 " : (entry >= 0 && branch ? "）" : "")
      result.append((ref, prefix + sign + ref.label + "(" + String(digit) + ")"))
      branch = entry < 0
    }
    if branch, !result.isEmpty { result[result.count - 1].1 += "）" }
    return result
  }

  func hint() -> NativeHintStep {
    let technique = NativeHintTechnique(key: kind)
    var cuts = Array(repeating: UInt16(0), count: 81)
    for c in deletes { cuts[c.cell] |= NativeBoardSnapshot.bit(c.digit) }
    let placed = deletes.isEmpty && values.count == 1 ? indices.first : nil
    var premises = indices
    let additional =
      fins.map(\.cell) + endoFins.map(\.cell) + colors.keys.sorted() + alsCells.flatMap { $0 }
      + chains.flatMap { nodes($0).flatMap { $0.0.cells } }
    for cell in additional where !premises.contains(cell) { premises.append(cell) }
    let digits = mask == 0 ? cuts.reduce(0, |) : mask
    var result = NativeHintStep(
      technique: technique, house: house, digits: digits, premises: premises,
      placementCell: placed, placementDigit: placed == nil ? 0 : (values.first ?? 0),
      deletions: cuts)
    if case .logical = technique { result.logical = self }
    return result
  }

  func stages(_ board: NativeBoardSnapshot) -> [NativeHintStage] {
    if let stages = basicAnswerStages(on: board) { return stages }
    var stages = [NativeHintStage]()
    func add(_ title: String, _ refs: [NativeHintReference]) {
      if !refs.isEmpty {
        stages.append(
          .init(title: title, text: refs.map(\.label).joined(separator: "、"), references: refs))
      }
    }
    let name = NativeHintTechnique(key: kind).name
    let positions = indices.map {
      NativeHintReference.cell($0, digits: board.candidates[$0] & mask)
    }
    if let subtype = subtype {
      stages.append(
        .init(title: name, text: NativeHintTechnique(key: subtype).name, references: []))
    }
    if !deletes.isEmpty { add("相关格", positions) }
    if let house = house { add("所在单元", [.house(house)]) }
    if entity.count == 2 {
      let index = entity[1]
      if entity[0] == 3, (0..<81).contains(index) {
        add("矛盾所在格", [.cell(index)])
      } else if (0...2).contains(entity[0]), (0..<9).contains(index) {
        add("矛盾所在单元", [.house([18, 0, 9][entity[0]] + index)])
      }
    }
    add("基础单元", bases.map(NativeHintReference.house))
    add("覆盖单元", covers.map(NativeHintReference.house))
    let showFishStatistics = fishDisplayMode != 0 && NativeFineHints.fish(kind)
    if showFishStatistics {
      let vertices = Set(indices).subtracting(potentialCannibalistic.map(\.cell))
      let exo = Set(fins.map(\.cell)).subtracting(endoFins.map(\.cell))
      let predicted = Set(potential.map(\.cell)).union(potentialCannibalistic.map(\.cell))
      let groups = [("V", vertices), ("XF", exo), ("NF", Set(endoFins.map(\.cell))),
        ("EE", Set(deletes.map(\.cell))), ("CE", Set(cannibalistic.map(\.cell))), ("PE", predicted)]
      let stats = groups.map { key, cells in
        let content = fishDisplayMode == 1 ? String(cells.count) : cells.sorted().map { NativeHintReference.cell($0).label }.joined(separator: "、")
        return key + "(" + content + ")"
      }
      stages.append(.init(title: "鱼形统计", text: stats.joined(separator: "　"),
        references: Set(groups.flatMap { $0.1 }).sorted().map { .cell($0) }))
    }
    func candidates(_ title: String, _ items: [Candidate]) {
      let refs = items.map {
        NativeHintReference.cell($0.cell, digits: NativeBoardSnapshot.bit($0.digit))
      }
      if !refs.isEmpty {
        let text = zip(refs, items).map { $0.0.label + "(" + String($0.1.digit) + ")" }.joined(
          separator: "、")
        stages.append(.init(title: title, text: text, references: refs))
      }
    }
    if !showFishStatistics {
      candidates("鳍候选", fins)
      candidates("内鳍候选", endoFins)
    }
    candidates("自食候选", cannibalistic)
    if siamese { candidates("双鱼共用的潜在自食候选", potentialCannibalistic) }
    for index in alsCells.indices {
      let set = alsDigits[index].reduce(UInt16(0)) { $0 | NativeBoardSnapshot.bit(UInt8($1)) }
      add(
        "几乎锁定集 " + String(index + 1),
        alsCells[index].map { .cell($0, digits: board.candidates[$0] & set) })
    }
    for link in restricted where link.count == 5 {
      let a = link[0]
      let b = link[1]
      guard alsCells.indices.contains(a), alsCells.indices.contains(b) else { continue }
      let active = link[4] == 1 ? [link[2]] : link[4] == 2 ? [link[3]] : Array(link[2...3])
      for digit in active where (1...9).contains(digit) {
        let bit = NativeBoardSnapshot.bit(UInt8(digit))
        let cells = (alsCells[a] + alsCells[b]).filter { board.candidates[$0] & bit != 0 }
        add(
          "集合 " + String(a + 1) + " 与 " + String(b + 1) + " 的受限公共候选 " + String(digit),
          cells.map { .cell($0, digits: bit) })
      }
    }
    for color in Set(colors.values).sorted() {
      add(
        "色组 " + String(color + 1),
        colors.keys.filter { colors[$0] == color }.sorted().map { .cell($0, digits: mask) })
    }
    for chain in chains {
      let links = nodes(chain)
      if !links.isEmpty {
        stages.append(
          .init(title: "推理链", text: links.map(\.1).joined(), references: links.map(\.0)))
      }
    }
    let conclusions = deletes.map {
      NativeHintReference.cell($0.cell, digits: NativeBoardSnapshot.bit($0.digit), removal: true)
    }
    let text =
      conclusions.isEmpty
      ? "在 " + positions.map(\.label).joined(separator: "、") + " 填入 "
        + values.map(String.init).joined(separator: "、") + "。"
      : "删除 "
        + zip(conclusions, deletes).map { $0.0.label + " 的 " + String($0.1.digit) }.joined(
          separator: "，") + "。"
    stages.append(
      .init(title: name, text: text, references: conclusions.isEmpty ? positions : conclusions))
    return stages
  }
}
