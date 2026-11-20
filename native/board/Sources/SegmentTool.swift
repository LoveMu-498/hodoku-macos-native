// SPDX-License-Identifier: GPL-3.0-or-later
import CoreGraphics
import CoreText
import Foundation

struct BoxAdditionFeedback {
  let cells: Set<Int>
  let group: Int
  let start: TimeInterval

  func opacity(at time: TimeInterval) -> CGFloat {
    let remaining = max(0, 1 - max(0, time - start) / 0.14)
    return 0.12 * CGFloat(remaining * remaining)
  }
}

struct BoxToolState: Codable, Equatable {
  var groups = Array(repeating: Set<Int>(), count: 6)
  var footprint: Set<Int> { groups.reduce(into: []) { $0.formUnion($1) } }

  func validate() throws {
    guard groups.count == 6, groups.allSatisfy({ $0.allSatisfy((0..<81).contains) }) else {
      throw BoardFileError.invalid
    }
  }

  func statistics(group: Int, board: NativeBoardSnapshot) -> (cells: Int, digits: Int) {
    guard groups.indices.contains(group) else { return (0, 0) }
    let empty = groups[group].filter { board.values[$0] == 0 }
    let mask = empty.reduce(UInt16(0)) { $0 | board.candidates[$1] }
    return (empty.count, mask.nonzeroBitCount)
  }

  static func selected(start: CGPoint, end: CGPoint, dragged: Bool, geometry g: BoardGeometry)
    -> Set<Int>
  {
    guard g.unit > 0 else { return [] }
    // Java assigns an exact interior grid line to the preceding cell.
    // The two internal palace lines and the leading border have no point target.
    func index(_ value: CGFloat, origin: CGFloat) -> Int? {
      if g.gap > 0 {
        return (0..<9).first { i in
          let left = origin + CGFloat(i) * g.unit + CGFloat(i / 3) * g.gap
          return value > left && value <= left + g.unit
        }
      }
      let q = (value - origin) / g.unit
      guard q > 0, q <= 9, q != 3, q != 6 else { return nil }
      return Int(ceil(q)) - 1
    }
    if !dragged && hypot(start.x - end.x, start.y - end.y) < 4 {
      guard let col = index(end.x, origin: g.grid.minX), let row = index(end.y, origin: g.grid.minY)
      else { return [] }
      return [row * 9 + col]
    }
    func covered(_ a: CGFloat, _ b: CGFloat, _ origin: CGFloat) -> [Int] {
      if a == b { return index(b, origin: origin).map { [$0] } ?? [] }
      let low = min(a, b)
      let high = max(a, b)
      let hits = (0..<9).filter { i in
        let left = origin + CGFloat(i) * g.unit + CGFloat(i / 3) * g.gap
        return high > left && low < left + g.unit
      }
      if hits.count <= 1 { return hits }
      return hits.filter { (low...high).contains(origin + (CGFloat($0) + 0.5) * g.unit + CGFloat($0 / 3) * g.gap) }
    }
    let rows = covered(start.y, end.y, g.grid.minY)
    let cols = covered(start.x, end.x, g.grid.minX)
    return Set(rows.flatMap { row in cols.map { row * 9 + $0 } })
  }

  mutating func edit(
    start: CGPoint, end: CGPoint, dragged: Bool, erase: Bool, group: Int, deleteGroup: Int?,
    geometry: BoardGeometry
  ) {
    guard groups.indices.contains(group) else { return }
    let affected = Self.selected(start: start, end: end, dragged: dragged, geometry: geometry)
    if erase {
      for i in groups.indices where deleteGroup == nil || i == deleteGroup {
        groups[i].subtract(affected)
      }
    } else {
      groups[group].formUnion(affected)
    }
  }

  private static func componentStarts(_ cells: Set<Int>) -> Set<Int> {
    var remaining = cells
    var starts = Set<Int>()
    while let first = remaining.min() {
      starts.insert(first)
      var component = [first]
      remaining.remove(first)
      var offset = 0
      while offset < component.count {
        let cell = component[offset]
        var neighbors = [cell - 9, cell + 9]
        if cell % 9 > 0 { neighbors.append(cell - 1) }
        if cell % 9 < 8 { neighbors.append(cell + 1) }
        for other in neighbors where remaining.remove(other) != nil { component.append(other) }
        offset += 1
      }
    }
    return starts
  }

  func draw(in c: CGContext, geometry g: BoardGeometry, activeGroup: Int?, visual: NativeBoardAppearance = .init(),
            allGroups: [Set<Int>]? = nil) {
    c.saveGState()
    defer { c.restoreGState() }
    let font = CTFontCreateWithName("HelveticaNeue-Bold" as CFString, max(5, g.unit * 0.125), nil)
    var labels: [(CGPath, CGPoint, CGColor, CGColor)] = []
    let completeGroups = allGroups ?? groups
    for (index, cells) in groups.enumerated() where !cells.isEmpty {
      let overlapping = completeGroups.prefix(index).filter { !$0.isDisjoint(with: completeGroups[index]) }.count
      let offset = g.unit * (0.011 + 0.011 * CGFloat(overlapping))
      let color = visual.annotationColor(index, alpha: activeGroup == nil || index == activeGroup ? 0.95 : 0.52)
      let starts = Self.componentStarts(cells)
      var character = UniChar(65 + index)
      var glyph = CGGlyph()
      let outline = CTFontGetGlyphsForCharacters(font, &character, &glyph, 1) ?
        CTFontCreatePathForGlyph(font, glyph, nil) : nil
      c.setStrokeColor(color)
      c.setLineWidth(max(0.75, g.unit * 0.02))
      c.setLineCap(.square)
      for cell in cells.sorted() {
        let bounds = g.rect(cell)
        let r = bounds.insetBy(dx: offset, dy: offset)
        if activeGroup == index {
          c.setFillColor(visual.annotationColor(index, alpha: 0.10))
          c.fill(r)
        }
        func edge(_ a: CGPoint, _ b: CGPoint) {
          c.move(to: a)
          c.addLine(to: b)
        }
        let tl = CGPoint(x: r.minX, y: r.minY)
        let tr = CGPoint(x: r.maxX, y: r.minY)
        let bl = CGPoint(x: r.minX, y: r.maxY)
        let br = CGPoint(x: r.maxX, y: r.maxY)
        if !cells.contains(cell - 9) {
          if starts.contains(cell), let outline = outline {
            // Put the tab in the gaps between candidate columns.
            let x = bounds.minX + g.unit * (0.28 + CGFloat(index % 3) * 0.05 + CGFloat(index / 3) * 0.33)
            let halfGap = outline.boundingBoxOfPath.width / 2 + max(1.6, g.unit * 0.027)
            edge(tl, CGPoint(x: max(tl.x, x - halfGap), y: tl.y))
            edge(CGPoint(x: min(tr.x, x + halfGap), y: tr.y), tr)
            let background = (cell / 27 + cell % 9 / 3) % 2 == 1 ? "alternateCellColor" : "defaultCellColor"
            labels.append((outline, CGPoint(x: x, y: tl.y), color, visual.color(background)))
          } else {
            edge(tl, tr)
          }
        }
        if !cells.contains(cell + 9) { edge(bl, br) }
        if cell % 9 == 0 || !cells.contains(cell - 1) { edge(tl, bl) }
        if cell % 9 == 8 || !cells.contains(cell + 1) { edge(tr, br) }
      }
      c.strokePath()
    }
    for (outline, center, color, background) in labels {
      let ink = outline.boundingBoxOfPath
      var transform = CGAffineTransform(a: 1, b: 0, c: 0, d: -1,
                                        tx: center.x - ink.midX, ty: center.y + ink.midY)
      guard let glyph = outline.copy(using: &transform) else { continue }
      let backing = glyph.boundingBoxOfPath.insetBy(dx: 1.1, dy: 0.45)
      c.setFillColor(background)
      c.addPath(CGPath(roundedRect: backing, cornerWidth: 1, cornerHeight: 1, transform: nil))
      c.fillPath()
      c.setFillColor(color)
      c.addPath(glyph)
      c.fillPath()
    }
  }

}

extension BoxToolState {
  mutating func clear(group: Int?) {
    for i in groups.indices where group == nil || group == i { groups[i].removeAll() }
  }
}
