import CoreGraphics
import CoreText
import Foundation
import ImageIO

enum BoardPainter {
    private static func rgb(_ hex: Int, _ alpha: CGFloat = 1) -> CGColor {
        CGColor(
            srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255,
            blue: CGFloat(hex & 255) / 255, alpha: alpha)
    }
    static func draw(_ frame: BoardFrame, drag: BoardDrag?, in context: CGContext, bounds: CGRect,
                     showsCoordinates: Bool = false, hoveredCoordinate: BoardHouse? = nil,
                     boxAddition: (feedback: BoxAdditionFeedback, opacity: CGFloat)? = nil,
                     digitMotion: (edit: BoardDigitMotion, elapsed: TimeInterval)? = nil) {
        let geometry = BoardGeometry(bounds: bounds, separatedBoxes: frame.general.drawMode == 0, showsCoordinates: showsCoordinates)
        guard geometry.unit > 0 else { return }
        let unit = geometry.unit
        let visual = frame.visual.rendered(frame.colorMode), board = frame.page.board
        let candidateFontFactor: CGFloat = frame.general.showColorKu ? 0.25 : visual.factors["candidateFontFactor"]!
        let hint = BoardHintColors(visual: visual)
        let houseCells = frame.housePreview.map { house in (0..<81).filter(house.contains) } ?? []
        let houseColor = rgb(frame.colorMode == .dark ? 0x8BC7FF : 0x175CD3)
        let hasChains = !frame.page.chains.paths.isEmpty
        var digitProtection: [Int: CGRect] = [:]
        let coloredCandidates = Set(frame.page.marks.filter { mark in
            mark.digit != 0 && (board.candidates[mark.cell] | board.userCandidates[mark.cell])
                & NativeBoardSnapshot.bit(UInt8(mark.digit)) != 0
        }.map { $0.cell * 10 + $0.digit })
        let selection = frame.hideSelection ? [] : (frame.selectionCells.isEmpty ? frame.selected.map { [$0] } ?? [] : frame.selectionCells)
        context.saveGState()
        defer { context.restoreGState() }
        context.setFillColor(visual.color("defaultCellColor"))
        context.fill(bounds)
        for cell in 0..<81 where (cell / 27 + cell % 9 / 3) % 2 == 1 {
            context.setFillColor(visual.color("alternateCellColor"))
            context.fill(geometry.rect(cell))
        }
        func colorDot(_ cell: Int, _ digit: Int) -> CGRect {
            let slot = geometry.rect(cell, digit: digit)
            return slot.insetBy(dx: slot.width * 0.16, dy: slot.height * 0.16)
        }
        func drawMarks(digits: Bool, later: Bool) {
            for mark in frame.page.marks
            where (mark.digit != 0) == digits && frame.later.contains(.mark(mark.cell, mark.digit)) == later {
                if mark.digit == 0 {
                    context.setFillColor(visual.annotationColor(mark.color, light: mark.light == true, alpha: 0.42))
                    context.fill(geometry.rect(mark.cell))
                } else if coloredCandidates.contains(mark.cell * 10 + mark.digit) {
                    context.setFillColor(visual.annotationColor(mark.color, light: mark.light == true, alpha: 0.48))
                    context.fillEllipse(in: colorDot(mark.cell, mark.digit))
                }
            }
        }
        func drawBoxes(later: Bool) {
            var boxes = frame.page.boxes
            for i in boxes.groups.indices {
                boxes.groups[i] = boxes.groups[i].filter { frame.later.contains(.box(i, $0)) == later }
            }
            boxes.draw(in: context, geometry: geometry, activeGroup: frame.previewTool == .boxes ? frame.palette : nil,
                       visual: visual, allGroups: frame.page.boxes.groups)
        }
        if !frame.general.onlySmallCursors && frame.colorMode != .dark {
            context.setFillColor(visual.color("aktCellColor", alpha: 0.35))
            for cell in selection { context.fill(geometry.rect(cell)) }
        }
        let filter = (0..<81).map { frame.filterHighlights(at: $0) }
        for (cell, highlight) in filter.enumerated() where highlight.inverseCell || highlight.digitCell {
            let fill: CGColor
            if highlight.inverseCell {
                fill = visual.color("invalidCellColor")
            } else {
                fill = visual.color(board.values[cell] == 0 ? "possibleCellColor" : "possibleFixedCellColor")
            }
            context.setFillColor(fill)
            context.fill(geometry.rect(cell))
        }
        drawMarks(digits: false, later: false)
        for reference in frame.preview {
            for cell in reference.cells {
                context.setFillColor(visual.color(reference.removal ? "hintCandidateDeleteBackColor" : "hintCandidateBackColor", alpha: 0.6))
                context.fill(geometry.rect(cell))
            }
        }
        if !houseCells.isEmpty {
            context.setFillColor(houseColor.copy(alpha: 0.15) ?? houseColor)
            for cell in houseCells { context.fill(geometry.rect(cell)) }
        }
        if let (feedback, opacity) = boxAddition {
            context.setFillColor(visual.annotationColor(feedback.group, alpha: opacity))
            for cell in feedback.cells { context.fill(geometry.rect(cell)) }
        }
        if !frame.onlySmallFilters, filter.contains(where: { $0.count != nil }),
           let gradient = countStripeGradient(mode: frame.colorMode) {
            for (cell, highlight) in filter.enumerated() {
                guard let count = highlight.count else { continue }
                drawCountStripes(count, in: geometry.rect(cell), gradient: gradient, context: context)
            }
        }
        let thin = max(0.5, geometry.grid.width * 0.002)
        let thick = max(0.25, min(unit, thin * visual.factors["boxLineFactor"]!))
        context.setStrokeColor(visual.color("innerGridColor"))
        context.setLineWidth(thin)
        for band in 0..<9 {
            let origin = geometry.rect((band / 3) * 27 + (band % 3) * 3).origin
            for i in 1...2 {
                let offset = CGFloat(i) * unit
                context.move(to: CGPoint(x: origin.x + offset, y: origin.y))
                context.addLine(to: CGPoint(x: origin.x + offset, y: origin.y + 3 * unit))
                context.move(to: CGPoint(x: origin.x, y: origin.y + offset))
                context.addLine(to: CGPoint(x: origin.x + 3 * unit, y: origin.y + offset))
            }
        }
        context.strokePath()
        context.setStrokeColor(visual.color("gridColor"))
        context.setLineWidth(thick)
        for band in 0..<9 {
            let origin = geometry.rect((band / 3) * 27 + (band % 3) * 3).origin
            context.stroke(CGRect(origin: origin, size: CGSize(width: unit * 3, height: unit * 3)))
        }
        if !frame.page.chains.paths.isEmpty {
            frame.page.chains.drawGroupBands(in: context, geometry: geometry, board: board, visual: visual,
                                            visible: { !frame.later.contains($0) })
        }
        drawBoxes(later: false)
        drawMarks(digits: true, later: false)
        let values = BoardDigitGlyphs.forFont(visual.fonts["defaultValueFont"]!.resolve(size: unit * min(8, visual.factors["valueFontFactor"]!)))
        let candidates = BoardDigitGlyphs.forFont(visual.fonts["defaultCandidateFont"]!.resolve(size: unit * min(8, visual.factors["candidateFontFactor"]!)))
        var ink = frame.page.ink
        let projection = frame.inkProjection ?? InkPreviewProjection()
        let promoted = projection.fills
        let hidden = projection.removed
        let conflicts = projection.conflicts
        if frame.previewTool == .ink {
            ink.strokes.removeAll { s in
                guard s.group == frame.palette, let c = s.cell, let d = s.digit else { return false }
                return hidden.contains(c * 10 + d) || promoted[c] == d
            }
        }
        let crossed = Set(ink.strokes.compactMap { stroke -> Int? in
            guard stroke.kind == .cross, let cell = stroke.cell, let digit = stroke.digit,
                  board.values[cell] == 0, board.candidates[cell] & NativeBoardSnapshot.bit(UInt8(digit)) != 0
            else { return nil }
            return cell * 10 + digit
        })
        func paint(_ digit: Int, at cell: Int, small: Bool, color: CGColor, errorIndex: Int? = nil,
                   fade: CGFloat = 1, live: Bool = true) {
            let rect = geometry.rect(cell, digit: small ? digit : 0)
            let index = cell * 10 + (small ? digit : 0)
            let opacity: CGFloat = small && crossed.contains(index) ? 0.82 : 1
            let protectsDigit = live && hasChains
            if fade < 1 {
                context.saveGState()
                context.setAlpha(fade)
            }
            defer { if fade < 1 { context.restoreGState() } }
            if frame.general.showColorKu {
                let dot = rect.insetBy(dx: rect.width * 0.13, dy: rect.height * 0.13)
                context.setFillColor(visual.color("colorKuColors", index: digit - 1, alpha: opacity))
                context.fillEllipse(in: dot)
                context.setStrokeColor(rgb(0, 0.35 * opacity))
                context.setLineWidth(max(0.5, dot.width * 0.035))
                context.strokeEllipse(in: dot)
                if protectsDigit { digitProtection[index] = dot }
                if let index = errorIndex {
                    let cross = dot.insetBy(dx: dot.width * 0.17, dy: dot.height * 0.17)
                    context.setStrokeColor(visual.color("colorKuColors", index: index, alpha: opacity))
                    context.setLineWidth(max(1, dot.width * 0.09))
                    context.move(to: cross.origin)
                    context.addLine(to: CGPoint(x: cross.maxX, y: cross.maxY))
                    context.move(to: CGPoint(x: cross.maxX, y: cross.minY))
                    context.addLine(to: CGPoint(x: cross.minX, y: cross.maxY))
                    context.strokePath()
                }
            } else {
                let inkColor = opacity == 1 ? color : (color.copy(alpha: color.alpha * opacity) ?? color)
                let glyph = (small ? candidates : values).draw(digit, in: rect, candidate: small, color: inkColor, context: context)
                if protectsDigit { digitProtection[index] = glyph }
            }
        }
        func paintValue(_ source: NativeBoardSnapshot, at cell: Int, legal: UInt16,
                        fade: CGFloat, live: Bool = true) {
            let digit = source.values[cell]
            let duplicate = !source.fixed[cell] && legal & NativeBoardSnapshot.bit(digit) == 0
            let deviates = !source.fixed[cell] && frame.solution.map { $0[cell] != digit } == true
            let key = duplicate ? "wrongValueColor" : deviates ? "deviationColor" : source.fixed[cell] ? "cellFixedValueColor" : "cellValueColor"
            paint(Int(digit), at: cell, small: false, color: visual.color(key),
                  errorIndex: duplicate ? 9 : deviates ? 10 : nil, fade: fade, live: live)
        }
        func candidateBackground(_ rect: CGRect, at cell: Int, digit: Int, color: CGColor) {
            context.setFillColor(color)
            context.beginPath()
            context.addEllipse(in: rect)
            if coloredCandidates.contains(cell * 10 + digit) {
                context.addEllipse(in: colorDot(cell, digit).intersection(rect))
            }
            context.drawPath(using: .eoFill)
        }
        let motion = frame.reviewBoard == nil && frame.inkProjection == nil ? digitMotion : nil
        let fades = motion.map { BoardDigitMotion.opacity(elapsed: $0.elapsed) } ?? (added: 1, removed: 0)
        for cell in 0..<81 {
            let mask = frame.displayedMask(at: cell, on: board)
            let highlight = filter[cell]
            let highlightDigits = highlight.digitCell ? 0 : highlight.digits
            let expected = frame.solution?[cell]
            let legal = frame.general.showWrongValues ? board.legalMask(at: cell) : 511
            var added: UInt16 = 0
            var valueChanged = false
            if let edit = motion?.edit {
                let before = edit.before
                valueChanged = before.values[cell] != board.values[cell]
                let changes = edit.candidateChanges(at: cell, previous: frame.displayedMask(at: cell, on: before), current: mask)
                added = changes.added
                if fades.removed > 0, changes.removed != 0 || valueChanged && before.values[cell] != 0 {
                    let oldLegal = frame.general.showWrongValues ? before.legalMask(at: cell) : 511
                    if valueChanged && before.values[cell] != 0 {
                        paintValue(before, at: cell, legal: oldLegal, fade: fades.removed, live: false)
                    }
                    for digit in 1...9 where changes.removed & NativeBoardSnapshot.bit(UInt8(digit)) != 0 {
                        // A missing solution digit can still be visible as an error marker.
                        if board.values[cell] == 0 && frame.showCandidates && expected == UInt8(digit) { continue }
                        let wrong = oldLegal & NativeBoardSnapshot.bit(UInt8(digit)) == 0
                        paint(digit, at: cell, small: true, color: visual.color(wrong ? "wrongValueColor" : "candidateColor"),
                              errorIndex: wrong ? 9 : nil, fade: fades.removed, live: false)
                    }
                }
            }
            if board.values[cell] != 0 {
                paintValue(board, at: cell, legal: legal, fade: valueChanged ? fades.added : 1)
            } else if let digit = promoted[cell] {
                paint(digit, at: cell, small: false, color: visual.annotationColor(frame.palette))
            } else {
                for digit in 1...9
                where !hidden.contains(cell * 10 + digit)
                    && (mask & NativeBoardSnapshot.bit(UInt8(digit)) != 0 || (frame.showCandidates && expected == UInt8(digit)))
                {
                    let bit = NativeBoardSnapshot.bit(UInt8(digit))
                    if highlightDigits & bit != 0 {
                        let rect = geometry.rect(cell, digit: digit).insetBy(dx: unit * 0.024, dy: unit * 0.024)
                        let color = highlight.count.flatMap { count in
                            highlight.digitMarks & bit == 0 ? CandidateFilterColors.fill(forCount: count, mode: frame.colorMode) : nil
                        } ?? visual.color("possibleCellColor")
                        candidateBackground(rect, at: cell, digit: digit, color: color)
                    }
                    let wrong = conflicts.contains(cell * 10 + digit) || legal & bit == 0
                    let missing = mask & bit == 0
                    let opacity: CGFloat = projection.peers.contains(cell * 10 + digit) && !projection.protected.contains(cell * 10 + digit) ? 0.45 : 1
                    let color = visual.color(wrong ? "wrongValueColor" : missing ? "deviationColor" : "candidateColor", alpha: opacity)
                    paint(digit, at: cell, small: true, color: color, errorIndex: wrong ? 9 : missing ? 10 : nil,
                          fade: added & bit != 0 ? fades.added : 1)
                }
            }
        }
        if let previous = frame.reviewBoard {
            for cell in 0..<81 {
                if previous.values[cell] != 0 && previous.values[cell] != board.values[cell] {
                    values.draw(Int(previous.values[cell]), in: geometry.rect(cell), candidate: false, color: rgb(0x606870, 0.5), context: context)
                }
                guard previous.values[cell] == 0 else { continue }
                for digit in 1...9 where UInt8(digit) != board.values[cell] {
                    let bit = NativeBoardSnapshot.bit(UInt8(digit))
                    let old = frame.showCandidates ? previous.candidates[cell] : previous.userCandidates[cell]
                    let current = frame.showCandidates ? board.candidates[cell] : board.userCandidates[cell]
                    if old & bit != 0 && current & bit == 0 {
                        candidates.draw(digit, in: geometry.rect(cell, digit: digit), candidate: true, color: rgb(0x606870, 0.55), context: context)
                    } else if old & bit == 0 && current & bit != 0 {
                        context.setStrokeColor(rgb(0x3477B7)); context.setLineWidth(1)
                        context.strokeEllipse(in: geometry.rect(cell, digit: digit).insetBy(dx: 1, dy: 1))
                    }
                }
            }
        }
        func drawClearOfDigits(_ draw: () -> Void) {
            context.saveGState()
            defer { context.restoreGState() }
            let mask = CGMutablePath()
            mask.addRect(bounds)
            for (id, rect) in digitProtection where id % 10 == 0 || digitProtection[id / 10 * 10] == nil {
                let inset = unit * 0.012
                mask.addRect(rect.insetBy(dx: -inset, dy: -inset))
            }
            context.addPath(mask)
            context.clip(using: .evenOdd)
            draw()
        }
        func overlay(later: Bool) {
            let visible: (AnnotationObject) -> Bool = { frame.later.contains($0) == later }
            if !frame.page.chains.paths.isEmpty {
                drawClearOfDigits {
                    frame.page.chains.draw(in: context, geometry: geometry, board: board, visual: visual,
                                           includesGroupBands: later, visible: visible)
                }
            }
            ink.draw(
                in: context, geometry: geometry, ghosts: frame.erasedInk,
                group: frame.activeTool == .ink ? frame.palette : nil, board: board, visual: visual,
                candidateFontFactor: candidateFontFactor, include: { $0 != .cross },
                visible: { frame.later.isEmpty || visible(.ink($0)) })
        }
        InkProofPreview.draw(frame.inkSources, in: context, geometry: geometry, visual: visual,
                            candidateFontFactor: candidateFontFactor)
        overlay(later: false)
        for selected in selection {
            context.setStrokeColor(visual.color("aktCellColor"))
            context.setLineWidth(2)
            context.stroke(geometry.rect(selected).insetBy(dx: 2, dy: 2))
        }
        if let diagram = frame.answerDiagram {
            let markerScale = min(1, candidateFontFactor * 1.85 * visual.factors["hintBackFactor"]!)
            let radius = unit / 6 * (frame.general.showColorKu ? max(0.94, markerScale) : markerScale)
            for (atom, role) in diagram.candidates {
                let cell = atom / 10, digit = atom % 10
                guard board.values[cell] == 0 else { continue }
                let mask = board.candidates[cell] | (diagram.usesPencilNotes ? board.userCandidates[cell] : 0)
                let present = mask & NativeBoardSnapshot.bit(UInt8(digit)) != 0
                let removed = !present && frame.showHistoricalRemovals && (role == .deletion || role == .cannibalistic)
                guard present || removed else { continue }
                let slot = geometry.rect(cell, digit: digit)
                let mark = CGRect(x: slot.midX - radius, y: slot.midY - radius, width: 2 * radius, height: 2 * radius)
                let colors = hint.pair(for: role)
                let fill = (diagram.isAuthored || diagram.isBoxProof) && role == .deletion ? rgb(0xeb0000) : colors.fill
                context.saveGState()
                if removed {
                    context.setStrokeColor(fill)
                    context.setLineWidth(max(1.2, unit * 0.025))
                    context.strokeEllipse(in: mark)
                    context.setAlpha(0.45)
                } else {
                    context.setFillColor(fill)
                    context.fillEllipse(in: mark)
                }
                if diagram.isAuthored {
                    candidates.draw(digit, in: slot, candidate: true, color: rgb(0xffffff), context: context)
                } else {
                    paint(digit, at: cell, small: true, color: colors.ink)
                }
                context.restoreGState()
            }
            if !diagram.links.isEmpty {
                diagram.drawLinks(geometry: geometry, visual: visual, markerRadius: radius, in: context)
            }
        }
        for reference in frame.preview {
            let historical = frame.showHistoricalRemovals && reference.removal
            context.setStrokeColor(visual.color(reference.removal ? "hintCandidateDeleteColor" : "hintCandidateColor"))
            context.setLineWidth(2)
            context.setLineDash(phase: 0, lengths: [4, 2])
            for cell in reference.cells {
                if reference.digits == 0 {
                    context.stroke(geometry.rect(cell).insetBy(dx: 3, dy: 3))
                } else {
                    for digit in 1...9 where reference.digits & NativeBoardSnapshot.bit(UInt8(digit)) != 0 {
                        let slot = geometry.rect(cell, digit: digit)
                        let scale = min(1, visual.factors["candidateFontFactor"]! * 2.1 * visual.factors["hintBackFactor"]!)
                        let inset = slot.width * (1 - scale) / 2
                        let mark = slot.insetBy(dx: inset, dy: inset)
                        let role = frame.answerDiagram?.candidates[cell * 10 + digit] ?? (reference.removal ? .deletion : .premise)
                        let pair = hint.pair(for: role)
                        let present = board.candidates[cell] & NativeBoardSnapshot.bit(UInt8(digit)) != 0
                        let removed = historical && !present
                        // The applied frame keeps the deleted glyph as a ghost. Its hollow marker
                        // distinguishes the result from a live deletion proposal, including in ColorKu.
                        guard board.values[cell] == 0 && (present || removed) else { continue }
                        if frame.answerDiagram?.candidates[cell * 10 + digit] == nil && !removed {
                            candidateBackground(mark, at: cell, digit: digit, color: pair.fill)
                        }
                        if frame.answerDiagram?.candidates[cell * 10 + digit] == nil {
                            context.saveGState()
                            if removed { context.setAlpha(0.45) }
                            paint(digit, at: cell, small: true, color: pair.ink)
                            context.restoreGState()
                        }
                        context.setStrokeColor(pair.ink)
                        context.strokeEllipse(in: mark)
                        if reference.removal {
                            context.move(to: CGPoint(x: mark.minX, y: mark.maxY))
                            context.addLine(to: CGPoint(x: mark.maxX, y: mark.minY))
                            context.strokePath()
                        }
                    }
                }
            }
            context.setLineDash(phase: 0, lengths: [])
        }
        if !frame.later.isEmpty {
            drawMarks(digits: false, later: true)
            drawMarks(digits: true, later: true)
            drawBoxes(later: true)
            overlay(later: true)
        }
        if frame.activeTool == .chain {
            drawClearOfDigits {
                AnnotationOverlay.chainCues(
                    in: context, geometry: geometry, state: frame.page.chains, board: board,
                    relations: frame.chainRelations, endpoint: frame.preciseEndpoint, onlySingles: frame.chainSinglePreview,
                    visual: visual)
            }
        }
        // Candidate previews can repaint a digit. Finish with the X so both diagonals stay continuous.
        if !crossed.isEmpty || frame.erasedInk?.strokes.contains(where: { $0.kind == .cross }) == true {
            ink.draw(
                in: context, geometry: geometry, ghosts: frame.erasedInk,
                group: frame.activeTool == .ink ? frame.palette : nil, board: board, visual: visual,
                candidateFontFactor: candidateFontFactor, include: { $0 == .cross })
        }
        if let drag = drag, let last = drag.points.last, frame.activeTool != .ink || frame.erasing {
            if drag.rectangle {
                let tint = frame.erasing ? 0xB43643 : 0x175CD3
                let outline = CGPath(roundedRect: drag.bounds, cornerWidth: 3, cornerHeight: 3, transform: nil)
                context.setFillColor(rgb(tint, 0.055))
                context.addPath(outline)
                context.fillPath()
                context.setStrokeColor(rgb(tint, 0.90))
                context.setLineCap(.round)
                context.setLineWidth(1.35)
                context.setLineDash(phase: 0, lengths: [5, 3])
                context.addPath(outline)
                context.strokePath()
            } else {
                context.setLineWidth(1.5)
                context.setLineDash(phase: 0, lengths: [4, 3])
                context.setStrokeColor(rgb(0x175CD3))
                context.strokeEllipse(
                    in: CGRect(
                        x: last.x - drag.radius, y: last.y - drag.radius, width: 2 * drag.radius,
                        height: 2 * drag.radius))
            }
        }
        if let first = houseCells.first, let last = houseCells.last {
            let region = geometry.rect(first).union(geometry.rect(last)).insetBy(dx: 1, dy: 1)
            context.setLineDash(phase: 0, lengths: [])
            context.setStrokeColor(houseColor)
            context.setLineWidth(1.5)
            context.stroke(region)
        }
        if showsCoordinates {
            drawCoordinates(in: context, geometry: geometry, visual: visual, accent: houseColor,
                            active: frame.housePreview, hovered: hoveredCoordinate)
        }
    }

    private static func countStripeGradient(mode: BoardColorMode) -> CGGradient? {
        let dark = mode == .dark
        let tint = dark ? 0xa6b7ca : 0x43576b
        let shade = dark ? 0x06090d : 0x35495b
        let colors = [rgb(tint, 0), rgb(tint, dark ? 0.08 : 0.105), rgb(tint, dark ? 0.10 : 0.135),
                      rgb(tint, dark ? 0.07 : 0.155), rgb(shade, dark ? 0.085 : 0.10), rgb(shade, 0)]
        return CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray,
                          locations: [0, 0.16, 0.47, 0.68, 0.86, 1])
    }

    private static func drawCountStripes(_ count: Int, in cell: CGRect, gradient: CGGradient, context: CGContext) {
        let unit = cell.width
        let descending = count == 2
        let slope: CGFloat = descending ? 1 : -1 // Both the canvas and PNG use top-down coordinates.
        let offsets: [CGFloat] = descending ? [-0.32, 0.32] : [-0.43, 0, 0.43]
        let halfNormal = (descending ? 0.19 : 0.14) * unit / (2 * sqrt(2.0))
        context.saveGState()
        defer { context.restoreGState() }
        context.clip(to: cell)
        for offset in offsets {
            let centerY = cell.midY + offset * unit
            let start = CGPoint(x: cell.midX + slope * halfNormal, y: centerY - halfNormal)
            let end = CGPoint(x: cell.midX - slope * halfNormal, y: centerY + halfNormal)
            context.drawLinearGradient(gradient, start: start, end: end, options: [])
        }
    }

    private static func drawCoordinates(in context: CGContext, geometry: BoardGeometry, visual: NativeBoardAppearance,
                                        accent: CGColor, active: BoardHouse?, hovered: BoardHouse?) {
        let size = min(10, max(6, geometry.unit * 0.17))
        let font = CTFontCreateUIFontForLanguage(.system, size, nil) ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
        let muted = visual.color("candidateColor")
        let axes = (0..<9).flatMap { [BoardHouse(.row, index: $0), BoardHouse(.column, index: $0)] }
        for house in axes + (active.map { $0.kind == .box ? [$0] : [] } ?? []) {
            let rect = geometry.coordinateRect(house)
            let emphasized = house == active || house == hovered
            let text = NSAttributedString(string: house.label, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): emphasized ? accent : muted
            ])
            let line = CTLineCreateWithAttributedString(text)
            let ink = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
            if emphasized {
                let width = min(rect.width, ceil(ink.width) + 6)
                let height = min(rect.height, ceil(ink.height) + 5)
                let badge = CGRect(x: rect.midX - width / 2, y: rect.midY - height / 2, width: width, height: height)
                context.setFillColor(accent.copy(alpha: house == active ? 0.20 : 0.10) ?? accent)
                context.addPath(CGPath(roundedRect: badge, cornerWidth: 3, cornerHeight: 3, transform: nil))
                context.fillPath()
            }
            context.saveGState()
            context.translateBy(x: rect.midX - ink.midX, y: rect.midY + ink.midY)
            context.scaleBy(x: 1, y: -1)
            context.textMatrix = .identity
            context.textPosition = .zero
            CTLineDraw(line, context)
            context.restoreGState()
        }
    }

    static func png(_ frame: BoardFrame, size: Int = 900) throws -> Data {
        guard (32...4096).contains(size),
            let context = CGContext(
                data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw CocoaError(.fileWriteUnknown) }
        context.translateBy(x: 0, y: CGFloat(size))
        context.scaleBy(x: 1, y: -1)
        draw(frame, drag: nil, in: context, bounds: CGRect(x: 0, y: 0, width: size, height: size))
        guard let image = context.makeImage() else { throw CocoaError(.fileWriteUnknown) }
        let data = NSMutableData()
        guard let target = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)
        else { throw CocoaError(.fileWriteUnknown) }
        CGImageDestinationAddImage(target, image, nil)
        guard CGImageDestinationFinalize(target) else { throw CocoaError(.fileWriteUnknown) }
        return data as Data
    }
}
