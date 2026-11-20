import AppKit

enum ReplayWorkbenchChecks {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func check(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try value() else { throw Failure(description: message) }
    }
    static func main() throws {
        guard let base = ProcessInfo.processInfo.environment["HODOKU_NATIVE_DATA_DIR"] else { throw BoardFileError.unsafeLocation }
        let root = URL(fileURLWithPath: base).appendingPathComponent("replay-workbench-" + UUID().uuidString)
        print("temporary replay workbench: \(root.path); remove after tests")
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let profile = root.appendingPathComponent("Native")
        try fm.createDirectory(at: profile, withIntermediateDirectories: true)
        let legacy = profile.appendingPathComponent("board-v2.json")
        var old = BoardProgress(); old.version = 2
        let oldBytes = try JSONEncoder().encode(old)
        try oldBytes.write(to: legacy)
        let model = NativeBoardModel(directory: profile, automaticTimers: false)
        let board = model.progress.current.board
        guard let step = try NativeHintEngine.next(for: board), model.reviewHint(step, source: board) else {
            throw Failure(description: "real step unavailable")
        }
        model.moveHint(100)
        guard let reading = model.reading, model.applyHint(id: reading.id) else { throw BoardFileError.invalid }
        let proof = model.recorder.document.frames[1]
        let result = model.recorder.document.frames[2]
        try check(proof.board == board && result.board != board && proof.operationID == result.operationID, "proof and result share one operation")
        try check(proof.previewPNG != nil && proof.text.contains(reading.current.text), "actual proof text and image frozen")
        model.history(redo: false)
        try check(model.progress.current.board == board && model.recorder.document.frames.last?.label == "撤销", "undo recorded")
        try model.beginReview()
        try check(!model.canEdit && model.reviewing, "read-only viewer")
        let snapshot = model.progress
        model.edit(1); model.history(redo: false)
        try check(model.progress == snapshot, "history cannot change live board")
        model.endReview()
        try check(model.recorder.document.frames[1] == proof, "historic proof immutable")
        let g = BoardGeometry(bounds: CGRect(x: 0, y: 0, width: 920, height: 920))
        let r = g.rect(2, digit: 1), p = CGPoint(x: r.midX, y: r.midY)
        model.chooseTool(.color)
        let initialCount = model.recorder.document.frames.count
        for t in [100, 180] {
            model.press(p, button: .left, modifiers: [], at: t, geometry: g)
            model.release(p, button: .left, at: t+1, geometry: g)
        }
        model.tick(500)
        try check(model.recorder.document.frames.count == initialCount && model.progress.current.marks.map(\.digit) == [1], "double replaces provisional first mark without recording annotation-only gestures")
        model.toggleFreeze()
        try check(model.recorder.document.frames.last?.previewPNG != nil, "explicit frozen frame recorded")
        model.toggleFreeze()
        try model.beginReview()
        try model.editReplayMetadata { $0.pinned = true; $0.bookmarks = [.init(name: "证明", frameIndex: 1)] }
        let priorProgress = model.progress
        let previous = model.recorder.document
        let name = "noncanonical.hrep"
        let base64 = try Data(contentsOf: URL(fileURLWithPath: "docs/replay-protocol/fixtures/m2/" + name + ".b64"))
        guard let original = Data(base64Encoded: base64, options: .ignoreUnknownCharacters) else { throw BoardFileError.invalid }
        let source = root.appendingPathComponent(name)
        try original.write(to: source)
        let imported = try NativeReplayLibrary.read(source)
        let entry = try model.replayLibrary.put(imported, named: name)
        let added = try model.replayLibrary.change(entry.id) { $0.pinned = true; $0.bookmarks.append(.init(name: "第二帧", frameIndex: 1)) }
        let loaded = try model.replayLibrary.load(added)
        try check(loaded.originalBytes == original && loaded.bookmarks.last?.frameIndex == 1 && loaded.pinned, "library metadata preserves raw payload")
        let copy = root.appendingPathComponent("另存.hrep")
        try model.replayLibrary.export(try ReplayExchange.encode(loaded), to: copy)
        try check(try Data(contentsOf: copy) == original, "noncanonical exact save-as")
        do { try model.replayLibrary.export(Data([0]), to: source); throw Failure(description: "source clobbered") }
        catch is Failure { throw Failure(description: "existing file export accepted") } catch {}
        let file = NativeBoardStore(directory: profile).file
        let current = try Data(contentsOf: file)
        let indexFile = profile.appendingPathComponent("Replays/library.json")
        let oldIndex = try Data(contentsOf: indexFile)
        try (current + Data([32])).write(to: file, options: .atomic)
        do { try model.branch(from: loaded, at: 1, archived: added); throw Failure(description: "stale progress overwrote other writer") }
        catch BoardFileError.concurrentChange {}
        try check(model.reviewing && model.progress == priorProgress && model.recorder.document == previous, "failed branch kept source and live attempt")
        try check(try Data(contentsOf: indexFile) == oldIndex, "failed branch restored exact prior library index")
        try current.write(to: file, options: .atomic)
        try model.branch(from: loaded, at: 1, archived: added)
        let branch = model.recorder.document
        try check(model.canEdit && branch.frames.count == 1 && branch.id != previous.id && branch.id != loaded.id && branch.elapsedMillis == 0, "fresh attempt identity and time")
        try check(branch.sourceReplayID == loaded.id && branch.sourceFrameIndex == 1 && branch.sourceArchiveSHA256 == entry.id, "source references")
        try check(model.progress == BoardProgress(current: BoardPage(board: loaded.frames[1].board)), "only the selected four arrays transferred")
        guard let empty = model.progress.current.board.values.firstIndex(of: 0) else { throw BoardFileError.invalid }
        model.select(empty); model.edit(1)
        try model.prepareToQuit()
        let restored = NativeBoardModel(directory: profile, automaticTimers: false)
        try check(restored.recorder.document.id == branch.id && restored.progress == model.progress && restored.progress.boardUndo.count == 1, "branch persisted after independent edit")
        try check(try Data(contentsOf: source) == original && Data(contentsOf: legacy) == oldBytes, "external original and old trial bytes preserved")
        let entries = try restored.replayLibrary.entries()
        let docs = try entries.map(restored.replayLibrary.load)
        try check(docs.contains(where: { $0.id == previous.id && $0.endedAt > 0 && $0.frames == previous.frames && $0.bookmarks == previous.bookmarks }) && docs.contains(loaded), "outgoing active attempt, bookmarks and imported source still readable")
        for fixture in ["core-v3", "m2/windows-m2-export", "m2/preview-carrier", "m2/unknown-important"] {
            let url = URL(fileURLWithPath: "docs/replay-protocol/fixtures/" + fixture + ".hrep.b64")
            guard let raw = Data(base64Encoded: try Data(contentsOf: url), options: .ignoreUnknownCharacters) else {
                throw BoardFileError.invalid
            }
            let replay = try NativeReplayLibrary.decode(raw)
            let row = try restored.replayLibrary.put(replay, named: fixture)
            let fromShelf = try restored.replayLibrary.load(row)
            try check(fromShelf.originalBytes == raw, "fixture bytes " + fixture)
            let i = fromShelf.frames.count - 1
            let chosen = fromShelf.frames[i]
            try restored.beginReview()
            try restored.branch(from: fromShelf, at: i, archived: row)
            try check(restored.progress.current.board == chosen.board && restored.progress.boardUndo.isEmpty && restored.reading == nil &&
                      restored.recorder.document.frames.count == 1 && restored.recorder.document.sourceArchiveSHA256 == row.id,
                      "independent editable position " + fixture)
            if fromShelf.format != .javaV3 { try check(restored.progress.current == BoardPage(board: chosen.board), "FRAME imports only the board") }
            try check(try restored.replayLibrary.load(row).originalBytes == raw, "immutable origin " + fixture)
        }
        print("PASS replay workbench: actual Rust proof, commit arbitration, freeze, scoped metadata, read-only viewer, exact import/export, failed/successful branch and separate restart")
    }

}
