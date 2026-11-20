import AppKit
import Foundation

#if !COMBINED_BOARD_CHECKS
    @main
#endif
enum ToolChecks {
    struct Failure: Error { let message: String }
    static func require(_ ok: Bool, _ message: String) throws {
        if !ok { throw Failure(message: message) }
    }
    static let geometry = BoardGeometry(bounds: CGRect(x: 0, y: 0, width: 470, height: 470))
    static func point(_ cell: Int, _ digit: Int = 0) -> CGPoint {
        let rect = geometry.rect(cell, digit: digit)
        return CGPoint(x: rect.midX, y: rect.midY)
    }

    static func main() throws {
        let fm = FileManager.default
        guard let base = ProcessInfo.processInfo.environment["HODOKU_NATIVE_DATA_DIR"] else {
            throw Failure(message: "Set HODOKU_NATIVE_DATA_DIR to an isolated test directory")
        }
        let root = URL(fileURLWithPath: base).appendingPathComponent("tool-tests-" + UUID().uuidString)
        print("Owned temporary fixtures: \(root.path), removed at exit")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        try inkCuts()
        try liveInkWidth(root.appendingPathComponent("live-ink"))
        try drawingOrder()
        try migration(root)
        try tools(root.appendingPathComponent("native"))
        try heldKeys(root.appendingPathComponent("held-keys"))
        try quietAnnotations(root.appendingPathComponent("quiet-annotations"))
        print("PASS native annotation transactions, independently saved histories and migration")
    }

    static func quietAnnotations(_ dir: URL) throws {
        let model = NativeBoardModel(directory: dir, automaticTimers: false, doubleClickMillis: 200)
        var sounds: [NativeOperationSound] = []
        model.didPlayOperationSound = { sounds.append($0) }
        model.mouseOptions.operationSoundsEnabled = true
        for tool in [BoardTool.color, .ink, .chain, .boxes] {
            model.chooseTool(tool)
            for (i, p) in [point(2, 1), point(3, 2)].enumerated() {
                let time = 1000 + i * 500
                let before = model.progress.current
                model.press(p, button: .left, modifiers: [], at: time, geometry: geometry)
                model.release(p, button: .left, at: time + 5, geometry: geometry)
                model.tick(time + 220)
                try require(model.progress.current != before, "valid \(tool) pointer edit")
            }
            try require(sounds.isEmpty, "\(tool) creation is silent")
            if tool == .boxes {
                for time in [2000, 2120] {
                    model.toolKey(.boxes, down: true, now: time)
                    model.toolKey(.boxes, down: false, now: time + 20)
                }
            } else {
                model.clearAnnotations(all: tool == .color)
            }
            model.clearAnnotations(all: false)
            try require(sounds == [.eraseInkBatch], "\(tool) bulk clearing plays once and empty clearing is silent")
            sounds.removeAll()
        }
    }

    static func drawingOrder() throws {
        var order = AnnotationTimeline()
        var page = BoardPage()
        let proof = UUID()
        let key = AnnotationObject.mark(1, 0)
        page.marks = [BoardMark(cell: 1, digit: 0, color: 0)]
        order.observe(page, proof: proof)
        try require(order.later.isEmpty, "existing marks predate a proof")
        page.marks[0].color = 2
        order.observe(page, proof: proof)
        try require(order.later == [key], "recolor above current proof")
        page.marks.removeAll()
        order.observe(page, proof: proof)
        try require(order.later.isEmpty, "erased source dropped from timeline")
        page.marks = [BoardMark(cell: 1, digit: 0, color: 0)]
        order.observe(page, proof: proof)
        try require(order.later == [key], "new mark can reuse the same position")
        order.observe(page, proof: UUID())
        try require(order.later.isEmpty, "new proof starts a fresh timeline")
    }

    static func heldKeys(_ dir: URL) throws {
        let m = NativeBoardModel(directory: dir, automaticTimers: false, doubleClickMillis: 200)
        let first = point(2, 1)
        let last = point(3, 2)
        m.chooseTool(.ink)
        for (i, p) in [first, last].enumerated() {
            m.chooseColor(i)
            m.press(p, button: .left, modifiers: [], at: i * 500, geometry: geometry)
            m.release(p, button: .left, at: i * 500 + 5, geometry: geometry)
            m.tick(i * 500 + 205)
        }
        m.holdPalette(0, down: true)
        var sounds: [NativeOperationSound] = []
        m.didPlayOperationSound = { sounds.append($0) }
        m.mouseOptions.operationSoundsEnabled = true
        let a = CGPoint(x: min(first.x, last.x) - 18, y: min(first.y, last.y) - 18)
        let b = CGPoint(x: max(first.x, last.x) + 18, y: max(first.y, last.y) + 18)
        m.press(a, button: .left, modifiers: .control, at: 1400, geometry: geometry)
        m.holdPalette(0, down: false)
        m.move(b, geometry: geometry)
        try require(
            m.progress.current.ink.strokes.count == 2 && m.frame.erasedInk?.strokes.count == 1,
            "live erase predicts locked group")
        try require(sounds.isEmpty, "eraser previews stay silent")
        m.release(b, button: .left, at: 1410, geometry: geometry)
        try require(m.progress.current.ink.strokes.map(\.group) == [1], "releasing A mid-drag preserves filter")
        try require(sounds == [.eraseInkBatch], "committed rectangle gives one batch cue")
        m.history(redo: false)
        m.press(first, button: .right, modifiers: [], at: 1500, geometry: geometry)
        m.release(first, button: .right, at: 1510, geometry: geometry)
        m.tick(1730)
        try require(m.progress.current.ink.strokes.map(\.group) == [1] && sounds == [.eraseInkBatch, .eraseInk],
                    "single erasure gives the short cue")
        m.press(a, button: .right, modifiers: [], at: 1750, geometry: geometry)
        m.release(a, button: .right, at: 1760, geometry: geometry)
        m.tick(1980)
        try require(sounds == [.eraseInkBatch, .eraseInk], "empty erasure stays silent")
        try require(NativeOperationSound.eraseInk.fileURL == NativeOperationSound.eraseInkBatch.fileURL &&
                    NativeOperationSound.eraseInkBatch.volume > NativeOperationSound.eraseInk.volume &&
                    NativeOperationSound.eraseInk.followupDelay == nil && NativeOperationSound.eraseInkBatch.followupDelay != nil,
                    "batch erasure repeats the same sample at a stronger level")
        m.history(redo: false)
        m.setPreview("option", down: true)
        m.setPreview("middle", down: true)
        m.setPreview("option", down: false)
        try require(m.frame.previewTool == .ink, "paired preview sources")
        let original = m.progress
        m.press(first, button: .left, modifiers: [], at: 2100, geometry: geometry)
        m.release(first, button: .left, at: 2110, geometry: geometry)
        try require(m.progress == original, "preview does not author")
        m.setPreview("middle", down: false)
        m.toolKey(.boxes, down: true, now: 3000)
        m.toolKey(.boxes, down: false, now: 3390)
        try require(m.tool == .ink, "long tool key returns to previous tool")
        m.toolKey(.boxes, down: true, now: 4000)
        m.toolKey(.boxes, down: false, now: 4010)
        m.toolKey(.boxes, down: true, now: 4500)
        m.toolKey(.boxes, down: false, now: 4510)
        try require(m.tool == .ink, "second settled short press returns to original tool")
        m.focus(false, now: 5000)
        try require(m.frame.previewTool == nil, "focus clears transient tools")
    }
    static func inkCuts() throws {
        let grid = BoardGeometry(bounds: CGRect(x: -10, y: -10, width: 120, height: 120))
        let eraser = BoardDrag(points: [CGPoint(x: 40, y: 20), CGPoint(x: 60, y: 80)], rectangle: true, radius: 0)
        var ink = InkToolState()
        ink.strokes = [
            InkStroke(kind: .line, group: 0, width: 0, points: [CGPoint(x: 0.1, y: 0.1), CGPoint(x: 0.9, y: 0.9)])
        ]
        var rows: [String] = []
        for whole in [false, true] {
            let clipped = ink.erased(eraser, group: nil, whole: whole, geometry: grid)
            for (kind, side) in [("retained", clipped.kept), ("removed", clipped.removed)] {
                for stroke in side.strokes {
                    let a = stroke.points.first!.x
                    let b = stroke.points.last!.x
                    rows.append(
                        "\(whole) \(kind) "
                            + String(
                                format: "%.6f %.6f", locale: Locale(identifier: "en_US_POSIX"), Double(a), Double(b)))
                }
            }
        }
        let gold = try String(contentsOfFile: "native/board/verification/ink-java.tsv", encoding: .utf8)
        try require(rows.joined(separator: "\n") + "\n" == gold, "Java erasure cut endpoints and whole-stroke source")
        let untouched = ink.erased(eraser, group: 1, whole: true, geometry: grid)
        try require(untouched.kept == ink && untouched.removed.strokes.isEmpty, "erase filter at gesture start")
    }

    static func liveInkWidth(_ dir: URL) throws {
        let m = NativeBoardModel(directory: dir, automaticTimers: false, doubleClickMillis: 200)
        m.chooseTool(.ink)
        m.chooseWidth(0)
        var sounds: [NativeOperationSound] = []
        m.didPlayOperationSound = { sounds.append($0) }
        m.mouseOptions.operationSoundsEnabled = true
        let start = point(22, 1)
        let end = point(23, 9)
        for (index, modifiers) in [BoardModifiers(), .shift].enumerated() {
            m.press(start, button: .left, modifiers: modifiers, at: index * 500, geometry: geometry)
            for sample in 1...64 {
                let t = CGFloat(sample) / 65
                m.move(CGPoint(x: start.x + (end.x - start.x) * t,
                               y: start.y + (end.y - start.y) * t + 8 * sin(t * .pi)), geometry: geometry)
            }
            m.release(end, button: .left, at: index * 500 + 10, geometry: geometry)
        }
        let freehand = m.progress.current.ink.strokes
        try require(freehand.map(\.kind) == [.line, .ellipse] && sounds.isEmpty, "drawing free ink gives visual feedback alone")
        try require(freehand[0].points.count > 60 && freehand[0].points.last == geometry.normalized(end) &&
                    freehand[1].points.count == 2, "dense trace samples and release point are committed")
        let marks: [(CGPoint, BoardModifiers)] = [(point(2, 1), []), (point(2, 2), []), (point(2, 4), .shift)]
        for (i, (p, modifiers)) in marks.enumerated() {
            let at = 1000 + i * 500
            m.press(p, button: .left, modifiers: modifiers, at: at, geometry: geometry)
            m.release(p, button: .left, at: at + 5, geometry: geometry)
            m.tick(at + 210)
        }
        let authored = m.progress.current.ink.strokes
        try require(authored.map(\.kind) == [.line, .ellipse, .circle, .circle, .cross], "two circles and one cross authored")
        let historyCount = m.progress.inkHistory.undo.count
        m.chooseWidth(3)
        let thick = m.progress.current.ink.strokes
        try require(Array(thick.prefix(2)) == freehand && thick.count == authored.count,
                    "live resize preserves the drawn freehand ink and all mark positions")
        try require(thick.suffix(3).allSatisfy { $0.width > authored.last!.width }, "all existing circles and crosses resize")
        try require(m.frame.page.ink.strokes.filter { $0.cell != nil }.allSatisfy { $0.width == thick.last!.width },
                    "the live board and its reasoning overlays use the chosen width")
        try require(m.progress.inkHistory.undo.count == historyCount, "pen width does not add an undo step")
        m.history(redo: false)
        try require(m.progress.current.ink.strokes == Array(thick.dropLast()), "undo keeps the chosen width")
        m.history(redo: true)
        let saved = try NativeBoardStore(directory: dir).load()
        try require(saved.current.ink.strokes == thick, "redo and saved marks keep the chosen width")
    }

    static func migration(_ dir: URL) throws {
        let before = NativeBoardSnapshot.example
        let rawBoard = try JSONSerialization.jsonObject(with: JSONEncoder().encode(before))
        let oldMark = ["cell": 2, "digit": 1, "color": 0]
        let old: [String: Any] = [
            "version": 1, "current": ["board": rawBoard, "marks": [oldMark]],
            "boardUndo": [rawBoard], "boardRedo": [], "markUndo": [[]], "markRedo": [[oldMark]],
        ]
        let oldURL = dir.appendingPathComponent("board-v1.json")
        let data = try JSONSerialization.data(withJSONObject: old)
        try data.write(to: oldURL)
        let store = NativeBoardStore(directory: dir)
        let new = try store.load()
        try require(
            new.version == 3 && new.current.marks[0].color == 3 && new.markRedo[0] == new.current.marks,
            "old teal history")
        try require(
            new.boardUndo == [before] && !FileManager.default.fileExists(atPath: store.file.path), "read-only import")
        try store.save(new)
        let restored = try NativeBoardStore(directory: dir).load()
        try require(try Data(contentsOf: oldURL) == data && restored == new, "separate old and new progress")
    }

    static func tools(_ dir: URL) throws {
        let m = NativeBoardModel(directory: dir, automaticTimers: false, doubleClickMillis: 200)
        let original = m.progress.current.board
        var clock = 100
        func click(_ p: CGPoint, flags: BoardModifiers = [], button: BoardButton = .left, after: Int = 300) {
            clock += after
            m.press(p, button: button, modifiers: flags, at: clock, geometry: geometry)
            m.release(p, button: button, at: clock + 1, geometry: geometry)
        }
        func draw(_ a: CGPoint, _ b: CGPoint, flags: BoardModifiers = [], button: BoardButton = .left) {
            clock += 300
            m.press(a, button: button, modifiers: flags, at: clock, geometry: geometry)
            m.move(b, geometry: geometry)
            m.release(b, button: button, at: clock + 10, geometry: geometry)
        }
        let a = point(2, 1)
        let b = point(3, 2)
        m.chooseTool(.ink)
        click(a)
        click(a, after: 100)
        try require(m.progress.current.ink.strokes.map(\.kind) == [.cross], "double replaces first circle")
        click(a)
        try require(m.progress.current.ink.strokes.count == 2, "circle and cross may coexist")
        m.chooseColor(2)
        draw(point(9), point(29))
        let beforeUndo = m.progress.current.ink
        m.history(redo: false)
        try require(m.progress.current.ink.strokes.count == 2, "single drag undo")
        m.history(redo: true)
        try require(m.progress.current.ink == beforeUndo, "redo full stroke")
        m.chooseTool(.boxes)
        draw(point(3), point(13))
        let boxes = m.progress.current.boxes
        try require(boxes.footprint.contains(3) && boxes.footprint.contains(13), "S drag membership")
        m.chooseTool(.chain)
        click(a)
        click(b)
        let chain = m.progress.current.chains
        try require(chain.hasConnected(21), "L adds an edge")
        m.history(redo: false)
        try require(
            !m.progress.current.chains.hasConnected(21) && m.progress.current.boxes == boxes, "independent L undo")
        m.history(redo: true)
        m.chooseTool(.ink)
        try require(
            m.progress.current.ink == beforeUndo && m.progress.current.board == original,
            "tools preserve board and other layers")
        m.toggleFreeze()
        let frozen = try BoardPainter.png(m.frame, size: 360)
        click(a)
        try require(try BoardPainter.png(m.frame, size: 360) == frozen, "frozen annotation image immutable")
        m.toggleFreeze()
        try m.prepareToQuit()
        let restored = try NativeBoardStore(directory: dir).load()
        try require(restored == m.progress, "all annotation layers and histories round-trip")
    }
}
