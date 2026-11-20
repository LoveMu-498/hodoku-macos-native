// SPDX-License-Identifier: GPL-3.0-or-later
// Port of the authoring rules in SudokuPanel, UserChainAssembly and UserChainCuts.
import CoreGraphics
import Foundation

struct ChainToolNode: Codable, Hashable {
  var atoms: [Int]
  var color: Int
  var label: String {
    atoms.map { a in "R\(a / 10 / 9 + 1)C\(a / 10 % 9 + 1)(\(a % 10))" }.joined(separator: "、")
  }
  static func point(_ atom: Int, _ g: BoardGeometry) -> CGPoint {
    let r = g.rect(atom / 10, digit: atom % 10)
    return CGPoint(x: r.midX, y: r.midY)
  }
  func validate() -> Bool {
    !atoms.isEmpty && atoms == Array(Set(atoms)).sorted()
      && atoms.allSatisfy {
        (0..<81).contains($0 / 10) && (1...9).contains($0 % 10)
      } && (0..<6).contains(color)
  }
}

struct ChainToolEdge: Codable, Equatable {
  var strong: Bool
  var color: Int
}

struct ChainToolPath: Codable, Equatable {
  var nodes: [ChainToolNode]
  var edges: [ChainToolEdge]
  var closed: Bool

  func endpoints(_ i: Int) -> (ChainToolNode, ChainToolNode) {
    (nodes[i], nodes[(i + 1) % nodes.count])
  }
  var valid: Bool {
    !nodes.isEmpty && nodes.allSatisfy { $0.validate() } && (!closed || nodes.count >= 3)
      && edges.count == nodes.count - (closed ? 0 : 1)
      && edges.allSatisfy { (0..<6).contains($0.color) }
  }

  func cut(edges removed: Set<Int>, members: [Int: Set<Int>], deleteGroup: Int?) -> [Self] {
    var copy = self
    var cuts = removed
    for (index, hit) in members where nodes.indices.contains(index) {
      let keep = nodes[index].atoms.filter { !hit.contains($0) }
      if !keep.isEmpty {
        copy.nodes[index].atoms = keep
        continue
      }
      if nodes.count == 1 { return [] }
      if index > 0 { cuts.insert(index - 1) } else if closed { cuts.insert(nodes.count - 1) }
      if index < edges.count { cuts.insert(index) }
    }
    guard !cuts.isEmpty else { return [copy] }
    let start = closed ? ((cuts.min() ?? -1) + 1) % nodes.count : 0
    var parts: [Self] = []
    var fragment: Self?
    for offset in edges.indices {
      let i = (start + offset) % edges.count
      if cuts.contains(i) {
        if let part = fragment { parts.append(part) }
        fragment = nil
      } else {
        let (left, right) = copy.endpoints(i)
        if fragment == nil { fragment = Self(nodes: [left], edges: [], closed: false) }
        fragment!.nodes.append(right)
        fragment!.edges.append(edges[i])
      }
    }
    if let part = fragment { parts.append(part) }
    if let group = deleteGroup {
      for node in nodes
      where node.color != group && !parts.contains(where: { $0.nodes.contains(node) }) {
        parts.append(Self(nodes: [node], edges: [], closed: false))
      }
    }
    return parts
  }

  func rawEndpoints(_ index: Int, in g: BoardGeometry) -> (CGPoint, CGPoint) {
    let (a, b) = endpoints(index)
    var nearest: (CGPoint, CGPoint, CGFloat)?
    for x in a.atoms {
      let p = ChainToolNode.point(x, g)
      for y in b.atoms where x != y {
        let q = ChainToolNode.point(y, g)
        let d = hypot(q.x - p.x, q.y - p.y)
        if nearest == nil || d < nearest!.2 { nearest = (p, q, d) }
      }
    }
    let p = nearest?.0 ?? ChainToolNode.point(a.atoms[0], g)
    let q = nearest?.1 ?? ChainToolNode.point(b.atoms[0], g)
    return (p, q)
  }
}

struct ChainToolAssembly {
  let path: ChainToolPath?
  let problem: String
  var message: String {
    switch problem {
    case "BRANCHED_INPUT": return "链有分支，保留一条连续路径"
    case "CONFLICTING_EDGE": return "同一对节点有两种关系，请保留一种"
    case "DISCONNECTED_INPUT": return "先把链段连起来"
    case "INVALID_GROUP": return "检查链节点对应的候选数"
    default: return "先连起两个候选节点"
    }
  }
}

struct ChainJunctionCounts: Equatable {
  var strong = 0
  var weak = 0
  var hasAmbiguousNodes = false
}

struct ChainToolState: Codable, Equatable {
  var paths: [ChainToolPath] = []
  var active: Int?
  var nextStrong = true

  func validate() throws {
    guard paths.allSatisfy(\.valid), active.map(paths.indices.contains) ?? true else {
      throw BoardFileError.invalid
    }
  }
  mutating func toggleNext() { nextStrong.toggle() }
  mutating func finish() {
    active = nil
    nextStrong = true
  }
  mutating func cancelActive() {
    if let index = active { paths.remove(at: index) }
    finish()
  }

  mutating func startSegment(at node: ChainToolNode) {
    let existingStart = paths.lastIndex { $0.edges.isEmpty && $0.nodes.first?.atoms == node.atoms }
    if let existingStart, existingStart == active { return }
    if active != nil { finish() }
    let adjoiningEdges = paths.compactMap { path -> ChainToolEdge? in
      guard !path.closed else { return nil }
      if path.nodes.last?.atoms == node.atoms { return path.edges.last }
      if path.nodes.first?.atoms == node.atoms { return path.edges.first }
      return nil
    }
    if adjoiningEdges.count == 1 { nextStrong = !adjoiningEdges[0].strong }
    if let existingStart {
      active = existingStart
    } else {
      append(node, group: node.color)
    }
  }

  private struct Link {
    let a, b: [Int]
    let edge: ChainToolEdge
    func other(_ node: [Int]) -> [Int] { node == a ? b : a }
  }

  func assembly() -> ChainToolAssembly { Self.assemble(paths) }
  func assembled() -> ChainToolPath? { assembly().path }

  /// Counts unambiguous junctions across paths, including loop seams and joins between segments.
  func junctionCounts(group: Int? = nil) -> ChainJunctionCounts {
    var adjacency: [[Int]: [[Int]: Set<Bool>]] = [:]
    for path in paths {
      for (index, edge) in path.edges.enumerated() where group == nil || edge.color == group {
        let (a, b) = path.endpoints(index)
        guard a.atoms != b.atoms else { continue }
        adjacency[a.atoms, default: [:]][b.atoms, default: []].insert(edge.strong)
        adjacency[b.atoms, default: [:]][a.atoms, default: []].insert(edge.strong)
      }
    }
    var counts = ChainJunctionCounts()
    for neighbors in adjacency.values {
      guard neighbors.count <= 2, neighbors.values.allSatisfy({ $0.count == 1 }) else {
        counts.hasAmbiguousNodes = true
        continue
      }
      guard neighbors.count == 2 else { continue }
      if neighbors.values.allSatisfy({ $0.contains(true) }) { counts.strong += 1 }
      if neighbors.values.allSatisfy({ $0.contains(false) }) { counts.weak += 1 }
    }
    return counts
  }

  private static func assemble(_ paths: [ChainToolPath]) -> ChainToolAssembly {
    var vertices: [[Int]: ChainToolNode] = [:]
    var neighbors: [[Int]: [Int]] = [:]
    var links: [Link] = []
    var identities: [[[Int]]: Int] = [:]
    func failure(_ kind: String) -> ChainToolAssembly {
      ChainToolAssembly(path: nil, problem: kind)
    }
    for path in paths {
      guard path.valid else { return failure("INVALID_GROUP") }
      for n in path.nodes { vertices[n.atoms] = n }
      for i in path.edges.indices {
        let (a, b) = path.endpoints(i)
        guard a.atoms != b.atoms else { return failure("DUPLICATE_NODE") }
        let id = [a.atoms, b.atoms].sorted { $0.lexicographicallyPrecedes($1) }
        if let previous = identities[id] {
          if links[previous].edge.strong != path.edges[i].strong {
            return failure("CONFLICTING_EDGE")
          }
        } else {
          identities[id] = links.count
          neighbors[a.atoms, default: []].append(links.count)
          neighbors[b.atoms, default: []].append(links.count)
          links.append(Link(a: a.atoms, b: b.atoms, edge: path.edges[i]))
        }
      }
    }
    guard vertices.count >= 2 else { return failure("INCOMPLETE") }
    // Java orders the canonical Arrays.toString keys lexically.
    let ordered = vertices.keys.sorted { $0.description < $1.description }
    var connected = Set<[Int]>()
    var queue = [ordered[0]]
    while let v = queue.popLast() {
      if connected.insert(v).inserted {
        queue.append(contentsOf: (neighbors[v] ?? []).map { links[$0].other(v) })
      }
    }
    guard connected.count == vertices.count else { return failure("DISCONNECTED_INPUT") }
    guard !neighbors.values.contains(where: { $0.count > 2 }) else {
      return failure("BRANCHED_INPUT")
    }
    let ends = ordered.filter { neighbors[$0]?.count == 1 }
    guard ends.isEmpty || ends.count == 2 else { return failure("DISCONNECTED_INPUT") }
    var current = ends.first ?? ordered[0]
    var used = Set<Int>()
    var nodes: [ChainToolNode] = []
    var edges: [ChainToolEdge] = []
    repeat {
      nodes.append(vertices[current]!)
      guard let next = neighbors[current]?.first(where: { !used.contains($0) }) else { break }
      used.insert(next)
      edges.append(links[next].edge)
      current = links[next].other(current)
    } while current != nodes[0].atoms
    return ChainToolAssembly(
      path: ChainToolPath(nodes: nodes, edges: edges, closed: ends.isEmpty), problem: "NONE")
  }

  func groups(at atom: Int) -> [ChainToolNode] {
    var seen = Set<[Int]>()
    return paths.flatMap(\.nodes).filter {
      $0.atoms.count > 1 && $0.atoms.contains(atom) && seen.insert($0.atoms).inserted
    }
  }
  func hasConnected(_ atom: Int) -> Bool {
    paths.contains { !$0.edges.isEmpty && $0.nodes.contains { $0.atoms.contains(atom) } }
  }
  func shouldDelay(_ p: BoardPress) -> Bool {
    guard p.button == .left, let c = p.cell, let d = p.digit else { return false }
    return groups(at: c * 10 + d).count > 1
  }

  mutating func append(_ selected: ChainToolNode, group: Int, expand: Bool = false) {
    var n = selected
    guard let i = active else {
      paths.append(ChainToolPath(nodes: [n], edges: [], closed: false))
      active = paths.count - 1
      return
    }
    guard !paths[i].closed, let tail = paths[i].nodes.last else { return }
    if expand {
      let atoms = Set(tail.atoms).union(n.atoms).sorted()
      guard atoms != tail.atoms else { return }
      for p in paths.indices {
        for j in paths[p].nodes.indices where paths[p].nodes[j].atoms == tail.atoms {
          paths[p].nodes[j].atoms = atoms
        }
      }
      return
    }
    guard paths[i].nodes.last?.atoms != n.atoms else { return }
    let closes = paths[i].nodes.count >= 3 && paths[i].nodes.first?.atoms == n.atoms
    guard closes || !paths[i].nodes.contains(where: { $0.atoms == n.atoms }) else { return }
    n.color = group
    paths[i].edges.append(ChainToolEdge(strong: nextStrong, color: group))
    paths[i].closed = closes
    nextStrong.toggle()
    if !closes {
      paths[i].nodes.append(n)
      joinEndpoints()
    }
  }

  private mutating func joinEndpoints() {
    while let i = active, !paths[i].closed, paths[i].nodes.count >= 2 {
      let live = paths[i]
      let head = live.nodes.first!.atoms
      let tail = live.nodes.last!.atoms
      var joined = false
      for j in paths.indices where j != i && !paths[j].closed && !paths[j].edges.isEmpty {
        let a = paths[j].nodes.first!.atoms
        let b = paths[j].nodes.last!.atoms
        guard [a, b].contains(head) || [a, b].contains(tail),
          var merged = Self.assemble([live, paths[j]]).path
        else { continue }
        let end = tail == a ? b : (tail == b ? a : tail)
        if merged.closed, let first = merged.nodes.firstIndex(where: { $0.atoms == head }) {
          merged.nodes = Array(merged.nodes[first...] + merged.nodes[..<first])
          merged.edges = Array(merged.edges[first...] + merged.edges[..<first])
        } else if merged.nodes.last?.atoms != end {
          merged.nodes.reverse()
          merged.edges.reverse()
        }
        paths[i] = merged
        paths.remove(at: j)
        active = i - (j < i ? 1 : 0)
        nextStrong = !(merged.edges.last?.strong ?? false)
        joined = true
        break
      }
      if !joined { return }
    }
  }

  private var orderedIndices: [Int] {
    paths.indices.filter { $0 != active } + (active.map { [$0] } ?? [])
  }
  private var latestEdge: (Int, Int)? {
    for i in orderedIndices.reversed() where !paths[i].edges.isEmpty {
      return (i, paths[i].edges.count - 1)
    }
    return nil
  }
  var latestIsStrong: Bool? { latestEdge.map { paths[$0.0].edges[$0.1].strong } }

  private mutating func synchronize() {
    nextStrong = latestIsStrong.map { !$0 } ?? true
  }
  mutating func flipLatest() {
    if let (p, e) = latestEdge {
      paths[p].edges[e].strong.toggle()
      synchronize()
    }
  }
  private mutating func applyCut(
    path i: Int, edges: Set<Int>, members: [Int: Set<Int>], group: Int?
  ) {
    let old = paths[i]
    let fragments = old.cut(edges: edges, members: members, deleteGroup: group)
    paths.replaceSubrange(i...i, with: fragments)
    if active == i {
      let cursor = old.nodes.last?.atoms
      let usable = fragments.indices.filter { !fragments[$0].edges.isEmpty }
      let last = usable.first { fragments[$0].nodes.last?.atoms == cursor } ?? usable.last
      if edges.isEmpty && fragments.count == 1 { active = i } else { active = last.map { i + $0 } }
    } else if let oldActive = active, i < oldActive {
      active = oldActive + fragments.count - 1
    }
  }
  mutating func backtrack(deleteGroup: Int?) {
    guard !paths.isEmpty else { return }
    for i in orderedIndices.reversed() {
      let path = paths[i]
      if let group = deleteGroup {
        if let e = path.edges.lastIndex(where: { $0.color == group }) {
          if e != path.edges.count - 1 || (!path.closed && path.nodes.last?.color != group) {
            applyCut(path: i, edges: [e], members: [:], group: group)
            synchronize()
            return
          }
        } else if path.nodes.count != 1 || path.nodes[0].color != group {
          continue
        }
      }
      if active != i {
        let selected = paths.remove(at: i)
        paths.append(selected)
      }
      let last = active == i ? i : paths.count - 1
      active = last
      if !paths[last].closed { paths[last].nodes.removeLast() }
      paths[last].closed = false
      if let edge = paths[last].edges.popLast() { nextStrong = edge.strong }
      if paths[last].nodes.isEmpty {
        paths.remove(at: last)
        finish()
      }
      return
    }
  }

  mutating func precise(_ a: Int, _ b: Int, erase: Bool, group: Int?) {
    guard a != b else { return }
    var hits: [(Int, Int)] = []
    for (p, path) in paths.enumerated() {
      for e in path.edges.indices where !erase || group == nil || path.edges[e].color == group {
        let (x, y) = path.endpoints(e)
        if x.atoms.contains(a) && y.atoms.contains(b) || x.atoms.contains(b) && y.atoms.contains(a)
        {
          hits.append((p, e))
        }
      }
    }
    guard hits.count == 1, let (p, e) = hits.first else { return }
    if erase {
      applyCut(path: p, edges: [e], members: [:], group: group)
      synchronize()
    } else {
      let tail = latestEdge
      paths[p].edges[e].strong.toggle()
      if tail?.0 == p && tail?.1 == e { synchronize() }
    }
  }
  mutating func edit(
    rect: CGRect, erase: Bool, deleteGroup: Int?, geometry: BoardGeometry,
    board: NativeBoardSnapshot? = nil
  ) {
    let routed = routes(geometry, board: board)
    let hit = CGRect(
      x: rect.minX, y: rect.minY, width: max(1, rect.width), height: max(1, rect.height))
    var tailHit = false
    let latest = latestEdge
    for i in paths.indices.reversed() {
      let path = paths[i]
      let edges = Set(
        path.edges.indices.filter { index in
          guard !erase || deleteGroup == nil || path.edges[index].color == deleteGroup else {
            return false
          }
          return routed[i][index]?.hits(hit, width: max(1.8, geometry.unit / 30)) ?? false
        })
      if erase {
        var members: [Int: Set<Int>] = [:]
        for (j, node) in path.nodes.enumerated()
        where (node.atoms.count > 1 || path.nodes.count == 1)
          && (deleteGroup == nil || node.color == deleteGroup)
        {
          if let group = deleteGroup,
            path.edges.indices.contains(where: {
              ($0 == j || ($0 + 1) % path.nodes.count == j) && path.edges[$0].color != group
            })
          {
            continue
          }
          let selected = Set(node.atoms.filter { hit.contains(ChainToolNode.point($0, geometry)) })
          if !selected.isEmpty { members[j] = selected }
        }
        if !edges.isEmpty || !members.isEmpty {
          applyCut(path: i, edges: edges, members: members, group: deleteGroup)
          tailHit = true
        }
      } else {
        for e in edges { paths[i].edges[e].strong.toggle() }
        if latest?.0 == i, let e = latest?.1, edges.contains(e) { tailHit = true }
      }
    }
    if tailHit { synchronize() }
  }

  mutating func clear(group: Int?) {
    guard let group = group else {
      self = Self()
      return
    }
    for i in paths.indices.reversed() {
      let path = paths[i]
      let edges = Set(path.edges.indices.filter { path.edges[$0].color == group })
      var members: [Int: Set<Int>] = [:]
      for (j, node) in path.nodes.enumerated() where node.color == group {
        let protected = path.edges.indices.contains {
          ($0 == j || ($0 + 1) % path.nodes.count == j) && path.edges[$0].color != group
        }
        if !protected { members[j] = Set(node.atoms) }
      }
      if !edges.isEmpty || !members.isEmpty {
        applyCut(path: i, edges: edges, members: members, group: group)
      }
    }
    synchronize()
  }

  func drawGroupBands(
    in c: CGContext, geometry g: BoardGeometry, board: NativeBoardSnapshot?,
    visual: NativeBoardAppearance, visible: (AnnotationObject) -> Bool
  ) {
    c.saveGState()
    defer { c.restoreGState() }
    var seen = Set<ChainToolNode>()
    for node in paths.lazy.flatMap(\.nodes)
    where node.atoms.count > 1 && visible(.chainNode(node.atoms)) && node.backed(by: board) && seen.insert(node).inserted {
      c.setFillColor(visual.annotationColor(node.color, alpha: 0.22))
      c.addPath(node.groupBands(in: g))
      c.fillPath()
    }
  }

  func draw(
    in c: CGContext, geometry g: BoardGeometry, board: NativeBoardSnapshot? = nil,
    visual: NativeBoardAppearance = .init(), includesGroupBands: Bool = true,
    visible: (AnnotationObject) -> Bool = { _ in true }
  ) {
    c.saveGState()
    defer { c.restoreGState() }
    let routed = routes(g, board: board)
    c.setLineCap(.round)
    c.setLineJoin(.round)
    var seen = Set<ChainToolNode>()
    let nodes = paths.flatMap(\.nodes).filter {
      $0.backed(by: board) && visible(.chainNode($0.atoms)) && seen.insert($0).inserted
    }
    if includesGroupBands { drawGroupBands(in: c, geometry: g, board: board, visual: visual, visible: visible) }
    for (j, path) in paths.enumerated() {
      for (i, edge) in path.edges.enumerated() {
        let (a, b) = path.endpoints(i)
        guard visible(.chainEdge(a.atoms, b.atoms)), let route = routed[j][i] else { continue }
        let color = visual.annotationColor(edge.color)
        let width = edge.strong ? max(1.2, g.unit * 0.026) : max(0.95, g.unit * 0.021)
        let length = route.length
        let dash: [CGFloat] = edge.strong ? [] : [
          min(max(2, g.unit * 0.060), length * 0.16), min(max(2.6, g.unit * 0.072), length * 0.22)
        ]
        let arrow = route.arrow(size: min(max(3, g.unit * 0.092), length * 0.32), closed: edge.strong)
        c.setLineDash(phase: 0, lengths: dash)
        c.setStrokeColor(visual.color("defaultCellColor", alpha: 0.94))
        c.setLineWidth(width + max(1, g.unit * 0.016))
        c.addPath(route.path)
        c.strokePath()
        c.setStrokeColor(color)
        c.setLineWidth(width)
        c.addPath(route.path)
        c.strokePath()
        c.setLineDash(phase: 0, lengths: [])
        c.addPath(arrow)
        if edge.strong {
          c.setFillColor(color)
          c.fillPath()
        } else {
          c.strokePath()
        }
      }
    }
    c.setLineDash(phase: 0, lengths: [])
    for node in nodes {
      c.setStrokeColor(visual.annotationColor(node.color))
      c.setLineWidth(max(0.65, g.unit * 0.014))
      for atom in node.atoms { c.strokeEllipse(in: g.candidateChainRing(atom)) }
    }
  }
}

extension ChainToolState {
  /// Java retains isolated candidates when editing the board removes their last incident relation.
  mutating func prune(board: NativeBoardSnapshot) {
    var changed = false
    for i in paths.indices.reversed() {
      let original = paths[i]
      func present(_ a: Int) -> Bool {
        board.values[a / 10] == 0
          && (board.candidates[a / 10] | board.userCandidates[a / 10])
            & NativeBoardSnapshot.bit(UInt8(a % 10)) != 0
      }
      var hit: [Int: Set<Int>] = [:]
      for (j, node) in original.nodes.enumerated() {
        let missing = Set(node.atoms.filter { !present($0) })
        if !missing.isEmpty { hit[j] = missing }
      }
      guard !hit.isEmpty else { continue }
      let parts = original.cut(edges: [], members: hit, deleteGroup: nil)
      var represented = Set(parts.flatMap(\.nodes).flatMap(\.atoms))
      var orphans: [ChainToolPath] = []
      for node in original.nodes {
        for a in node.atoms where present(a) && represented.insert(a).inserted {
          orphans.append(
            ChainToolPath(
              nodes: [ChainToolNode(atoms: [a], color: node.color)], edges: [], closed: false))
        }
      }
      applyCut(path: i, edges: [], members: hit, group: nil)
      let after = i + parts.count
      paths.insert(contentsOf: orphans, at: after)
      if let a = active, a >= after { active = a + orphans.count }
      changed = true
    }
    if changed { synchronize() }
  }
}
