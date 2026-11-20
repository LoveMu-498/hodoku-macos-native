// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// FineHintMatcher, ReasoningStepIndex, and NativeReasoningMatcher.BOX_PRIORITY.
enum NativeFineHints {
  enum Scope: Equatable {
    case digits(Set<UInt8>)
    case chain(NativeFineChain)
    case boxes(Set<Int>, active: Bool, allowPartial: Bool, groups: [Set<Int>] = [])
  }
  static let priority = """
    NAKED_SINGLE HIDDEN_SINGLE NAKED_PAIR NAKED_TRIPLE NAKED_QUADRUPLE HIDDEN_PAIR HIDDEN_TRIPLE HIDDEN_QUADRUPLE
    LOCKED_PAIR LOCKED_TRIPLE LOCKED_CANDIDATES_1 LOCKED_CANDIDATES_2 X_WING FINNED_X_WING SASHIMI_X_WING
    SWORDFISH FINNED_SWORDFISH SASHIMI_SWORDFISH JELLYFISH FINNED_JELLYFISH SASHIMI_JELLYFISH
    SKYSCRAPER TWO_STRING_KITE EMPTY_RECTANGLE XY_WING XYZ_WING W_WING XY_CHAIN REMOTE_PAIR ALS_XZ ALS_XY_WING
    ALS_XY_CHAIN SUE_DE_COQ GROUPED_AIC GROUPED_NICE_LOOP
    """.split(whereSeparator: { $0.isWhitespace }).map(String.init)
  static let manualFish = Set(priority[12...20])
  static let singles: Set<String> = ["FULL_HOUSE", "NAKED_SINGLE", "HIDDEN_SINGLE"]
  static let indexedPremises: Set<String> = [
    "NAKED_PAIR", "NAKED_TRIPLE", "NAKED_QUADRUPLE", "HIDDEN_PAIR", "HIDDEN_TRIPLE",
    "HIDDEN_QUADRUPLE", "LOCKED_PAIR", "LOCKED_TRIPLE", "LOCKED_CANDIDATES_1",
    "LOCKED_CANDIDATES_2", "SKYSCRAPER", "TWO_STRING_KITE", "DUAL_TWO_STRING_KITE",
    "EMPTY_RECTANGLE", "DUAL_EMPTY_RECTANGLE", "XY_WING", "XYZ_WING", "W_WING", "SUE_DE_COQ",
  ]
  static let als: Set<String> = ["ALS_XZ", "ALS_XY_WING", "ALS_XY_CHAIN", "DEATH_BLOSSOM"]
  static let singleDigit = singles.union([
    "LOCKED_CANDIDATES_1", "LOCKED_CANDIDATES_2", "SKYSCRAPER", "TWO_STRING_KITE",
    "DUAL_TWO_STRING_KITE", "EMPTY_RECTANGLE", "DUAL_EMPTY_RECTANGLE", "TURBOT_FISH", "X_CHAIN",
    "SIMPLE_COLORS_WRAP", "SIMPLE_COLORS_TRAP", "MULTI_COLORS_1", "MULTI_COLORS_2",
  ])
  private static func supportsSingleDigit(_ kind: String) -> Bool {
    singleDigit.contains(kind) || kind == "SIMPLE_COLORS" || kind == "MULTI_COLORS" || fish(kind)
  }
  static func fish(_ name: String) -> Bool {
    ["X_WING", "SWORDFISH", "JELLYFISH", "SQUIRMBAG", "WHALE", "LEVIATHAN"].contains {
      name.hasSuffix($0)
    }
  }
  static func rectangle(_ name: String) -> Bool {
    name.hasPrefix("UNIQUENESS_") || name.hasPrefix("AVOIDABLE_RECTANGLE_")
      || name == "HIDDEN_RECTANGLE"
  }
  static func types(_ kind: String) -> [String] {
    switch kind {
    case "SIMPLE_COLORS": return [kind]
    case "MULTI_COLORS": return [kind]
    case "TWO_STRING_KITE": return [kind, "DUAL_TWO_STRING_KITE"]
    case "EMPTY_RECTANGLE": return [kind, "DUAL_EMPTY_RECTANGLE"]
    case "GROUPED_NICE_LOOP":
      return ["GROUPED_AIC", "GROUPED_CONTINUOUS_NICE_LOOP", "GROUPED_DISCONTINUOUS_NICE_LOOP"]
    case "NICE_LOOP": return ["AIC", "CONTINUOUS_NICE_LOOP", "DISCONTINUOUS_NICE_LOOP"]
    case "FORCING_NET", "FORCING_CHAIN": return [kind + "_CONTRADICTION", kind + "_VERITY"]
    case "KRAKEN_FISH": return ["KRAKEN_FISH_TYPE_1", "KRAKEN_FISH_TYPE_2"]
    default: return [kind]
    }
  }

  struct Match {
    let step: NativeHintStep
    let partial: Bool
  }
  static func lookup(
    _ scope: Scope, board: NativeBoardSnapshot, config: NativeSolverConfig,
    preferredDigit: UInt8? = nil, preparingSingles: Bool = false, cancelled: () -> Bool
  ) throws -> NativeHintStep? {
    try collect(scope, board: board, config: config, preferredDigit: preferredDigit,
      firstOnly: true, preparingSingles: preparingSingles, cancelled: cancelled).first?.step
  }
  static func search(
    _ scope: Scope, board: NativeBoardSnapshot, config: NativeSolverConfig,
    preferredDigit: UInt8? = nil, cancelled: () -> Bool
  ) throws -> Match? {
    try collect(scope, board: board, config: config, preferredDigit: preferredDigit,
      firstOnly: true, cancelled: cancelled).first
  }

  static func matches(
    _ scope: Scope, board: NativeBoardSnapshot, config: NativeSolverConfig,
    preferredDigit: UInt8? = nil, cancelled: () -> Bool
  ) throws -> [NativeHintStep] {
    try collect(scope, board: board, config: config, preferredDigit: preferredDigit,
      firstOnly: false, cancelled: cancelled).map(\.step)
  }

  private static func collect(
    _ scope: Scope, board: NativeBoardSnapshot, config: NativeSolverConfig,
    preferredDigit: UInt8?, firstOnly: Bool, preparingSingles: Bool = false, cancelled: () -> Bool
  ) throws -> [Match] {
    var policy = config
    let box: Bool
    var focus: Scope?
    switch scope {
    case .digits(let ds):
      guard (1...2).contains(ds.count) else { return [] }
      policy.searchOptions["fineProofDigits"] = ds.sorted().map(String.init).joined(separator: ",")
      box = false
    case .chain(let path):
      policy.searchOptions["fineProofCells"] = path.cells.sorted().map(String.init).joined(separator: ",")
      box = false
    case .boxes(let cs, _, _, _):
      guard !cs.isEmpty, cs.allSatisfy({ (0..<81).contains($0) && board.values[$0] == 0 }) else {
        return []
      }
      policy.searchOptions["fineProofCells"] = cs.sorted().map(String.init).joined(separator: ",")
      box = true
      if let digit = preferredDigit, (1...9).contains(digit),
         cs.allSatisfy({ board.candidates[$0] & NativeBoardSnapshot.bit(digit) != 0 }) {
        focus = .digits([digit])
      }
    }
    var eligible = [(String, Int, Int)]()
    for rule in policy.rules {
      for kind in types(rule.kind) {
        guard rule.allEnabled || fish(kind) else { continue }
        guard
          !["GIVE_UP", "INCOMPLETE", "BRUTE_FORCE", "TEMPLATE_SET", "TEMPLATE_DEL", "BUG_PLUS_1"]
            .contains(kind)
        else { continue }
        if case .chain = scope {
          // A Death Blossom records petals, restricted commons and a stem. It
          // supplies no ordered chain for NativeFineChain.matches to compare.
          if kind == "DEATH_BLOSSOM" { continue }
          guard als.contains(kind) || ["TURBOT_FISH", "X_CHAIN", "XY_CHAIN", "REMOTE_PAIR", "AIC", "GROUPED_AIC"].contains(kind)
            || kind.contains("NICE_LOOP") || kind.hasPrefix("KRAKEN_FISH") || kind.hasPrefix("FORCING_")
          else { continue }
        }
        if case .digits(let ds) = scope {
          guard
            ds.count == 1
              ? supportsSingleDigit(kind) : rectangle(kind) || kind == "XY_WING"
          else { continue }
        }
        let rankKind =
          ["GROUPED_CONTINUOUS_NICE_LOOP", "GROUPED_DISCONTINUOUS_NICE_LOOP"].contains(kind)
          ? "GROUPED_NICE_LOOP" : kind
        eligible.append(
          (kind, box ? priority.firstIndex(of: rankKind) ?? priority.count : 0, rule.index))
      }
    }
    eligible.sort { ($0.1, $0.2) < ($1.1, $1.2) }
    let preferred = focus.map { digitScope in
      eligible.filter { supportsSingleDigit($0.0) }.map { ($0, Optional(digitScope)) }
    } ?? []
    var result = [Match]()
    var fallback = [(step: NativeLogicalStep, grade: Int, priority: Int, index: Int, roleCount: Int)]()
    func append(_ step: NativeLogicalStep, partial: Bool = false) {
      let hint = step.hint()
      if hint.applying(to: board) != nil && !result.contains(where: { $0.step == hint }) {
        result.append(Match(step: hint, partial: partial))
      }
    }
    var singleBudget = 3
    for ((kind, priority, index), digitScope) in preferred + eligible.map({ ($0, nil) }) {
      var whole = [(step: NativeLogicalStep, roles: Int)]()
      if cancelled() { return [] }
      // Preparation walks the actual foreground order. Skipping an expensive earlier
      // family could return the wrong first proof, as could promoting a fallback.
      if preparingSingles {
        guard singles.contains(kind), singleBudget > 0 else { return [] }
        singleBudget -= 1
      }
      var searches = [policy]
      if manualFish.contains(kind) {
        var manual = policy
        manual.searchOptions.merge([
          "allStepsSearchFish": "true", "allStepsMinFishSize": "2", "allStepsMaxFishSize": "4",
          "allStepsMaxFishType": "0", "allStepsMaxFins": "5", "allStepsMaxEndoFins": "2",
          "allStepsFishCandidates": "111111111",
        ]) { _, new in new }
        searches.append(manual)
      }
      for settings in searches {
        let path = try NativeLogicalEngine.rate(
          board, config: settings, only: kind, catalogue: true, cancelled: cancelled)
        for step in path.steps where step.kind == kind || step.trainingKey == kind {
          let grade = match(step, scope, board)
          guard grade > 0 else { continue }
          if let digitScope {
            if grade == 3, match(step, digitScope, board) == 3 {
              append(step)
              if firstOnly && !result.isEmpty { return result }
            }
            continue
          }
          var roleCount = 0
          if case .boxes(_, _, false, let groups) = scope, als.contains(step.kind), !groups.isEmpty {
            let roles = step.alsCells.map(Set.init)
            roleCount = groups.filter { !$0.isEmpty && roles.contains($0) }.count
            if grade == 3 {
              whole.append((step, roleCount))
              continue
            }
          }
          if grade == 3 {
            append(step)
            if firstOnly && !result.isEmpty { return result }
          } else {
            fallback.append((step, grade, priority, index, roleCount))
          }
        }
      }
      for item in whole.sorted(by: { $0.roles > $1.roles }) {
        append(item.step)
        if firstOnly && !result.isEmpty { return result }
      }
    }
    if cancelled() { return [] }
    for item in fallback.sorted(by: {
      (-$0.grade, $0.priority, $0.index, -$0.roleCount) < (-$1.grade, $1.priority, $1.index, -$1.roleCount)
    }) {
      append(item.step, partial: item.grade == 1)
      if firstOnly && !result.isEmpty { return result }
    }
    return result
  }

  static func match(_ s: NativeLogicalStep, _ scope: Scope, _ board: NativeBoardSnapshot) -> Int {
    func live(_ c: Int, _ d: UInt8) -> Bool {
      (0..<81).contains(c) && (1...9).contains(d) && board.values[c] == 0
        && board.candidates[c] & NativeBoardSnapshot.bit(d) != 0
    }
    guard
      !s.deletes.isEmpty
        ? s.deletes.allSatisfy({ live($0.cell, $0.digit) })
        : !s.indices.isEmpty && !s.values.isEmpty
          && s.indices.enumerated().allSatisfy({
            live($0.element, s.values[min(s.values.count - 1, $0.offset)])
          })
    else { return 0 }
    if case .chain(let path) = scope { return path.matches(s) ? 3 : 0 }
    var premise = Set<Int>()
    var singleChain = true
    if indexedPremises.contains(s.kind) || fish(s.kind) || rectangle(s.kind) {
      for c in s.indices where s.values.contains(where: { live(c, $0) }) { premise.insert(c) }
    }
    for p in s.fins + s.endoFins where live(p.cell, p.digit) { premise.insert(p.cell) }
    for c in s.colors.keys where s.values.contains(where: { live(c, $0) }) { premise.insert(c) }
    for group in s.alsCells { premise.formUnion(group) }
    for chain in s.chains {
      if chain.count < 2 { singleChain = false }
      for raw in chain {
        if raw == .min {
          singleChain = false
          continue
        }
        let entry = abs(Int(raw))
        let mode = (entry >> 26) & 3
        let d = UInt8(entry & 15)
        if raw <= 0 || mode > 1 || d != s.values.first { singleChain = false }
        if mode == 2 { continue }
        guard mode <= 1 else { return 0 }
        for shift in mode == 1 ? [5, 12, 19] : [5] {
          let c = (entry >> shift) & 127
          if shift == 19 && c == 127 { continue }
          if live(c, d) { premise.insert(c) } else { singleChain = false }
        }
      }
    }
    switch scope {
    case .digits(let ds):
      if ds.count == 1, let d = ds.first {
        let roles = s.fins + s.endoFins + s.cannibalistic
        return (singleDigit.contains(s.kind) || fish(s.kind)) && s.alsCells.isEmpty
          && Set(s.values) == ds && s.deletes.allSatisfy { $0.digit == d }
          && roles.allSatisfy { $0.digit == d && live($0.cell, d) }
          && s.indices.allSatisfy { live($0, d) } && s.colors.keys.allSatisfy { live($0, d) }
          && singleChain ? 3 : 0
      }
      guard ds.count == 2 else { return 0 }
      if s.kind == "XY_WING", s.indices.count == 3, Set(s.indices).count == 3, s.values.count == 3,
        Set(s.values).count == 3
      {
        return Set(s.values.prefix(2)) == ds
          && board.candidates[s.indices[0]] == ds.reduce(0) { $0 | NativeBoardSnapshot.bit($1) }
          ? 3 : 0
      }
      // The Rust uniqueness catalogue validates uniqueness, fixed/givens,
      // rectangle geometry and the configured missing-candidate rule.
      return rectangle(s.kind) && Set(s.values) == ds && Set(s.indices).count == 4 ? 3 : 0
    case .chain: return 0  // Handled before indexing box premises.
    case .boxes(let cs, let active, let partial, _):
      if singles.contains(s.kind) { return Set(s.indices) == cs && cs.count == 1 ? 3 : 0 }
      if als.contains(s.kind) {
        let roles = s.alsCells.map(Set.init)
        if (partial ? premise : Set(roles.flatMap { $0 })) == cs { return 3 }
        if active && roles.contains(cs) { return 2 }
        if partial && roles.contains(where: { cs.isSubset(of: $0) }) { return 1 }
        return 0
      }
      if premise == cs { return 3 }
      return partial && !cs.isEmpty && cs.isSubset(of: premise) ? 1 : 0
    }
  }
}
