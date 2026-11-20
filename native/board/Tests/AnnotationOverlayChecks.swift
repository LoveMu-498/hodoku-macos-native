import AppKit
import CoreText
import Foundation

/// Offscreen Core Graphics pixels in the normal board space. No window or input device.
#if !COMBINED_BOARD_CHECKS
  @main
#endif
enum AnnotationOverlayChecks {
  struct Pixel: Equatable {
    let r, g, b, a: Int
    var green: Bool { a > 200 && g > r + 50 && g > b + 30 }
  }

  static func check(_ test: Bool, _ message: String) { if !test { fatalError(message) } }

  static func main() {
    let size = 830
    let g = BoardGeometry(bounds: CGRect(x: 0, y: 0, width: size, height: size))
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let c = CGContext(
      data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
      space: space,
      bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    let bytes = c.data!.assumingMemoryBound(to: UInt8.self)
    func pixel(_ x: Int, _ y: Int) -> Pixel {
      let i = (y * size + x) * 4
      return Pixel(
        r: Int(bytes[i]), g: Int(bytes[i + 1]), b: Int(bytes[i + 2]), a: Int(bytes[i + 3]))
    }
    func colors() -> [Pixel] {
      c.flush()
      return (395..<436).flatMap { (y: Int) -> [Pixel] in (395..<436).map { x in pixel(x, y) } }
    }
    func clear() { c.clear(CGRect(x: 0, y: 0, width: size, height: size)) }
    let empty = NativeBoardSnapshot(
      values: Array(repeating: 0, count: 81), fixed: Array(repeating: false, count: 81),
      candidates: Array(repeating: 511, count: 81), userCandidates: Array(repeating: 0, count: 81))
    boxAddition(empty)
    digitMotion(empty)
    var ink = InkToolState()
    var removed = InkToolState()
    let one = InkStroke(kind: .circle, group: 0, width: 0.005, cell: 40, digit: 5)
    var two = one
    two.group = 1
    ink.strokes = [two, one]
    // Thin diagonal arms can be antialiased across several partially covered pixels.
    func isOrange(_ p: Pixel) -> Bool {
      p.a > 110 && (p.r - p.g) * 255 > 35 * p.a && (p.g - p.b) * 255 > 30 * p.a
    }
    func isPurple(_ p: Pixel) -> Bool {
      p.a > 110 && (p.b - p.r) * 255 > 40 * p.a && (p.r - p.g) * 255 > 20 * p.a
    }
    for kind: InkStroke.Kind in [.circle, .cross] {
      ink.strokes = ink.strokes.map {
        var s = $0
        s.kind = kind
        return s
      }
      clear()
      ink.draw(in: c, geometry: g, board: empty)
      let full = colors()
      let minimum = kind == .cross ? 10 : 25
      let orangeCount = full.filter(isOrange).count
      let purpleCount = full.filter(isPurple).count
      check(orangeCount > minimum && purpleCount > minimum,
            "missing source in \(kind): orange \(orangeCount), purple \(purpleCount)")
      clear()
      ink.draw(in: c, geometry: g, board: empty, visible: { $0 == ink.strokes[0] })
      let layer = colors()
      check(
        layer.filter(isOrange).isEmpty
          && layer.filter(isPurple).count == full.filter(isPurple).count,
        "layer changed source geometry")
      var kept = ink
      removed.strokes = [kept.strokes.removeLast()]
      clear()
      kept.draw(in: c, geometry: g, ghosts: removed, board: empty)
      let predicted = colors()
      check(
        predicted.filter(isPurple).count == full.filter(isPurple).count,
        "ghost changed retained source")
      check(
        predicted.contains(where: {
          (50...64).contains($0.a) && $0.r > $0.g + 10 && $0.g > $0.b + 10
        }), "erasing source lost or opaque")
    }
    var state = ChainToolState()
    state.paths = [
      ChainToolPath(
        nodes: [.init(atoms: [405, 415], color: 0), .init(atoms: [425], color: 1)],
        edges: [.init(strong: true, color: 1)], closed: false)
    ]
    clear()
    state.draw(in: c, geometry: g, board: empty)
    c.flush()
    let member = ChainToolNode.point(405, g), sibling = ChainToolNode.point(415, g)
    func sample(_ p: CGPoint) -> Pixel { pixel(Int(p.x), Int(p.y)) }
    let band = sample(CGPoint(x: (member.x + sibling.x) / 2, y: member.y))
    check((52...60).contains(band.a), "group connection should be translucent between members")
    let wideGroup = ChainToolNode(atoms: [365, 405, 445], color: 0)
    let track = wideGroup.groupBands(in: g)
    let start = ChainToolNode.point(365, g)
    let end = ChainToolNode.point(445, g)
    for x in [start.x, start.x + 0.1 * g.unit, (start.x + end.x) / 2, end.x] {
      check(track.contains(CGPoint(x: x, y: start.y + 0.11 * g.unit)) &&
            !track.contains(CGPoint(x: x, y: start.y + 0.15 * g.unit)),
            "the track should have straight, constant-width sides across the group")
    }
    check(track.contains(CGPoint(x: start.x - 0.115 * g.unit, y: start.y)) &&
          !track.contains(CGPoint(x: start.x - 0.115 * g.unit, y: start.y + 0.11 * g.unit)),
          "the track should end in a semicircle")
    for point in [member, sibling] {
      let top = Int(point.y - 0.94 * g.unit / 6)
      check((top-1...top+1).contains { pixel(Int(point.x), $0).a > 100 },
            "each group member should have a ring centered on its candidate")
    }
    check(sample(CGPoint(x: member.x + g.unit * 0.134, y: member.y + g.unit * 0.134)).a == 0,
          "an old square corner should remain clear")
    clear()
    AnnotationOverlay.chainCues(
      in: c, geometry: g, state: state, board: empty, relations: [:], endpoint: 405,
      onlySingles: false, showEnds: false)
    check(colors().filter(\.green).count > 20, "first precise endpoint ring missing")
    check(
      ((Int(sibling.x) - 18)...(Int(sibling.x) + 18)).contains(where: { x in
        ((395..<436)).contains(where: { y in pixel(x, y).green })
      }), "group member not highlighted")
    var board = empty
    state.active = 0
    board.candidates[41] &= ~NativeBoardSnapshot.bit(5)
    state.prune(board: board)
    check(
      state.paths.count == 1 && state.paths[0].nodes[0].atoms == [405], "candidate-pruned group")
    state.paths = [
      ChainToolPath(
        nodes: [
          .init(atoms: [405], color: 0), .init(atoms: [415], color: 0),
          .init(atoms: [425], color: 1),
        ], edges: [.init(strong: true, color: 0), .init(strong: false, color: 1)], closed: false)
    ]
    state.prune(board: board)
    check(
      Set(state.paths.flatMap(\.nodes).map(\.atoms)) == Set([[405], [425]])
        && state.paths.allSatisfy(\.edges.isEmpty), "surviving orphans connected or lost")
    opticalCentering()
    sharedCandidate(empty)
    crossedCandidate(empty)
    print(
      "P circle/cross compositing, ghost opacity, time layers, L group cues, optical numerals and same-color T/P/L/S layering passed"
    )
  }

  static func boxAddition(_ board: NativeBoardSnapshot) {
    let size = 290
    let bounds = CGRect(x: 0, y: 0, width: size, height: size)
    let geometry = BoardGeometry(bounds: bounds)
    let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                            bytesPerRow: size * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.translateBy(x: 0, y: CGFloat(size))
    context.scaleBy(x: 1, y: -1)
    let bytes = context.data!.assumingMemoryBound(to: UInt8.self)
    let feedback = BoxAdditionFeedback(cells: [41], group: 0, start: 0)
    var page = BoardPage(board: board)
    page.boxes.groups[0] = [40, 41]
    for mode in [BoardColorMode.light, .dark] {
      var frame = BoardFrame(page: page, colorMode: mode)
      frame.showCandidates = false
      func draw(at time: TimeInterval? = nil) -> [[UInt8]] {
        BoardPainter.draw(frame, drag: nil, in: context, bounds: bounds,
                          boxAddition: time.map { (feedback, feedback.opacity(at: $0)) })
        context.flush()
        return [40, 41, 42].map { cell in
          let rect = geometry.rect(cell)
          let offset = (Int(rect.midY) * size + Int(rect.midX)) * 4
          return Array(UnsafeBufferPointer(start: bytes + offset, count: 3))
        }
      }
      let settled = draw()
      let added = draw(at: 0)
      check(added[0] == settled[0] && added[1] != settled[1] && added[2] == settled[2],
            "only the newly added box cell receives feedback")
      check(draw(at: 0.14) == settled, "the box settles to the static appearance in 140 ms")
    }
    print("PASS new box cell tint and settled pixels in light and dark")
  }

  static func digitMotion(_ empty: NativeBoardSnapshot) {
    let size = 290
    let bounds = CGRect(x: 0, y: 0, width: size, height: size)
    let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                            bytesPerRow: size * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.translateBy(x: 0, y: CGFloat(size))
    context.scaleBy(x: 1, y: -1)
    let bytes = context.data!.assumingMemoryBound(to: UInt8.self)
    let five = NativeBoardSnapshot.bit(5)
    var blank = empty
    blank.candidates = Array(repeating: 0, count: 81)
    var withCandidate = blank, withNote = blank, withValue = blank
    withCandidate.candidates[40] = five
    withNote.userCandidates[40] = five
    withValue.setValue(5, at: 40)
    func draw(_ board: NativeBoardSnapshot, notes: Bool, colorKu: Bool,
              motion: (BoardDigitMotion, TimeInterval)? = nil) -> [UInt8] {
      var frame = BoardFrame(page: BoardPage(board: board), colorMode: .light)
      frame.showCandidates = !notes
      frame.general.showColorKu = colorKu
      BoardPainter.draw(frame, drag: nil, in: context, bounds: bounds, digitMotion: motion)
      return Array(UnsafeBufferPointer(start: bytes, count: size * size * 4))
    }
    func distance(_ a: [UInt8], _ b: [UInt8]) -> Int {
      zip(a, b).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) }
    }
    for (marked, notes, colorKu) in [(withCandidate, false, false), (withNote, true, false), (withValue, false, true)] {
      let off = draw(blank, notes: notes, colorKu: colorKu)
      let on = draw(marked, notes: notes, colorKu: colorKu)
      let fadingIn = BoardDigitMotion(before: blank, after: marked, explicitRemovals: [], start: 0)
      let fadingOut = BoardDigitMotion(before: marked, after: blank, explicitRemovals: [], start: 0)
      let entering = draw(marked, notes: notes, colorKu: colorKu, motion: (fadingIn, 0.06))
      let leaving = draw(blank, notes: notes, colorKu: colorKu, motion: (fadingOut, 0.045))
      let full = distance(on, off)
      check(distance(entering, off) > 0 && distance(entering, off) < full / 2, "ease-in glyph at half time")
      check(distance(leaving, off) > 0 && distance(leaving, off) < full / 2, "ease-out glyph at half time")
      check(draw(marked, notes: notes, colorKu: colorKu, motion: (fadingIn, 0.12)) == on &&
            draw(blank, notes: notes, colorKu: colorKu, motion: (fadingOut, 0.09)) == off,
            "finished fade matches the static board")
    }
    var filled = empty
    filled.setValue(5, at: 40)
    var removals = Array(repeating: UInt16(0), count: 81)
    removals[41] = five
    let fillOnly = BoardDigitMotion(before: empty, after: filled, explicitRemovals: [], start: 0)
    let withRemoval = BoardDigitMotion(before: empty, after: filled, explicitRemovals: removals, start: 0)
    check(fillOnly.candidateChanges(at: 41, previous: empty.candidates[41], current: filled.candidates[41]).removed == 0 &&
          withRemoval.candidateChanges(at: 41, previous: empty.candidates[41], current: filled.candidates[41]).removed == five,
          "peer updates only animate when explicitly deleted in a compound result")
    print("PASS ease-in/out for ordinary candidates, notes and ColorKu values")
  }

  static func crossedCandidate(_ board: NativeBoardSnapshot) {
    let cell = 40, digit = 8
    let thin = InkStroke(kind: .cross, group: 0, width: 0.0035, cell: cell, digit: digit)
    var thick = thin
    thick.width = 0.0095
    for size in [360, 830] {
      let bounds = CGRect(x: 0, y: 0, width: size, height: size)
      let g = BoardGeometry(bounds: bounds)
      let slot = g.rect(cell, digit: digit)
      let standard = thick.lineWidth(in: g, candidateFontFactor: 0.25)
      check(thin.lineWidth(in: g, candidateFontFactor: 0.25) < standard &&
            thick.lineWidth(in: g, candidateFontFactor: 0.12) < standard &&
            thick.lineWidth(in: g, candidateFontFactor: 0.5) > standard,
            "pen levels and candidate font size change the visible stroke at \(size)")
      check(thick.lineWidth(in: g, candidateFontFactor: 10) < slot.width * 0.11,
            "oversized candidate settings cannot overwhelm the slot")

      let c = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue)!
      c.translateBy(x: 0, y: CGFloat(size))
      c.scaleBy(x: 1, y: -1)
      let bytes = c.data!.assumingMemoryBound(to: UInt8.self)
      var frame = BoardFrame(page: BoardPage(board: board), colorMode: .light)
      func draw() -> [UInt8] {
        BoardPainter.draw(frame, drag: nil, in: c, bounds: bounds)
        c.flush()
        return Array(UnsafeBufferPointer(start: bytes, count: size * size * 4))
      }
      let plain = draw()
      frame.page.ink.strokes = [thick]
      let crossed = draw()
      var softened = 0
      for y in Int(slot.minY.rounded(.up))..<Int(slot.maxY) {
        for x in Int(slot.minX.rounded(.up))..<Int(slot.maxX) {
          let i = (y * size + x) * 4
          if plain[i] < 160 && (8...47).contains(Int(crossed[i]) - Int(plain[i])) &&
             abs(Int(crossed[i]) - Int(plain[i]) - (Int(crossed[i + 1]) - Int(plain[i + 1]))) <= 4 {
            softened += 1
          }
        }
      }
      check(softened > 0, "the digit is still legible and softer away from the diagonals")

      frame.preview = [.cell(cell, digits: NativeBoardSnapshot.bit(UInt8(digit)))]
      let highlighted = draw()
      for s in [0.0, 0.12, 0.22] {
        let x = Int(slot.midX + s * slot.width)
        let y = Int(slot.midY + s * slot.width)
        check((y-1...y+1).contains { row in
          (x-1...x+1).contains { col in
            let i = (row * size + col) * 4
            return Int(highlighted[i]) - Int(highlighted[i + 1]) > 32 &&
              Int(highlighted[i + 1]) - Int(highlighted[i + 2]) > 30
          }
        }, "continuous X remains visible above the hint digit at \(size), sample \(s)")
      }
    }
  }

  static func opticalCentering() {
    let size = 128
    let slot = CGRect(x: 14, y: 14, width: 100, height: 100)
    let c = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size,
                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
    let bytes = c.data!.assumingMemoryBound(to: UInt8.self)
    func centroid() -> CGPoint {
      c.flush()
      var sum = 0, xMoment = 0, yMoment = 0
      for i in 0..<(size * size) {
        let ink = Int(bytes[i])
        sum += ink
        xMoment += ink * (i % size)
        yMoment += ink * (i / size)
      }
      check(sum > 0, "digit rendered empty")
      return CGPoint(x: CGFloat(xMoment) / CGFloat(sum) + 0.5, y: CGFloat(yMoment) / CGFloat(sum) + 0.5)
    }
    for style in [0, 3] {
      let font = NativePaintFont(name: "Tahoma", style: style, size: 82).resolve()
      let shapes = BoardDigitGlyphs.forFont(font)
      for digit in 1...9 {
        c.setFillColor(gray: 0, alpha: 1)
        c.fill(CGRect(x: 0, y: 0, width: size, height: size))
        var code = UniChar(48 + digit)
        var glyph = CGGlyph()
        check(CTFontGetGlyphsForCharacters(font, &code, &glyph, 1), "fixture font has no digit")
        let path = CTFontCreatePathForGlyph(font, glyph, nil)!
        let box = path.boundingBoxOfPath
        c.saveGState()
        c.translateBy(x: slot.midX - box.midX, y: slot.midY - box.midY)
        c.setFillColor(gray: 1, alpha: 1)
        c.addPath(path)
        c.fillPath()
        c.restoreGState()
        let original = centroid()
        let geometricError = abs(original.x - slot.midX)
        c.setFillColor(gray: 0, alpha: 1)
        c.fill(CGRect(x: 0, y: 0, width: size, height: size))
        let ink = shapes.draw(digit, in: slot, candidate: true, color: CGColor(gray: 1, alpha: 1), context: c)!
        let adjusted = centroid()
        let opticalError = abs(adjusted.x - slot.midX)
        check(opticalError <= geometricError * 0.32 + 0.1, "optical correction for \(digit), style \(style)")
        check(abs(adjusted.y - slot.midY) <= abs(original.y - slot.midY) * 0.78 + 0.12,
              "vertical optical correction for \(digit), style \(style)")
        check(slot.insetBy(dx: 16, dy: 16).contains(ink), "large digit leaves clearance for annotations")
        if digit == 4 && style == 0 {
          check(geometricError > 1 && ink.midX < slot.midX, "four needs a measured leftward correction")
          print(String(format: "Tahoma 4 at 100 px per slot, horizontal ink-center error %.2f → %.2f px", geometricError, opticalError))
        }
      }
    }
  }

  static func sharedCandidate(_ empty: NativeBoardSnapshot) {
    for size in [360, 830] {
      let bounds = CGRect(x: 0, y: 0, width: size, height: size)
      let g = BoardGeometry(bounds: bounds)
      let c = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue)!
      c.translateBy(x: 0, y: CGFloat(size))
      c.scaleBy(x: 1, y: -1)
      let bytes = c.data!.assumingMemoryBound(to: UInt8.self)
      let cell = 40, digit = 4
      let r = g.rect(cell, digit: digit), width = r.width
      var page = BoardPage(board: empty)
      page.marks = [.init(cell: cell, digit: digit, color: 0)]
      page.ink.strokes = [InkStroke(kind: .circle, group: 0, width: 0.0095, cell: cell, digit: digit)]
      page.boxes.groups[0] = [cell]
      page.chains.paths = [
        ChainToolPath(nodes: [.init(atoms: [404], color: 0), .init(atoms: [436], color: 0)],
                      edges: [.init(strong: false, color: 0)], closed: false)
      ]
      func draw(_ page: BoardPage, _ mode: BoardColorMode) -> [UInt8] {
        BoardPainter.draw(BoardFrame(page: page, selected: nil, reference: nil, colorMode: mode),
                          drag: nil, in: c, bounds: bounds)
        c.flush()
        return Array(UnsafeBufferPointer(start: bytes, count: size * size * 4))
      }
      func difference(_ a: [UInt8], _ b: [UInt8], around p: CGPoint) -> Bool {
        let x = Int(p.x), y = Int(p.y)
        return (y-1...y+1).contains { row in
          (x-1...x+1).contains { column in
            let i = (row * size + column) * 4
            return (0..<3).contains { abs(Int(a[i + $0]) - Int(b[i + $0])) >= 9 }
          }
        }
      }
      for mode in [BoardColorMode.light, .dark] {
        let annotated = draw(page, mode)
        var without = page
        without.marks = []
        check(difference(annotated, draw(without, mode), around: CGPoint(x: r.midX - width * 0.17, y: r.midY + width * 0.17)),
              "color fill shows under coexisting shapes")
        without = page
        without.ink = InkToolState()
        check(difference(annotated, draw(without, mode), around: CGPoint(x: r.midX, y: r.midY - width * 0.39)),
              "ink circle has its own visible track")
        without = page
        without.chains = ChainToolState()
        check(difference(annotated, draw(without, mode), around: CGPoint(x: r.midX + width * 0.332, y: r.midY + width * 0.332)),
              "outer chain ring reads apart from ink")
        without = page
        without.boxes = BoxToolState()
        let cellRect = g.rect(cell)
        check(difference(annotated, draw(without, mode), around: CGPoint(x: cellRect.minX + g.unit * 0.011, y: cellRect.maxY - g.unit * 0.12)),
              "group box maintains a visible boundary")
        without = BoardPage(board: empty)
        let plain = draw(without, mode)
        without.chains = page.chains
        let linked = draw(without, mode)
        let color = NativeBoardAppearance().rendered(mode).colors["candidateColor"]![0]
        let expected = [UInt8(color >> 16 & 255), UInt8(color >> 8 & 255), UInt8(color & 255)]
        var checked = 0
        let tolerance = size <= 360 ? 65 : 0
        for cell in 40...43 {
          for digit in 1...9 {
            let slot = g.rect(cell, digit: digit)
            let core = slot.insetBy(dx: slot.width * 0.18, dy: slot.height * 0.18)
            for row in Int(ceil(core.minY))..<Int(core.maxY) {
              for column in Int(ceil(core.minX))..<Int(core.maxX) {
                let i = (row * size + column) * 4
                if (0..<3).allSatisfy({ abs(Int(plain[i + $0]) - Int(expected[$0])) <= tolerance }) {
                  check(linked[i..<i+3].elementsEqual(plain[i..<i+3]), "chain stroke or halo covers a digit")
                  checked += 1
                }
              }
            }
          }
        }
        check(checked > 50, "insufficient candidate pixels at \(size): \(checked)")
      }
    }
  }
}
