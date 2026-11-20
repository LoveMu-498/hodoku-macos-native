// SPDX-License-Identifier: GPL-3.0-or-later
import CoreGraphics
import Foundation

enum AnnotationOverlay {
  struct InkGlyph: Hashable {
    let cell: Int
    let digit: Int
    let cross: Bool
    init?(_ s: InkStroke) {
      guard let cell = s.cell, let digit = s.digit, s.kind == .circle || s.kind == .cross else {
        return nil
      }
      self.cell = cell
      self.digit = digit
      cross = s.kind == .cross
    }
  }
  struct Source {
    let mark: InkStroke
    let ghost: Bool
    var opacity: CGFloat { ghost ? 0.25 : 1 }
  }
  struct Composite {
    var byGroup: [Int: Source] = [:]
    var byRole: [Int: Source] = [:]
    var ordered: [Source] { byGroup.keys.sorted().compactMap { byGroup[$0] } }
    mutating func add(_ source: Source) {
      let group = source.mark.group
      let role = group * 2 + (source.mark.start ? 1 : 0)
      if byGroup[group] == nil || byGroup[group]!.ghost || !source.ghost { byGroup[group] = source }
      if byRole[role] == nil || byRole[role]!.ghost || !source.ghost { byRole[role] = source }
    }
  }
  static func rgba(_ hex: Int, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
      srgbRed: CGFloat(hex >> 16) / 255, green: CGFloat(hex >> 8 & 255) / 255,
      blue: CGFloat(hex & 255) / 255, alpha: alpha)
  }
  static func ink(
    _ live: InkToolState, ghosts: InkToolState?, in c: CGContext, geometry g: BoardGeometry,
    group: Int?, board: NativeBoardSnapshot?, alpha: CGFloat,
    visual: NativeBoardAppearance, candidateFontFactor: CGFloat, include: (InkStroke.Kind) -> Bool,
    visible: (InkStroke) -> Bool
  ) {
    let sources =
      live.strokes.filter { include($0.kind) }.map { Source(mark: $0, ghost: false) }
      + (ghosts?.strokes ?? []).filter { include($0.kind) }.map { Source(mark: $0, ghost: true) }
    var composites: [InkGlyph: Composite] = [:]
    for source in sources {
      guard let glyph = InkGlyph(source.mark) else { continue }
      if let b = board,
        b.values[glyph.cell] != 0
          || b.candidates[glyph.cell] & NativeBoardSnapshot.bit(UInt8(glyph.digit)) == 0
      {
        continue
      }
      composites[glyph, default: Composite()].add(source)
    }
    func path(_ segments: [[CGPoint]]) -> CGPath {
      let p = CGMutablePath()
      for line in segments where !line.isEmpty {
        p.move(to: line[0])
        for q in line.dropFirst() { p.addLine(to: q) }
      }
      return p
    }
    func stroke(_ line: CGPath, _ width: CGFloat, _ color: CGColor) {
      c.setStrokeColor(color)
      c.setLineWidth(width)
      c.addPath(line)
      c.strokePath()
    }
    c.saveGState()
    defer { c.restoreGState() }
    c.setLineCap(.round)
    c.setLineJoin(.round)
    c.setLineDash(phase: 0, lengths: [])
    let projection = CGAffineTransform(a: g.grid.width, b: 0, c: 0, d: g.grid.height, tx: g.grid.minX, ty: g.grid.minY)
    var painted = Set<InkGlyph>()
    for source in sources {
      let s = source.mark
      let width = s.lineWidth(in: g, candidateFontFactor: candidateFontFactor)
      guard let glyph = InkGlyph(s) else {
        if visible(s) {
          let line: CGPath
          if s.kind == .line {
            let trace = CGMutablePath()
            trace.addLines(between: s.points, transform: projection)
            line = trace
          } else {
            line = path(s.paths(g))
          }
          stroke(line, width, visual.annotationColor(s.group, light: s.light == true, alpha: alpha * source.opacity))
        }
        continue
      }
      guard painted.insert(glyph).inserted, let composite = composites[glyph] else { continue }
      let parts = composite.ordered
      guard parts.contains(where: { visible($0.mark) }) else { continue }
      // The grouping geometry includes both retained and erasing sources, keeping each
      // source's arc/diagonal segment stable while the pointer moves.
      let segments = s.paths(g)
      let outline = path(segments)
      var selected: Source?
      var start: Source?
      if let active = group {
        for role in composite.byRole.values {
          guard visible(role.mark) else { continue }
          if role.mark.start && role.mark.group == active && (start == nil || start!.ghost) {
            start = role
          }
          if role.mark.outlined && (role.mark.group == active || !role.mark.outlineSources.isEmpty)
            && (selected == nil || selected!.ghost)
          {
            selected = role
          }
        }
      }
      let bandWidth = g.unit * 0.009
      func band(_ item: Source, color: Int, outside: CGFloat) {
        let opacity = alpha * item.opacity
        stroke(outline, width + 2 * (outside + bandWidth * 0.42), visual.color("defaultCellColor", alpha: opacity))
        stroke(outline, width + 2 * outside, rgba(color, opacity))
        if outside > bandWidth { stroke(outline, width + 2 * (outside - bandWidth), visual.color("defaultCellColor", alpha: opacity)) }
      }
      if let start = start {
        band(start, color: 0x00D72D, outside: bandWidth * (selected == nil ? 1 : 2))
      }
      if let selected = selected { band(selected, color: 0x1769FF, outside: bandWidth) }
      for (i, item) in parts.enumerated() {
        guard visible(item.mark) else { continue }
        let focus: CGFloat = group != nil && item.mark.group != group && parts.count == 1 ? 0.16 : 1
        let opacity = alpha * item.opacity * focus
        let color =
          item.mark.witness
          ? rgba(0xC52024, opacity) : visual.annotationColor(item.mark.group, light: item.mark.light == true, alpha: opacity)
        if parts.count == 1 {
          stroke(outline, width, color)
          continue
        }
        let lo = CGFloat(i) / CGFloat(parts.count)
        let hi = CGFloat(i + 1) / CGFloat(parts.count)
        if glyph.cross {
          c.setLineCap(.butt)
          for diagonal in segments {
            guard let a = diagonal.first, let b = diagonal.last else { continue }
            func pos(_ t: CGFloat) -> CGPoint {
              CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
            }
            stroke(path([[pos(lo), pos(hi)]]), width, color)
            for end in [lo, hi] where end == 0 || end == 1 {
              let q = pos(end)
              c.setFillColor(color)
              c.fillEllipse(
                in: CGRect(x: q.x - width / 2, y: q.y - width / 2, width: width, height: width))
            }
          }
          c.setLineCap(.round)
        } else {
          let r = g.candidateInkBounds(glyph.cell, digit: glyph.digit)
          let arc = CGMutablePath()
          arc.addArc(
            center: CGPoint(x: r.midX, y: r.midY), radius: r.width / 2, startAngle: lo * 2 * .pi,
            endAngle: hi * 2 * .pi, clockwise: false)
          c.setLineCap(.butt)
          stroke(arc, width, color)
          c.setLineCap(.round)
        }
      }
    }
  }

  static func chainCues(
    in c: CGContext, geometry g: BoardGeometry, state: ChainToolState, board: NativeBoardSnapshot,
    relations: [ChainToolNode: Int], endpoint: Int?, onlySingles: Bool, showEnds: Bool = true,
    visual: NativeBoardAppearance = .init()
  ) {
    c.saveGState()
    defer { c.restoreGState() }
    c.setLineCap(.round)
    c.setLineJoin(.round)
    let unit = g.unit
    func emphasized(_ atom: Int, color: Int, width: CGFloat) {
      let ring = g.candidateChainRing(atom, scale: 1.08)
      c.setStrokeColor(visual.color("defaultCellColor"))
      c.setLineWidth(width + max(0.6, unit * 0.012))
      c.strokeEllipse(in: ring)
      c.setStrokeColor(rgba(color))
      c.setLineWidth(width)
      c.strokeEllipse(in: ring)
    }
    let grouped = Set(relations.keys.filter { $0.atoms.count > 1 }.flatMap(\.atoms))
    for (node, relation) in relations.sorted(by: {
      $0.key.atoms.lexicographicallyPrecedes($1.key.atoms)
    }) {
      if onlySingles && node.atoms.count > 1
        || !onlySingles && node.atoms.count == 1 && grouped.contains(node.atoms[0])
      {
        continue
      }
      let enabled = relation == 2 || relation == (state.nextStrong ? 3 : 1)
      let weak = relation == 1 || (relation == 2 && !state.nextStrong)
      let color = enabled ? (weak ? 0xB77923 : 0x008455) : 0xB8676E
      c.setStrokeColor(rgba(color))
      c.setLineWidth(max(0.9, unit * (enabled ? 0.023 : 0.018)))
      let step = max(1.4, unit * 0.026)
      let gap = max(2.6, unit * 0.06)
      c.setLineDash(phase: 0, lengths: enabled ? (weak ? [step, gap] : []) : [step * 1.5, step, step * 0.5, step])
      if node.atoms.count > 1 {
        c.setFillColor(rgba(color, enabled ? 0.16 : 0.08))
        c.addPath(node.groupBands(in: g))
        c.fillPath()
      }
      for a in node.atoms {
        c.addEllipse(in: g.candidateChainRing(a, scale: 1.08))
        c.strokePath()
      }
    }
    c.setLineDash(phase: 0, lengths: [])
    if showEnds, let active = state.active, !state.paths[active].closed,
       let tail = state.paths[active].nodes.last, tail.backed(by: board) {
      for atom in tail.atoms {
        emphasized(atom, color: 0x1C70E1, width: max(1, unit * 0.024))
      }
    }
    guard let a = endpoint else { return }
    let selected = Set(
      state.paths.flatMap(\.nodes).filter { $0.atoms.contains(a) && $0.backed(by: board) }.flatMap(
        \.atoms))
    for member in selected {
      emphasized(member, color: 0x008455, width: max(1.1, unit * 0.03))
    }
  }
}
