// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

extension ChainToolState {
  /// 1 = weak, 2 = strong and weak, 3 = strong only (an independently established premise).
  func previewRelations(
    board: NativeBoardSnapshot, boxes: BoxToolState = .init(), ink: InkToolState = .init()
  ) -> [ChainToolNode: Int] {
    guard let index = active, !paths[index].closed, let origin = paths[index].nodes.last else {
      return [:]
    }
    let path = paths[index]
    let source = Set(origin.atoms)
    func present(_ atom: Int) -> Bool {
      board.values[atom / 10] == 0
        && board.candidates[atom / 10] & NativeBoardSnapshot.bit(UInt8(atom % 10)) != 0
    }
    guard origin.atoms.allSatisfy(present) else { return [:] }
    var complete: [Set<Int>] = []
    var houses = Array(repeating: Set<Int>(), count: 243)
    var targets = Set<[Int]>()
    for cell in 0..<81 where board.values[cell] == 0 {
      let atoms = (1...9).map { cell * 10 + $0 }.filter(present)
      if !atoms.isEmpty { complete.append(Set(atoms)) }
      for a in atoms {
        targets.insert([a])
        for h in [cell / 9, 9 + cell % 9, 18 + cell / 27 * 3 + cell % 9 / 3] {
          houses[h * 9 + a % 10 - 1].insert(a)
        }
      }
    }
    complete.append(contentsOf: houses.filter { !$0.isEmpty })
    for p in paths { for n in p.nodes where n.atoms.count > 1 { targets.insert(n.atoms) } }
    var independentStrong = Set<[Int]>()
    var independentWeak = Set<[Int]>()
    for cells in boxes.groups {
      let empty = cells.filter { board.values[$0] == 0 }
      guard let first = empty.first, !empty.contains(where: { board.candidates[$0] == 0 }),
        empty.allSatisfy({ $0 / 9 == first / 9 }) || empty.allSatisfy({ $0 % 9 == first % 9 })
          || empty.allSatisfy({ $0 / 27 == first / 27 && $0 % 9 / 3 == first % 9 / 3 })
      else { continue }
      var digits: [Int: [Int]] = [:]
      for cell in empty.sorted() {
        for d in 1...9 where present(cell * 10 + d) { digits[d, default: []].append(cell * 10 + d) }
      }
      guard digits.count == empty.count + 1, digits.values.contains(origin.atoms) else { continue }
      independentStrong.formUnion(digits.values.filter { $0 != origin.atoms })
    }
    var trueGroups: [(starts: Set<Int>, negatives: Set<Int>)] = []
    for group in 0..<6 {
      let marks = ink.strokes.filter {
        $0.group == group && !$0.witness && ($0.kind == .circle || $0.kind == .cross)
      }
      func atom(_ s: InkStroke) -> Int { s.cell! * 10 + s.digit! }
      let starts = marks.filter(\.start)
      guard let first = starts.first,
        starts.allSatisfy({ $0.kind == first.kind && present(atom($0)) })
      else { continue }
      let start = Set(starts.map(atom))
      if first.kind == .circle {
        let negatives = Set(
          marks.filter { !$0.start && $0.kind == .cross && present(atom($0)) }.map(atom))
        trueGroups.append((start, negatives))
      }
      if start == source {
        for mark in marks where !mark.start && present(atom(mark)) {
          if first.kind == .cross && mark.kind == .circle { independentStrong.insert([atom(mark)]) }
          if first.kind == .circle && mark.kind == .cross { independentWeak.insert([atom(mark)]) }
        }
      } else if first.kind == .circle && source.isStrictSubset(of: start) {
        independentStrong.insert(start.subtracting(source).sorted())
      }
    }
    // Two other true branches whose negative conclusions cover every member
    // of a third OR start cannot both be true (DoodleDerivedBasis.weakRelations).
    for (i, baseline) in trueGroups.enumerated() {
      for (j, left) in trueGroups.enumerated()
      where i != j && left.starts == source && !left.negatives.isEmpty {
        for (k, right) in trueGroups.enumerated()
        where k != i && k != j && right.starts != source && !right.negatives.isEmpty {
          if baseline.starts.isSubset(of: left.negatives.union(right.negatives)) {
            independentWeak.insert(right.starts.sorted())
          }
        }
      }
    }
    targets.formUnion(independentStrong)
    targets.formUnion(independentWeak)
    let used = Set(path.nodes.flatMap(\.atoms))
    let remaining = complete.map { $0.subtracting(source) }
    var relations: [ChainToolNode: Int] = [:]
    for atoms in targets {
      let target = Set(atoms)
      let close = path.nodes.count >= 3 && path.nodes[0].atoms == atoms
      guard atoms.allSatisfy(present), close || used.isDisjoint(with: target) else { continue }
      let nativeWeak = source.allSatisfy { a in
        target.allSatisfy { b in
          let x = a / 10
          let y = b / 10
          return a != b
            && (x == y
              || a % 10 == b % 10
                && (x / 9 == y / 9 || x % 9 == y % 9 || x / 27 == y / 27 && x % 9 / 3 == y % 9 / 3))
        }
      }
      let weak = nativeWeak || independentWeak.contains(atoms)
      var strong = independentStrong.contains(atoms)
      if nativeWeak {
        if source.count == 1 && target.count == 1 {
          let x = origin.atoms[0] / 10
          let y = atoms[0] / 10
          let d = atoms[0] % 10
          if x == y {
            strong = strong || board.candidates[x].nonzeroBitCount == 2
          } else {
            let covered = target.union(source)
            for h in [x / 9, 9 + x % 9, 18 + x / 27 * 3 + x % 9 / 3]
            where houses[h * 9 + d - 1] == covered { strong = true }
          }
        } else {
          strong = strong || remaining.contains(where: { $0.isSubset(of: target) })
        }
      }
      if weak || strong {
        relations[ChainToolNode(atoms: atoms, color: origin.color)] = strong ? (weak ? 2 : 3) : 1
      }
    }
    return relations
  }
  func previewTargets(
    board: NativeBoardSnapshot, boxes: BoxToolState = .init(), ink: InkToolState = .init()
  ) -> [Int: Bool] {
    var result: [Int: Bool] = [:]
    for (node, r) in previewRelations(board: board, boxes: boxes, ink: ink) {
      let possible = r == 2 || r == (nextStrong ? 3 : 1)
      for a in node.atoms { result[a] = (result[a] ?? false) || possible }
    }
    return result
  }
}

struct ChainToolSession {
  enum PreviewRejection {
    case noTail, noRelation, wrongStrength(nextStrong: Bool), stale

    var message: String {
      switch self {
      case .noTail: return "先选一个可续画的链尾。"
      case .noRelation: return "这个候选数与链尾没有可用的连接。"
      case .wrongStrength(true): return "这里只能接弱链。按空格切换。"
      case .wrongStrength(false): return "这里只能接强链。按空格切换。"
      case .stale: return "这组候选已无法连接。请重新选择。"
      }
    }
  }

  var endpoint: Int?
  private var deleting = false
  private(set) var choices: [ChainToolNode] = []
  private var selectionGroup = 0
  private var selectionState: ChainToolState?
  private var selectionBoard: NativeBoardSnapshot?
  private var previewChoice = false
  private(set) var startingSegment = false
  private(set) var previewRejection: PreviewRejection?

  mutating func reset() { self = Self() }
  mutating func cancelPreviewChoice() {
    if previewChoice { reset() }
  }

  mutating func choose(
    _ n: ChainToolNode, board: NativeBoardSnapshot, state: inout ChainToolState,
    preview: Bool = false, boxes: BoxToolState = .init(), ink: InkToolState = .init()
  ) {
    var rejection: PreviewRejection?
    defer {
      reset()
      previewRejection = rejection
    }
    guard choices.contains(n), selectionState == state, selectionBoard == board else {
      if previewChoice { rejection = .stale }
      return
    }
    if previewChoice {
      guard preview, let relation = state.previewRelations(board: board, boxes: boxes, ink: ink)[n],
        relation == 2 || relation == (state.nextStrong ? 3 : 1)
      else {
        rejection = .stale
        return
      }
    }
    if startingSegment { state.startSegment(at: n) } else { state.append(n, group: selectionGroup) }
  }
  mutating func click(
    _ p: BoardPress, twice: Bool, preciseEligible: Bool, palette: Int, deleteGroup: Int?,
    preview: Bool, board: NativeBoardSnapshot, state: inout ChainToolState,
    boxes: BoxToolState = .init(), ink: InkToolState = .init()
  ) {
    let atom = p.cell.flatMap { c in p.digit.map { c * 10 + $0 } }
    let erase = p.erases
    previewRejection = nil
    if preview && p.button != .left { return }
    let startsNewSegment = !preview && p.startsChainSegment
    if let first = endpoint, !startsNewSegment {
      let wasDeleting = deleting
      reset()
      // A new button cancels the armed endpoint.
      if let second = atom, wasDeleting == erase {
        state.precise(first, second, erase: erase, group: deleteGroup)
      }
      return
    }
    reset()
    if twice && p.modifiers.isEmpty {
      if preciseEligible, let a = atom {
        endpoint = a
        deleting = erase
      } else if erase {
        state.backtrack(deleteGroup: deleteGroup)
      } else {
        state.flipLatest()
      }
      return
    }
    if twice && atom != nil && !(p.modifiers.contains(.shift) && !erase) {
      endpoint = atom
      deleting = erase
      return
    }
    if erase {
      state.backtrack(deleteGroup: deleteGroup)
      return
    }
    guard let a = atom else {
      guard p.cell == nil, !startsNewSegment else { return }
      if p.modifiers.contains(.shift) { state.finish() } else { state.toggleNext() }
      return
    }
    let single = ChainToolNode(atoms: [a], color: palette)
    if preview {
      guard let active = state.active, !state.paths[active].closed else {
        previewRejection = .noTail
        return
      }
      let relations = state.previewRelations(board: board, boxes: boxes, ink: ink)
      let matching = relations.filter { $0.key.atoms.contains(a) }
      let grouped = matching.filter { $0.key.atoms.count > 1 }
      let targets = !p.modifiers.contains(.command) && !grouped.isEmpty
        ? grouped : matching.filter { $0.key.atoms.count == 1 }
      let eligible = targets.filter { $0.value == 2 || $0.value == (state.nextStrong ? 3 : 1) }.keys.sorted {
        $0.atoms.lexicographicallyPrecedes($1.atoms)
      }
      guard let target = eligible.first else {
        previewRejection = targets.isEmpty ? .noRelation : .wrongStrength(nextStrong: state.nextStrong)
        return
      }
      if eligible.count > 1 { choices = eligible }
      else { state.append(target.atoms.count == 1 ? single : target, group: palette) }
    } else if p.modifiers.contains(.shift) {
      if twice {
        state.finish()
        state.append(single, group: palette)
      } else {
        state.append(single, group: palette, expand: true)
      }
    } else {
      let groups = state.groups(at: a)
      if groups.count > 1 {
        choices = [single] + groups
      } else if startsNewSegment {
        state.startSegment(at: groups.first ?? single)
      } else {
        state.append(groups.first ?? single, group: palette)
      }
    }
    if !choices.isEmpty {
      selectionState = state
      selectionBoard = board
      selectionGroup = palette
      previewChoice = preview
      startingSegment = startsNewSegment
    }
  }
}
