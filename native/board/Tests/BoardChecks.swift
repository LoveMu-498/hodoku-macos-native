import AppKit
import ImageIO

private struct Failure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

private func check(_ okay: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !okay() { throw Failure(message: message) }
}

#if !COMBINED_BOARD_CHECKS
@main
#endif
enum BoardChecks {
    private static let geometry = BoardGeometry(bounds: CGRect(x: 0, y: 0, width: 920, height: 920))
    private static func point(_ cell: Int, _ digit: Int = 0) -> CGPoint {
        let rect = geometry.rect(cell, digit: digit)
        return CGPoint(x: rect.midX, y: rect.midY)
    }
    private static func model(_ directory: URL) -> NativeBoardModel {
        NativeBoardModel(directory: directory, automaticTimers: false, doubleClickMillis: 200)
    }
    private static func click(_ m: NativeBoardModel, _ p: CGPoint, _ at: Int, _ button: BoardButton = .left) {
        m.press(p, button: button, modifiers: [], at: at, geometry: geometry)
        m.release(p, button: button, at: at + 1, geometry: geometry)
    }
    private static func has(_ m: NativeBoardModel, _ cell: Int, _ digit: Int = 0) -> Bool {
        m.progress.current.marks.contains { $0.cell == cell && $0.digit == digit }
    }

    static func main() throws {
        guard let supplied = ProcessInfo.processInfo.environment["HODOKU_NATIVE_DATA_DIR"], !supplied.isEmpty else {
            throw Failure(message: "Run with HODOKU_NATIVE_DATA_DIR set to an isolated test directory.")
        }
        let base = URL(fileURLWithPath: supplied, isDirectory: true)
        let scratch = base.appendingPathComponent("board-checks-" + UUID().uuidString, isDirectory: true)
        print("temporary board fixtures: \(scratch.path); remove after test")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        try gestures(scratch.appendingPathComponent("input"))
        try editing(scratch.appendingPathComponent("edits"))
        try reading(scratch.appendingPathComponent("reading"))
        try asyncRequests(scratch.appendingPathComponent("async"))
        try filteredBoxHints(scratch.appendingPathComponent("filtered-boxes"))
        try confirmDisplayedAnswer(scratch.appendingPathComponent("displayed-answer"))
        try inkAnswer(scratch.appendingPathComponent("ink-answer"))
        try deletionReading(scratch.appendingPathComponent("deletion"))
        try saving(scratch.appendingPathComponent("saves"))
        try protectLegacy(scratch.appendingPathComponent("Application Support"))
        print("PASS native board: pointer arbitration, tool histories, four arrays, hint lifecycle, frozen PNG, isolated save, retry and concurrent edits")
    }

    private static func gestures(_ directory: URL) throws {
        let grid = geometry.grid
        try check(geometry.cell(at: grid.origin) == 0 && geometry.cell(at: CGPoint(x: grid.maxX, y: grid.midY)) == nil &&
                  geometry.cell(at: CGPoint(x: grid.minX, y: grid.maxY)) == nil &&
                  geometry.cell(at: CGPoint(x: grid.maxX.nextDown, y: grid.maxY.nextDown)) == 80, "half-open board bounds")
        let m = model(directory)
        let a = point(2, 1), b = point(40)
        m.chooseTool(.color)
        click(m, a, 100)
        try check(has(m, 2) && !has(m, 2, 1), "first release immediately shows cell color")
        try check(!FileManager.default.fileExists(atPath: NativeBoardStore(directory: directory).file.path),
                  "provisional mark should not be durable")
        m.press(a, button: .left, modifiers: [], at: 300, geometry: geometry)
        try check(has(m, 2), "second press preserves provisional mark")
        m.release(a, button: .left, at: 450, geometry: geometry)
        try check(!has(m, 2) && has(m, 2, 1) && m.progress.markUndo.count == 1, "double at 200ms replaces first edit")
        m.history(redo: false)
        try check(m.progress.current.marks.isEmpty, "undo double in one step")
        m.history(redo: true)
        click(m, a, 600)
        m.tick(801)
        click(m, b, 1000)
        m.tick(1201)
        let old = m.progress
        click(m, a, 1400, .right)
        let start = CGPoint(x: b.x - 25, y: b.y - 25)
        m.press(start, button: .right, modifiers: [], at: 1500, geometry: geometry)
        m.move(CGPoint(x: start.x + 3, y: start.y), geometry: geometry)
        try check(!has(m, 2) && has(m, 2, 1) && m.drag == nil, "right second press and 3pt hold first erase")
        m.move(CGPoint(x: start.x + 4, y: start.y), geometry: geometry)
        try check(m.progress == old && m.drag?.rectangle == true, "4pt right cross-target rollback restores histories")
        let end = CGPoint(x: b.x + 25, y: b.y + 25)
        m.release(end, button: .right, at: 1600, geometry: geometry)
        try check(has(m, 2) && has(m, 2, 1) && !has(m, 40), "box uses second press and removes contained centers")
        m.history(redo: false)
        try check(m.progress.current == old.current, "one undo restores exactly the two pre-gesture positions")
        m.history(redo: true)
        try check(!has(m, 40), "redo final rectangle")

        click(m, a, 1900, .right)
        m.press(start, button: .right, modifiers: [], at: 1940, geometry: geometry)
        m.move(end, geometry: geometry)
        m.escape()
        m.release(end, button: .right, at: 1990, geometry: geometry)
        try check(has(m, 2) && m.drag == nil, "Escape cancels replacement drag and subsequent release")
        click(m, a, 2100, .right)
        m.focus(false, now: 2120)
        try check(!has(m, 2) && has(m, 2, 1) && model(directory).progress == m.progress,
                  "focus loss commits lone single")
        m.focus(true, now: 2200)
        click(m, a, 2300)
        m.press(a, button: .left, modifiers: [], at: 2340, geometry: geometry)
        m.focus(false, now: 2350)
        try check(!has(m, 2) && has(m, 2, 1) && model(directory).progress == m.progress,
                  "focus loss cancels same-target replacement; reopening restores the prior state")
        m.focus(true, now: 2400)
        click(m, a, 2500)
        click(m, point(2, 2), 2550)
        m.tick(2800)
        try check(!has(m, 2, 2) && has(m, 2), "nearby distinct visible digits remain single clicks")
        click(m, point(2, 1), 3000, .right)
        click(m, point(40, 5), 3040, .right)
        m.tick(3300)
        try check(!has(m, 2) && !has(m, 40), "right cross-target without drag keeps both singles")
        click(m, a, 3400)
        m.tick(3650)
        click(m, a, 3800, .right)
        m.press(start, button: .right, modifiers: [], at: 3840, geometry: geometry)
        m.focus(false, now: 3900)
        try check(!has(m, 2) && model(directory).progress == m.progress, "deactivation before cross-target drag commits the single")
    }

    private static func editing(_ directory: URL) throws {
        let m = model(directory)
        var edits = 0
        m.didEdit = { _ in edits += 1 }
        m.select(0)
        m.edit(9)
        try check(m.progress.current.board == .example && edits == 0, "givens locked")
        var board = NativeBoardSnapshot.example
        let bit = NativeBoardSnapshot.bit(1)
        board.candidates[3] &= ~bit
        board.userCandidates[2] = bit
        board.userCandidates[6] = bit
        board.setValue(1, at: 2)
        try check(board.values[2] == 1 && board.candidates[2] == 0 && board.userCandidates[6] == 0,
                  "placement updates four arrays")
        board.setValue(0, at: 2)
        try check(board.userCandidates[2] == 0 && board.userCandidates[6] == 0, "clearing does not fabricate user notes")
        try board.validate()
        m.select(40)
        m.edit(5)
        try check(!m.hint.available && edits == 1, "board mutation invalidates source")
        try check(model(directory).progress == m.progress, "new instance restores board and history")
        m.chooseTool(.color)
        m.history(redo: false)
        try check(m.progress.current.board.values[40] == 5, "color undo cannot undo board")
        m.chooseTool(.play)
        m.history(redo: false)
        try check(m.progress.current.board == .example && !m.hint.available && edits == 2, "undo restores four arrays")
        m.history(redo: true)
        m.edit(0)
        try check(m.progress.current.board == .example && edits == 4, "redo and delete")
    }

    private static func runMain(until satisfied: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(5)
        while !satisfied(), Date() < deadline {
            _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        try check(satisfied(), "timed out waiting for main-thread delivery")
    }

    private static func awaitHint(_ model: NativeBoardModel) throws {
        try runMain { !model.hintRequestPending }
    }

    private static func asyncRequests(_ directory: URL) throws {
        let queue = DispatchQueue(label: "HoDoKu test hints")
        let m = NativeBoardModel(directory: directory, automaticTimers: false, hintQueue: queue)
        func drainDelivery() throws {
            queue.sync {}
            var drained = false
            DispatchQueue.main.async { drained = true }
            try runMain { drained }
        }

        m.openTechniqueChooser()
        try check(m.choosingTechnique && m.techniqueLookupPending, "named lookup starts in background")
        try runMain { !m.techniqueLookupPending }
        guard let named = m.techniqueInstances[.hiddenSingle]?.last else { throw Failure(message:"named catalogue lacks hidden singles") }
        let untouched = m.progress
        m.previewTechnique(named)
        try check(!m.frame.preview.isEmpty && m.progress == untouched && m.reading == nil, "browsing only previews the selected instance")
        m.adoptTechnique(named)
        try check(m.reading?.step == named && m.knownTechnique == .hiddenSingle && m.reading?.index == 0 &&
                  m.progress == untouched && !m.choosingTechnique, "adopting retains the name and starts at stage one")
        m.openTechniqueChooser(); m.closeTechniqueChooser(); try drainDelivery()
        try check(m.reading?.step == named && !m.choosingTechnique, "dismissing catalogue preserves accepted reading")
        m.closeHint()
        m.openTechniqueChooser(); queue.sync {}; m.select(40); m.edit(5); m.history(redo:false)
        try drainDelivery()
        try check(!m.choosingTechnique && m.techniqueInstances.isEmpty && m.reading == nil, "stale named scan is discarded")

        m.toggleHintDigit(5, additive: false)
        m.openCurrentReasoning()
        try check(m.techniqueLookupPending && !m.choosingTechnique && !m.isHintDrawerAvailable &&
                  m.hintSearchMessage == m.generalOptions.localized("正在查找步骤…"),
                  "Tab uses the progress toast without presenting a panel")
        try drainDelivery()
        try check(!m.techniqueLookupPending && m.hintSearchMessage == nil && m.choosingTechnique &&
                  m.techniqueTab == .reasoning && !m.techniqueInstances.isEmpty,
                  "successful Tab publishes the scoped list after it is ready")
        m.closeTechniqueChooser()
        m.openCurrentReasoning()
        queue.sync {}
        m.escape()
        try drainDelivery()
        try check(!m.techniqueLookupPending && !m.choosingTechnique && m.hintSearchMessage == nil &&
                  m.hintDigits == NativeBoardSnapshot.bit(5), "Escape cancels only the pending search")
        m.openCurrentReasoning()
        queue.sync {}
        m.toggleHintDigit(5, additive: false); m.toggleHintDigit(5, additive: false)
        try drainDelivery()
        try check(!m.choosingTechnique && m.hintSearchMessage == nil, "changing a scope and returning to it cannot revive a lookup")

        let savedConfig = m.solverConfig
        m.solverConfig.rules.removeAll()
        m.openCurrentReasoning()
        try drainDelivery()
        try check(!m.choosingTechnique && m.hintSearchMessage == nil &&
                  m.operationMessage?.contains("未找到匹配的解题步骤") == true,
                  "an empty match gives guidance in the toast without opening the panel")
        m.solverConfig = savedConfig
        m.toggleHintDigit(5, additive: false)

        // The actual Rust invocation has finished, but its completion is still in the main queue.
        m.openHint()
        try check(m.hintSearchMessage == m.generalOptions.localized("正在查找步骤…") && !m.isHintDrawerAvailable,
                  "first request immediately reports progress outside the drawer")
        queue.sync {}
        try check(m.hintRequestPending && m.reading == nil, "request does not block AppKit")
        m.select(40); m.edit(5); m.history(redo: false)
        try drainDelivery()
        try check(m.progress.current.board == .example && m.reading == nil && m.hintSearchMessage == nil,
                  "edit and undo cannot revive a completed background proof")

        m.hintKey(down: true, now: 10); m.hintKey(down: false, now: 15)
        try awaitHint(m)
        try check(m.reading?.step.placementCell == 40 && m.frame.reference == 0 &&
                  m.isHintDrawerAvailable && m.hintSearchMessage == nil,
                  "first H tap during computation reaches the real stage")
        m.closeHint()
        m.openHint(); m.moveHint(100)
        try awaitHint(m)
        try check(m.reading?.isFinal == true, "full-hint shortcut survives async delivery")
        m.closeHint()
        m.openHint(); queue.sync {}; m.escape()
        try drainDelivery()
        try check(m.reading == nil && m.hintSearchMessage == nil, "Escape retires a queued reply")
        m.openHint(); queue.sync {}; m.toggleFreeze(); m.toggleFreeze()
        try drainDelivery()
        try check(m.reading == nil && m.hintSearchMessage == nil, "freeze and thaw cannot install an old hint")

        var valid = true
        m.openBoxHint(cells: [40], sourceIsCurrent: { valid })
        queue.sync {}; valid = false; m.invalidateHintSourceIfNeeded(); valid = true
        try drainDelivery()
        try check(m.reading == nil && m.hintSearchMessage == nil, "changed and restored selection retires the request")
        m.openBoxHint(cells: [40], sourceIsCurrent: { true })
        try awaitHint(m)
        try check(m.reading?.step.placementCell == 40, "selected Rust result reaches main thread")
        try check(m.reading?.isFinal == true, "full selection opens executable final stage")
        m.openBoxHint(cells: [0,1], sourceIsCurrent: { true })
        try awaitHint(m)
        try check(m.reading == nil && m.operationMessage?.contains("调整选框") == true && !m.isHintDrawerAvailable,
                  "no matching step explains how to adjust the box")
        m.quickHint()
        try check(!m.hintRequestPending && m.reading == nil && m.operationMessage?.contains("先筛选 1 或 2 个数字") == true,
                  "Tab without supported inputs explains the required filter without searching the whole board")
        m.toggleHintDigit(5, additive:false); m.quickHint(); try awaitHint(m)
        try check(m.reading?.step.digits == NativeBoardSnapshot.bit(5) && m.reading?.step.placementCell == 40,
                  "single-digit Tab selects an actual matching Java-priority proof")
        m.toggleHintDigit(3, additive:true)
        try check(m.reading?.step.digits == NativeBoardSnapshot.bit(5), "filter change preserves already accepted evidence")
        m.mouseOptions.operationSoundsEnabled = false
        let beforeUnmatchedHint = m.progress
        m.quickHint(); try awaitHint(m)
        try check(!m.isHintDrawerAvailable && m.operationMessage?.hasPrefix("未找到匹配的解题步骤。") == true &&
                  m.operationMessage?.contains("⌥F12 查找全盘") == true &&
                  m.progress == beforeUnmatchedHint,
                  "two-digit Tab without a match explains the full-board fallback even with sounds off")
        m.toggleHintDigit(5, additive:false)
        try check(m.hintDigits == 0, "reselecting an active exclusive filter clears all")
        m.openHint(); try awaitHint(m); m.moveHint(1)
        guard let first = m.reading else { throw Failure(message:"missing reading") }
        try check(m.annotateHint(id:first.id,stage:first.index,reference:0,whole:false,group:0,box:true),
                  "add the displayed R5C5 reference as a source box")
        m.chooseTool(.boxes)
        m.quickHint()
        try awaitHint(m)
        guard let quick = m.reading else { throw Failure(message:"selected Tab result missing") }
        try check(quick.index == 0 && quick.step.placementCell == 40, "Tab starts at the first stage of its source proof")
        m.moveHint(1); m.quickHint()
        try check(m.reading?.id == quick.id && m.reading?.index == 1 && !m.hintRequestPending,
                  "repeated Tab preserves the adopted result and stage")
        m.inspectSource(); try awaitHint(m)
        let countBefore = m.progress.boardUndo.count
        try check(m.reading?.isFinal == true && m.progress.current.board.values[40] == 0,
                  "first S Enter previews the full result and leaves the board unchanged")
        m.inspectSource()
        try check(m.progress.boardUndo.count == countBefore+1 && m.progress.current.board.values[40] == 5 &&
                  m.progress.current.boxes.footprint.isEmpty, "second Enter applies once and consumes the verified box")
        m.chooseTool(.boxes); m.history(redo:false)
        try check(m.progress.current.boxes.footprint == [40] && m.progress.current.board.values[40] == 5,
                  "box undo restores only the consumed source")

        m.chooseTool(.chain)
        click(m, point(2, 1), 100)
        m.tick(400)
        let withOnlyStart = m.progress
        try check(withOnlyStart.current.chains.active != nil, "chain is still being drawn")
        m.openCurrentReasoning()
        try check(!m.techniqueLookupPending && m.operationMessage == "先连起两个候选节点" &&
                  m.progress == withOnlyStart, "Tab explains when the chain only has a start")

        let solved = "534678912672195348198342567859761423426853791713924856961537284287419635345286179"
        var completed = NativeBoardSnapshot.example
        for (cell, digit) in solved.utf8.enumerated() where !completed.fixed[cell] {
            completed.setValue(digit - 48, at: cell)
        }
        let game = BoardProgress(current: BoardPage(board: completed))
        try m.installGame(game)
        m.openHint()
        try awaitHint(m)
        try check(m.operationMessage == "棋盘已填满。" && !m.isHintDrawerAvailable && m.progress.current.board == completed,
                  "ordinary hint on a completed grid explains the outcome in the toast")
    }

    private static func filteredBoxHints(_ directory: URL) throws {
        let grid = """
            7 2 18 158 58 3 6 4 9
            13468 138 1348 16789 2 1678 78 78 5
            168 5 9 4 68 1678 3 278 128
            12348 6 5 138 7 1248 2489 289 248
            12348 13789 13478 13568 4568 124568 245789 256789 2468
            248 78 478 568 9 24568 1 3 2468
            138 1378 2 5678 4568 9 458 568 3468
            5 378 378 678 1 4678 2489 2689 23468
            9 4 6 2 3 58 58 1 7
            """.split(whereSeparator: { $0.isWhitespace })
        let values = grid.map { $0.count == 1 ? UInt8($0)! : 0 }
        let entered: Set<Int> = [1, 19, 20, 76, 79]
        let fixed = values.indices.map { values[$0] != 0 && !entered.contains($0) }
        let candidates = grid.map { cell in
            cell.count == 1 ? 0 : cell.utf8.reduce(UInt16(0)) { $0 | NativeBoardSnapshot.bit($1 - 48) }
        }
        let board = NativeBoardSnapshot(values: values, fixed: fixed, candidates: candidates,
                                        userCandidates: Array(repeating: 0, count: 81))
        var boxes = BoxToolState()
        boxes.groups[0] = [42, 43] // R5C7 and R5C8
        let m = model(directory)
        try m.installGame(BoardProgress(current: BoardPage(board: board, boxes: boxes)))
        m.chooseTool(.boxes)

        m.quickHint()
        try awaitHint(m)
        try check(m.reading?.step.technique.key == "HIDDEN_PAIR", "unfiltered boxes use standard box priority")
        let pair = m.reading?.id
        m.toggleHintDigit(5, additive: false)
        try check(m.reading?.id == pair, "a filter change preserves the accepted proof until another explicit match")
        m.quickHint()
        try awaitHint(m)
        let five = NativeBoardSnapshot.bit(5)
        guard let pointing = m.reading?.step, pointing.technique.key == "LOCKED_CANDIDATES_1" else {
            throw Failure(message: "filtered boxes did not prefer the complete pointing proof")
        }
        try check(pointing.digits == five && [39, 40, 41].allSatisfy { pointing.deletions[$0] == five } &&
                  pointing.deletions.filter { $0 != 0 }.count == 3 && m.progress.current.board == board,
                  "pointing 5 previews exactly R5C4–R5C6 without editing the board")

        m.toggleHintDigit(8, additive: false)
        m.quickHint()
        try awaitHint(m)
        try check(m.reading?.step.technique.key == "HIDDEN_PAIR", "without a complete 8 match, fall back to box priority")
        m.toggleHintDigit(5, additive: false)
        m.quickHint()
        m.toggleHintDigit(7, additive: true)
        try check(!m.hintRequestPending && m.reading == nil, "changing the filter cancels an in-flight box lookup")
        m.quickHint()
        try awaitHint(m)
        try check(m.reading?.step.technique.key == "HIDDEN_PAIR", "multiple filtered digits preserve box priority")

        m.closeHint()
        m.toggleHintDigit(7, additive: true)
        m.analyzeHint()
        try awaitHint(m)
        m.moveHint(100)
        try check(m.reading?.isFinal == true && m.reading?.step == pointing && m.progress.current.board == board,
                  "the analysis key finds the same proof without applying it")
        m.enterBoardKey()
        try check(m.progress.current.board == pointing.applying(to: board), "Return applies the previewed proof")
    }

    private static func confirmDisplayedAnswer(_ directory: URL) throws {
        for tool in [BoardTool.boxes, .chain, .ink] {
            let m = model(directory.appendingPathComponent(String(describing: tool)))
            m.chooseTool(tool)
            m.toggleHintDigit(5, additive: false)
            m.quickHint()
            try awaitHint(m)
            guard let reading = m.reading, let expected = reading.step.applying(to: reading.source) else {
                throw Failure(message: "missing scoped digit proof in drawing mode")
            }
            let before = m.progress
            m.moveHint(100)
            try check(m.reading?.id == reading.id && m.reading?.isFinal == true && m.progress == before,
                      "reading the answer in a drawing tool is read-only")
            m.enterBoardKey()
            try check(m.progress.current.board == expected && m.progress.boardUndo.count == before.boardUndo.count + 1 &&
                      !m.hintRequestPending, "Enter confirms the visible scoped answer from any drawing tool")
        }
    }

    private static func inkAnswer(_ directory: URL) throws {
        let board = NativeBoardSnapshot(values: Array(repeating: 0, count: 81), fixed: Array(repeating: false, count: 81),
                                        candidates: Array(repeating: 511, count: 81), userCandidates: Array(repeating: 511, count: 81))
        var ink = InkToolState()
        ink.strokes = [InkStroke(kind: .circle, group: 0, width: 0.005, cell: 0, digit: 3, outlined: true),
                       InkStroke(kind: .circle, group: 0, width: 0.005, cell: 16, digit: 7, outlined: true),
                       InkStroke(kind: .cross, group: 0, width: 0.005, cell: 10, digit: 4, outlined: true),
                       InkStroke(kind: .circle, group: 1, width: 0.005, cell: 80, digit: 8)]
        let m = model(directory)
        try m.installGame(BoardProgress(current: BoardPage(board: board, ink: ink)))
        m.chooseTool(.ink)
        let before = m.progress
        let operations = m.recorder.document.frames.count
        m.analyzeHint()
        guard let first = m.reading else { throw Failure(message: "P analysis failed to preview the outlined answer") }
        try check(first.isFinal && first.step.inkConclusions?.truths == [3,167] && first.step.inkConclusions?.falses == [104] &&
                  m.progress == before && m.recorder.document.frames.count == operations,
                  "P preview preserves board, strokes, undo and replay and identifies only explicit targets")
        m.escape()
        try check(m.reading == nil && m.progress == before && !m.applyHint(id: first.id), "Escape discards only the P answer")
        m.analyzeHint(); let changedColor = m.reading!.id
        m.chooseColor(1); m.chooseColor(0)
        try check(m.reading == nil && !m.applyHint(id: changedColor) && m.progress == before, "changing ink group retires its pending confirmation")
        m.analyzeHint()
        let changedSource = m.reading!.id
        m.clearAnnotations(all: false)
        try check(m.reading == nil && !m.applyHint(id: changedSource) && m.progress.current.board == board, "source edit retires a P answer")
        m.history(redo: false)
        m.analyzeHint()
        let confirmed = m.reading!.id
        m.enterBoardKey()
        try check(m.progress.current.board.values[0] == 3 && m.progress.current.board.values[16] == 7 &&
                  (m.progress.current.board.candidates[10] | m.progress.current.board.userCandidates[10]) & 8 == 0 &&
                  m.progress.boardUndo == [board] && m.progress.current.ink.strokes == [ink.strokes.last!] &&
                  !m.applyHint(id: confirmed), "P confirms the displayed multi-placement and deletion batch once and preserves unrelated ink")
        try check(m.recorder.document.frames.suffix(2).map(\.kind) == ["doodle-conclusion-input", "doodle-conclusion-result"],
                  "P records the input and result together only on confirmation")
        m.chooseTool(.play); m.history(redo: false)
        try check(m.progress.current.board == board, "one puzzle undo restores both candidate layers and every placement")
    }

    private static func reading(_ directory: URL) throws {
        var held = BoardHintGesture(referenceCount: 2)
        held.press(10)
        held = held.rebound(to: 3, keepingKey: true)
        try check(held.visible && held.index == 0, "same-session stage change retains the physical H hold")
        held.release(40)
        held.tick(400)
        try check(!held.visible && held.deadline == nil, "continued H release cannot toggle a lock")
        let original = NativeBoardSnapshot.example
        let m = model(directory)
        m.openHint()
        try awaitHint(m)
        guard let reading = m.reading else { throw Failure(message: "Rust returned no step on the bundled position") }
        try check(reading.step.technique == .nakedSingle && reading.step.placementCell == 40 && reading.step.placementDigit == 5, "Rust selects R5C5 on Java baseline")
        try check(reading.stages.count == 3 && reading.current.references.map(\.label) == ["第2大行"] &&
                  !reading.current.text.contains("R5C5") && !m.applyHint(id: reading.id), "anonymous area, no early execution")
        m.moveHint(1)
        try check(m.reading?.current.references.map(\.label) == ["R5C5"] && !m.applyHint(id: reading.id), "target disclosure without the digit")
        m.hintKey(down: true, now: 100)
        try check(m.frame.reference == 0, "H press exposes first reference")
        m.hintKey(down: false, now: 350)
        try check(m.frame.reference == nil, "250ms hold is temporary")
        m.hintKey(down: true, now: 500)
        m.hintKey(down: false, now: 510)
        m.tick(810)
        m.hintKey(down: true, now: 810)
        m.hintKey(down: false, now: 815)
        try check(m.frame.reference == 0, "second press at +300ms stays on the only disclosed reference")
        m.focus(false, now: 820)
        try check(m.frame.reference == nil, "kept H pauses on deactivate")
        m.focus(true, now: 900)
        try check(m.frame.reference == 0, "kept H resumes")
        m.hintKey(down: true, now: 1100)
        try check(m.wheel(0.5, now: 1110) && m.wheel(0.5, now: 1120) && m.frame.reference == 0, "precise wheel accumulates")
        m.hintKey(down: false, now: 1130)
        try check(m.wheel(1, now: 1450) && m.frame.reference == 0 && !m.wheel(1, now: 1800), "wheel tail owns input until quiet")
        let capture = m.frame
        m.toggleFreeze()
        m.select(40)
        m.edit(5)
        try check(m.frozen == capture && m.frame == capture, "frozen read-only frame")
        let image = try BoardPainter.png(capture, size: 470)
        guard let source = CGImageSourceCreateWithData(image as CFData, nil),
              let decoded = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw Failure(message: "invalid PNG") }
        try check(decoded.width == 470 && decoded.height == 470, "PNG image dimensions")
        m.toggleFreeze()
        m.moveHint(1)
        try check(m.reading?.isFinal == true && m.progress.current.board == original, "full proof reads without editing")
        try check(m.applyHint(id: reading.id) && m.progress.boardUndo == [original], "confirm applies exactly one board action")
        try check(m.reading == nil && !m.applyHint(id: reading.id) && m.progress.current.board.values[40] == 5, "old authority consumed")
        let committed = m.progress.current.board
        m.history(redo: false)
        try check(m.progress.current.board == original && !m.applyHint(id: reading.id), "undo restores four arrays and does not revive old identity")
        m.openHint()
        try awaitHint(m)
        guard let second = m.reading else { throw Failure(message: "missing fresh source after undo") }
        m.moveHint(2)
        try check(second.id != reading.id && !m.applyHint(id: reading.id), "stale callback cannot confirm a new reading")
        m.history(redo: true)
        try check(m.progress.current.board == committed && !m.applyHint(id: second.id), "redo invalidates current reading")
        m.openHint()
        try awaitHint(m)
        try check(m.reading?.step.placementCell != nil && m.reading?.step.placementCell != 40, "next real position produces its own Rust step")
        try check(model(directory).progress.current.board == committed, "applied position resumes from independent native storage")
        try check(try BoardPainter.png(capture, size: 470) == image &&
                  BoardPainter.png(m.frame, size: 470) != image, "captured PNG independent of later live edits")
    }

    private static func deletionReading(_ directory: URL) throws {
        var original = NativeBoardSnapshot(values: Array(repeating: 0, count: 81), fixed: Array(repeating: false, count: 81),
                                           candidates: Array(repeating: 511, count: 81), userCandidates: Array(repeating: 3, count: 81))
        original.candidates[0] = 3
        original.candidates[1] = 3
        var saved = BoardProgress()
        saved.current.board = original
        try NativeBoardStore(directory: directory).save(saved)
        let m = model(directory)
        m.openHint()
        try awaitHint(m)
        guard let r = m.reading else { throw Failure(message: "missing locked pair") }
        try check(r.step.technique == .lockedPair && r.step.premises == [0, 1], "Rust selected Java locked pair")
        m.moveHint(2)
        m.hintKey(down: true, now: 10)
        try check(m.frame.preview.first?.cells == [0], "preview matches first proof cell")
        try check(m.wheel(1, now: 20) && m.frame.preview.first?.cells == [1], "wheel selects next proof cell")
        try check(m.wheel(1, now: 25) && m.frame.preview.first?.cells == [0,1], "keyboard union follows consecutive text references")
        m.hintKey(down: false, now: 30)
        m.moveHint(1)
        let expectedTargets = [2,3,4,5,6,7,8,9,10,11,18,19,20]
        try check(r.step.deletions.indices.filter { r.step.deletions[$0] != 0 } == expectedTargets, "all row and box eliminations")
        try check(m.applyHint(id: r.id), "apply elimination")
        var expected = original
        for cell in expectedTargets { expected.candidates[cell] &= ~3 }
        try check(m.progress.current.board == expected && m.progress.boardUndo == [original], "one transaction deletes exactly ordinary candidates")
        let recorded = Array(m.recorder.document.frames.suffix(2))
        try check(recorded.count == 2 && recorded[0].previewPNG != nil && recorded[1].previewPNG != nil &&
                  recorded[0].board == original && recorded[1].board == expected && recorded[0].previewPNG != recorded[1].previewPNG,
                  "frozen elimination before/after retains effective ordinary and user candidates")
        m.history(redo: false)
        try check(m.progress.current.board == original, "undo preserves user candidates")
        var valid = true
        try check(m.reviewHint(r.step, source: original, sourceIsCurrent: { valid }), "tool-selected proof binds its source")
        m.moveHint(3)
        let toolID = m.reading!.id
        valid = false
        m.invalidateHintSourceIfNeeded()
        valid = true
        try check(m.reading == nil && !m.applyHint(id: toolID), "restoring tool source cannot revive a stale reading")
    }

    private static func saving(_ directory: URL) throws {
        let fm = FileManager.default
        let location = directory.appendingPathComponent("HoDoKu/isolated")
        let first = model(location), stale = model(location)
        first.select(40); first.edit(5)
        stale.select(2); stale.edit(1)
        try check(first.problem == nil && stale.problem != nil, "concurrent save detects changed bytes")
        try check(model(location).progress == first.progress, "winning save remains intact")
        let damaged = directory.appendingPathComponent("damaged")
        try fm.createDirectory(at: damaged, withIntermediateDirectories: true)
        let file = NativeBoardStore(directory: damaged).file
        let unknown = Data("{\"version\":99}".utf8)
        try unknown.write(to: file)
        let blocked = model(damaged)
        blocked.select(40); blocked.edit(5)
        try blocked.prepareToQuit()
        try check(!blocked.canEdit && (try Data(contentsOf: file)) == unknown, "future version preserved")
        try Data("{".utf8).write(to: file)
        blocked.retry()
        try check(!blocked.canEdit, "bad JSON remains read protected")
        try Data(contentsOf: NativeBoardStore(directory: location).file).write(to: file)
        blocked.retry()
        try check(blocked.canEdit && blocked.progress == first.progress, "retry reopens recovered document")
        let inaccessible = directory.appendingPathComponent("unavailable")
        let m = model(inaccessible)
        try Data().write(to: inaccessible)
        m.select(40); m.edit(5)
        try check(m.problem != nil, "write failure exposed")
        do {
            try m.prepareToQuit()
            throw Failure(message: "failed save allowed quit")
        } catch is Failure { throw Failure(message: "failed save allowed quit") } catch {}
        try fm.removeItem(at: inaccessible)
        try m.prepareToQuit()
        try check(m.problem == nil && model(inaccessible).progress == m.progress, "quit retry persists unsaved edit")
    }

    private static func protectLegacy(_ support: URL) throws {
        let fm = FileManager.default
        let legacy = support.appendingPathComponent("HoDoKu")
        let native = support.appendingPathComponent("HoDoKu Native Candidate")
        let alias = support.appendingPathComponent("legacy-alias")
        let files = ["last-session.xml": Data("<saved/>".utf8), "hodoku.hcfg": Data([1, 2, 3]),
                     "history.hdkreplay": Data([0, 127, 255])]
        try fm.createDirectory(at: legacy, withIntermediateDirectories: true)
        for (name, data) in files { try data.write(to: legacy.appendingPathComponent(name)) }
        try fm.createSymbolicLink(at: alias, withDestinationURL: legacy)
        let store = NativeBoardStore(directory: native, supportRoot: support)
        var progress = try store.load()
        progress.current.board.setValue(5, at: 40)
        try store.save(progress)
        try check(try fm.contentsOfDirectory(atPath: native.path) == ["board-v3.json"], "only candidate progress created")
        for location in [legacy, legacy.appendingPathComponent("child"), alias, alias.appendingPathComponent("new/deeper")] {
            let denied = NativeBoardStore(directory: location, supportRoot: support)
            do { _ = try denied.load(); throw Failure(message: "legacy read accepted") } catch BoardFileError.unsafeLocation {}
            do { try denied.save(progress); throw Failure(message: "legacy write accepted") } catch BoardFileError.unsafeLocation {}
        }
        let redirected = native.appendingPathComponent("redirected")
        try fm.createDirectory(at: redirected, withIntermediateDirectories: true)
        let indirect = NativeBoardStore(directory: redirected, supportRoot: support)
        try fm.createSymbolicLink(at: indirect.file, withDestinationURL: legacy.appendingPathComponent("last-session.xml"))
        do { _ = try indirect.load(); throw Failure(message: "symlink file read accepted") } catch BoardFileError.unsafeLocation {}
        do { try indirect.save(progress); throw Failure(message: "symlink file write accepted") } catch BoardFileError.unsafeLocation {}
        try check(Set(try fm.contentsOfDirectory(atPath: legacy.path)) == Set(files.keys), "legacy tree membership preserved")
        for (name, data) in files {
            try check(try Data(contentsOf: legacy.appendingPathComponent(name)) == data, "legacy fixture bytes preserved")
        }
    }
}
