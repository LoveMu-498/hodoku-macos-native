// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// The exact painted nodes and relations used for exact chain matching.
struct NativeFineChain: Equatable {
  let nodes: [[Int]]
  let links: [Bool]
  let closed: Bool
  var cells: Set<Int> { Set(nodes.flatMap { $0.map { $0 / 10 } }) }

  init?(authored: ChainToolState, board: NativeBoardSnapshot) {
    guard let path = authored.assembled() else { return nil }
    nodes = path.nodes.map(\.atoms)
    links = path.edges.map(\.strong)
    closed = path.closed
    guard nodes.allSatisfy({ atoms in
      atoms.count <= 3 && Set(atoms.map { $0 % 10 }).count == 1
        && atoms.allSatisfy { atom in
          board.values[atom / 10] == 0
            && board.candidates[atom / 10] & NativeBoardSnapshot.bit(UInt8(atom % 10)) != 0
        }
    }) else { return nil }
    let complete = Self.ordinaryGroups(board)
    for index in links.indices where links[index] {
      let covered = Set(nodes[index] + nodes[(index + 1) % nodes.count])
      guard complete.contains(where: { $0.isSubset(of: covered) }) else { return nil }
    }
  }

  private static func ordinaryGroups(_ board: NativeBoardSnapshot) -> [Set<Int>] {
    var cells: [Set<Int>] = []
    var houses = Array(repeating: Set<Int>(), count: 243)
    var placed = Set<Int>()
    for cell in 0..<81 {
      let units = [cell / 9, 9 + cell % 9, 18 + cell / 27 * 3 + cell % 9 / 3]
      let value = Int(board.values[cell])
      if value != 0 {
        for h in units { placed.insert(h * 9 + value - 1) }
      } else {
        var atoms = Set<Int>()
        for d in 1...9 where board.candidates[cell] & NativeBoardSnapshot.bit(UInt8(d)) != 0 {
          let atom = cell * 10 + d
          atoms.insert(atom)
          for h in units { houses[h * 9 + d - 1].insert(atom) }
        }
        if !atoms.isEmpty { cells.append(atoms) }
      }
    }
    for i in houses.indices where !placed.contains(i) && !houses[i].isEmpty { cells.append(houses[i]) }
    return cells
  }

  func matches(_ step: NativeLogicalStep) -> Bool {
    guard step.chains.count == 1, let chain = step.chains.first, chain.count >= 2 else { return false }
    var proof: [[Int]] = []
    for raw in chain {
      guard raw > 0 else { return false }
      let e = Int(raw), kind = (e >> 26) & 3, digit = e & 15
      guard (1...9).contains(digit), kind <= 1 else { return false }
      var cells = [(e >> 5) & 127]
      if kind == 1 {
        cells.append((e >> 12) & 127)
        let third = (e >> 19) & 127
        if third != 127 { cells.append(third) }
      }
      guard cells.allSatisfy({ $0 < 81 }), Set(cells).count == cells.count else { return false }
      proof.append(cells.sorted().map { $0 * 10 + digit })
    }
    let repeats = proof.first == proof.last
    let loopTypes = ["CONTINUOUS_NICE_LOOP", "DISCONTINUOUS_NICE_LOOP",
                     "GROUPED_CONTINUOUS_NICE_LOOP", "GROUPED_DISCONTINUOUS_NICE_LOOP"]
    guard closed == (repeats || loopTypes.contains(step.kind)) else { return false }
    if repeats { proof.removeLast() }
    let count = proof.count
    guard count == nodes.count, Set(proof).count == count else { return false }
    var relations = chain.dropFirst().map { $0 & 16 != 0 }
    if closed && !repeats { relations.append(chain[0] & 16 != 0) }
    if !closed {
      return nodes == proof && links == relations
        || nodes.elementsEqual(proof.reversed()) && links.elementsEqual(relations.reversed())
    }
    guard let start = proof.firstIndex(of: nodes[0]) else { return false }
    for direction in [1, -1] {
      let equal = nodes.indices.allSatisfy { i in
        let j = (start + count + direction * i) % count
        let edge = direction > 0 ? j : (j + count - 1) % count
        return nodes[i] == proof[j] && links[i] == relations[edge]
      }
      if equal { return true }
    }
    return false
  }
}
