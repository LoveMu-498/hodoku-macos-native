// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import CryptoKit

enum FilterOptionsChecks {
    static func run() throws {
        func expect(_ condition: Bool, _ detail: String) throws {
            if !condition { throw WorkspaceProblem("Filter/edit settings: " + detail) }
        }
        let old = try JSONDecoder().decode(NativeMouseOptions.self, from: Data(#"{"showCandidates":false}"#.utf8))
        try expect(!old.showCandidates && old.showDeviations && !old.editModeAutoAdvance, "old settings")
        let base = Data("<java class='java.beans.XMLDecoder'><object class='sudoku.Options'/></java>".utf8)
        var prefs = try LegacySettingsFile(base).preferences
        prefs.mouse?.useOrInsteadOfAndForFilter = true
        prefs.mouse?.onlySmallFilters = true
        prefs.mouse?.highlightingGivens = true
        prefs.mouse?.editModeAutoAdvance = true
        let decoded = try LegacySettingsFile(prefs.exportJava()).preferences
        try expect(decoded.mouse == prefs.mouse, "Java configuration round trip")

        // The digest comes from the frozen Java implementation invoked by FilterOptionsOracle.
        var oracleFrame = BoardFrame(page: BoardPage(), selected: nil, reference: nil)
        for cell in 0..<81 {
            let marks = (1...9).filter { (cell + $0) % 3 == 0 }
                .reduce(UInt16(0)) { $0 | NativeBoardSnapshot.bit(UInt8($1)) }
            oracleFrame.page.board.userCandidates[cell] = oracleFrame.page.board.candidates[cell] & marks
        }
        var actual = Data(capacity: 165_564)
        for showCandidates in [true, false] {
            oracleFrame.showCandidates = showCandidates
            for any in [false, true] {
                oracleFrame.filterAnyDigit = any
                for mask: UInt16 in 1...511 {
                    oracleFrame.digitFilter = mask
                    for cell in 0..<81 { actual.append(oracleFrame.filterHighlights(at: cell).cell ? 1 : 0) }
                }
            }
        }
        let hash = SHA256.hash(data: actual).map { String(format: "%02x", $0) }.joined()
        try expect(hash == "ee9ae8cc476924cb83d38ac4c7368637e314cc30d7dbc7d4404908c69c7323a6", "frozen Java mask matrix")
        // R1C3 has normal candidates 1, 2, 4. Keep only 1 as a user pencil mark.
        var frame = BoardFrame(page: BoardPage(), selected: nil, reference: nil)
        frame.page.board.userCandidates[2] = 1
        frame.digitFilter = 5 // 1 and 3.
        try expect(!frame.filterHighlights(at: 2).cell, "default AND must find both")
        frame.filterAnyDigit = true
        try expect(frame.filterHighlights(at: 2).cell, "OR accepts 1")
        frame.filterAnyDigit = false
        frame.countFilters = [3]
        try expect(frame.filterHighlights(at: 2).cell, "count or digit")
        frame.inverseFilter = true
        try expect(!frame.filterHighlights(at: 2).cell && frame.filterHighlights(at: 0).cell, "inverse of union")
        frame.inverseFilter = false
        frame.digitFilter = 3
        try expect(frame.filterHighlights(at: 2).digits == 3, "overlap marks")
        frame.onlySmallFilters = true
        try expect(!frame.filterHighlights(at: 2).cell && frame.filterHighlights(at: 2).digits == 11, "small count marks")
        frame.showCandidates = false
        try expect(frame.filterHighlights(at: 2).digits == 0, "user candidates")
        frame.digitFilter = 16
        frame.highlightingGivens = true
        try expect(frame.filterHighlights(at: 0).cell, "selected given")

        var colors = BoardFrame(page: BoardPage(), selected: 2, reference: nil)
        colors.page.board = .blank
        colors.general.onlySmallCursors = true
        colors.showCandidates = false
        colors.page.boxes.groups[0] = [2, 5]
        colors.page.board.userCandidates[2] = 3
        colors.page.board.userCandidates[3] = 36 // Candidates 3 and 6 stay off the stripe scan.
        colors.page.board.userCandidates[5] = 73
        colors.page.board.userCandidates[6] = 292 // 3, 6 and 9.
        colors.page.board.userCandidates[7] = 15
        let bounds = CGRect(x: 0, y: 0, width: 920, height: 920)
        let geometry = BoardGeometry(bounds: bounds, separatedBoxes: colors.general.drawMode == 0)
        func image(_ frame: BoardFrame) throws -> NSBitmapImageRep {
            guard let bitmap = NSBitmapImageRep(data: try BoardPainter.png(frame, size: 920)) else {
                throw WorkspaceProblem("Missing filter image")
            }
            return bitmap
        }
        func pixel(_ bitmap: NSBitmapImageRep, x: Int, y: Int) -> [Int] {
            var rgb = [Int](repeating: 0, count: 4)
            bitmap.getPixel(&rgb, atX: x, y: y)
            return rgb
        }
        func pixel(_ bitmap: NSBitmapImageRep, cell: Int, x: Int, y: Int) -> [Int] {
            let origin = geometry.rect(cell).origin
            return pixel(bitmap, x: Int(origin.x) + x, y: Int(origin.y) + y)
        }
        func matches(_ pixel: [Int], _ color: CGColor) -> Bool {
            // The painter writes sRGB bytes. Compare those directly, before AppKit's display conversion.
            guard let rgb = color.components, rgb.count == 4 else { return false }
            return (0..<3).allSatisfy { abs(CGFloat(pixel[$0]) - rgb[$0] * 255) < 2 }
        }
        func luminance(_ channels: [CGFloat]) -> CGFloat {
            zip(channels, [0.2126, 0.7152, 0.0722]).reduce(0) { sum, pair in
                let (channel, weight) = pair
                let linear = channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
                return sum + linear * weight
            }
        }
        for mode in [BoardColorMode.light, .dark] {
            colors.colorMode = mode
            colors.digitFilter = 1
            colors.countFilters = []
            let digitOnly = try image(colors)
            colors.countFilters = [2, 3]
            let overlap = try image(colors)
            colors.digitFilter = 0
            let countOnly = try image(colors)
            func stripeStarts(_ bitmap: NSBitmapImageRep, cell: Int, x: Int) -> [Int] {
                var starts: [Int] = []
                var inside = false
                let base = pixel(digitOnly, cell: cell, x: x, y: 50)[1]
                for y in 5...94 {
                    let delta = pixel(bitmap, cell: cell, x: x, y: y)[1] - base
                    let band = (mode == .dark ? delta : -delta) >= 9
                    if band && !inside { starts.append(y) }
                    inside = band
                }
                return starts
            }
            for bitmap in [countOnly, overlap] {
                for (cell, count, direction) in [(3, 2, 1), (6, 3, -1)] {
                    let left = stripeStarts(bitmap, cell: cell, x: 47)
                    let right = stripeStarts(bitmap, cell: cell, x: 53)
                    try expect(left.count == count && right.count == count &&
                               zip(left.dropFirst(), right.dropFirst()).allSatisfy { abs(($1 - $0) - 6 * direction) <= 1 },
                               "\(mode) \(count) stripes with the correct slope across the cell: \(left), \(right)")
                }
                try expect(pixel(bitmap, cell: 3, x: 65, y: 34) != pixel(digitOnly, cell: 3, x: 65, y: 34) &&
                           pixel(bitmap, cell: 3, x: 33, y: 2) != pixel(digitOnly, cell: 3, x: 33, y: 2) &&
                           pixel(bitmap, cell: 4, x: 4, y: 34) == pixel(digitOnly, cell: 4, x: 4, y: 34),
                           "\(mode) stripes reach the boundary and stay clipped to the cell")
                let base = pixel(digitOnly, cell: 3, x: 65, y: 33)[1]
                let center = abs(pixel(bitmap, cell: 3, x: 65, y: 33)[1] - base)
                let edge = abs(pixel(bitmap, cell: 3, x: 65, y: 22)[1] - base)
                try expect(edge > 0 && center > edge && center <= (mode == .dark ? 17 : 28),
                           "\(mode) stripe has a soft edge and restrained contrast: \(edge), \(center)")
            }
            let visual = colors.visual.rendered(mode)
            let green = visual.color("possibleCellColor")
            try expect(matches(pixel(overlap, cell: 2, x: 50, y: 50), green) &&
                       matches(pixel(overlap, cell: 5, x: 38, y: 42), green) &&
                       matches(pixel(overlap, cell: 7, x: 50, y: 50), green),
                       "\(mode) green remains visible between the stripes")
            try expect(pixel(overlap, cell: 2, x: 60, y: 28) != pixel(countOnly, cell: 2, x: 60, y: 28) &&
                       pixel(overlap, cell: 2, x: 60, y: 28) != pixel(digitOnly, cell: 2, x: 60, y: 28),
                       "\(mode) the count stripe and the green fill remain visible at their intersection")
            try expect(matches(pixel(overlap, cell: 2, x: 50, y: 2), visual.color("aktCellColor")) &&
                       zip(pixel(overlap, cell: 5, x: 1, y: 50), pixel(digitOnly, cell: 5, x: 1, y: 50))
                           .allSatisfy { abs($0 - $1) <= 12 },
                       "\(mode) active selection and group box stay above the stripes")
            let glyph = geometry.rect(2, digit: 1)
            let ink = visual.color("candidateColor")
            let foreground = luminance(ink.components!) + 0.05
            for (cell, x, y) in [(2, 60, 28), (5, 50, 50)] {
                let background = luminance(pixel(overlap, cell: cell, x: x, y: y).map { CGFloat($0) / 255 }) + 0.05
                try expect(max(foreground, background) / min(foreground, background) >= 4.5,
                           "\(mode) candidate ink has contrast over green and count-stripe fill")
            }
            var glyphPixels = 0
            var preservedPixels = 0
            for y in Int(glyph.minY)..<Int(glyph.maxY) {
                for x in Int(glyph.minX)..<Int(glyph.maxX) where matches(pixel(digitOnly, x: x, y: y), ink) {
                    glyphPixels += 1
                    if matches(pixel(overlap, x: x, y: y), ink) { preservedPixels += 1 }
                }
            }
            try expect(glyphPixels >= 10 && preservedPixels == glyphPixels, "\(mode) candidate ink stays above the stripes")
            colors.onlySmallFilters = true
            let small = try image(colors)
            try expect(pixel(small, cell: 3, x: 65, y: 34) == pixel(digitOnly, cell: 3, x: 65, y: 34),
                       "\(mode) candidate-only filtering clears the full-cell stripes")
            colors.onlySmallFilters = false
        }

        guard let profile = ProcessInfo.processInfo.environment["HODOKU_NATIVE_DATA_DIR"] else { throw BoardFileError.unsafeLocation }
        let directory = URL(fileURLWithPath: profile).appendingPathComponent("filter-editor-" + UUID().uuidString)
        print("Temporary filter/edit checks: \(directory.path); remove after tests")
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = NativeBoardModel(directory: directory, automaticTimers: false)
        var game = try NativePuzzleFiles.readText(String(repeating: "0", count: 81))
        var context = NativeGameContext()
        context.editingClues = true
        game.extra = context
        try model.installGame(game)
        model.generalOptions.deleteCursorDisplay = true
        model.generalOptions.deleteCursorDisplayLength = 5
        model.select(8)
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.04))
        try expect(model.frame.hideSelection && model.selected == 8, "cursor timeout preserves the active cell")
        model.selectCells([8, 9])
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.04))
        try expect(!model.frame.hideSelection, "multi-cell selections remain visible")
        model.generalOptions = NativeGeneralOptions()
        model.select(8)
        model.mouseOptions.editModeAutoAdvance = true
        model.enterKeyboardDigit(5)
        try expect(model.selected == 8 && model.progress.current.board.values[8] == 5, "digit stays in cell")
        model.enterKeyboardDigit(0)
        try expect(model.selectionCells == [8, 9] && model.progress.current.board.values[8] == 0, "zero wraps to next row")
        model.select(80)
        model.deleteWithKeyboard()
        try expect(model.selected == 80, "bottom right")
        model.select(7)
        model.mouseOptions.editModeAutoAdvance = false
        model.deleteWithKeyboard()
        try expect(model.selected == 7, "advance disabled")
        try expect(NativeBoardStatus(model: model).mode == "录题", "status shows actual clue-entry mode")

        var attempt = BoardProgress()
        attempt.current.board.userCandidates[2] = 1
        attempt.extra = NativeGameContext(difficulty: 4, mode: "LEARNING", score: 500)
        try model.installGame(attempt)
        model.select(0)
        model.generalOptions.colorValues = false
        model.togglePlayMenuColor(2)
        try expect(model.progress.current.marks.isEmpty, "filled cells reject coloring")
        model.generalOptions.colorValues = true
        model.togglePlayMenuColor(2)
        try expect(model.progress.current.marks.count == 1, "filled cells accept coloring")
        let almostSolved = "034678912672195348198342567859761423426853791713924856961537284287419635345286179"
        try model.installGame(NativePuzzleFiles.readText(almostSolved))
        model.generalOptions.showSudokuSolved = true
        model.select(0)
        model.edit(7)
        try expect(model.operationMessageID != "native-sudoku-solved", "conflicting full grid is not solved")
        model.edit(0)
        model.edit(5)
        try expect(model.operationMessageID == "native-sudoku-solved", "valid full grid reports completion")
        try model.installGame(attempt)
        model.select(2)
        model.mouseOptions.showCandidates = true
        var status = NativeBoardStatus(model: model)
        try expect(status.mode == "学习" && status.grade == "艰难" && status.score == 500, "recorded grade and mode")
        try expect(status.filled == 30 && status.selection == "R1C3" && status.selectedContent == "候选 1、2、4", "selected cell")
        model.mouseOptions.showCandidates = false
        try expect(NativeBoardStatus(model: model).selectedContent == "笔记 1", "status follows displayed marks")
        model.revealCandidates(all: false, active: true)
        try expect(NativeBoardStatus(model: model).selectedContent == "候选 1、2、4", "held selected-candidate preview")
        model.revealCandidates(all: false, active: false)
        model.toggleFreeze()
        model.mouseOptions.showCandidates = true
        try expect(NativeBoardStatus(model: model).selectedContent == "笔记 1", "frozen status follows captured marks")
        model.toggleFreeze()
        model.selectCells([2, 3])
        status = NativeBoardStatus(model: model)
        try expect(status.selection == "已选 2 格" && status.selectedContent == "共同候选 2"
                   && status.selectionDetail == "2 个空格，合计候选 1、2、4、6", "multi-selection intersection and union")
        model.selectCells([0, 2, 3])
        try expect(NativeBoardStatus(model: model).selectedContent == "共同候选 2", "givens do not erase the empty-cell intersection")
        model.selectCells([0, 1])
        try expect(NativeBoardStatus(model: model).selectedContent == "给定 2 格，已填 0 格", "filled selection")
        let original = model.progress.current.board
        func clickFilter(_ digit: UInt8, _ flags: NSEvent.ModifierFlags) {
            model.toggleHintDigit(digit, additive: CandidateDigitFilters.isAdditive(flags, sticky: false))
        }
        model.cycleToolbarFilter(1)
        try expect(model.hintDigits == 0, "wheel with no digit does not start filtering")
        clickFilter(9, [])
        model.toggleCountFilter(3)
        model.cycleToolbarFilter(1)
        try expect(model.hintDigits == 1 && model.countFilters == [3], "9 wraps to 1 without changing count filters")
        model.cycleToolbarFilter(-1)
        try expect(model.hintDigits == 256, "1 wraps back to 9")
        model.toggleFreeze()
        model.cycleToolbarFilter(1)
        try expect(model.hintDigits == 256, "frozen filters do not scroll")
        model.toggleFreeze()
        clickFilter(9, [])
        model.toggleCountFilter(3)
        clickFilter(4, [])
        clickFilter(6, .command)
        model.cycleToolbarFilter(1)
        try expect(NativeBoardStatus(model: model).filterSummary == "筛选 4、6（同时含有）", "Command adds a digit and disables wheel cycling")
        model.mouseOptions.useOrInsteadOfAndForFilter = true
        model.toggleCountFilter(2)
        try expect(NativeBoardStatus(model: model).filterSummary == "筛选 4、6（含其一） 或 双值格", "OR setting and count filter")
        clickFilter(6, .control)
        try expect(NativeBoardStatus(model: model).filterSummary == "筛选 4 或 双值格", "Control removes one digit")
        model.toggleCountFilter(2)
        clickFilter(4, [])
        try expect(!NativeBoardStatus(model: model).filtered && model.progress.current.board == original, "filter actions leave board intact")
        try expect(!model.statusPaletteWheel(1, at: 1000), "play has no palette wheel")
        model.chooseTool(.color)
        let firstColor = model.color
        for tick in [1001, 1010, 1020] { _ = model.statusPaletteWheel(1, at: tick) }
        try expect(model.color == (firstColor + 1) % 6, "one color per wheel gesture")
        _ = model.statusPaletteWheel(-1, at: 1500)
        try expect(model.color == firstColor, "reverse palette wheel")
        model.toggleFreeze()
        try expect(!model.statusPaletteWheel(1, at: 2000), "frozen palette")
        model.toggleFreeze()
        attempt.extra = NativeGameContext(difficulty: 0, score: 0)
        try model.installGame(attempt)
        status = NativeBoardStatus(model: model)
        try expect(status.grade == nil && status.score == nil && status.mode == "作答", "unrated import")
        print("PASS filter AND/OR, inverse union, overlap, small markers, givens, user masks, clue editing and settings migration")
        print("PASS digit filter wheel wrap, multi-selection gating, and light/dark count bands")
        print("PASS board status, selected value source, frozen marks and annotation palette wheel")
    }
}
