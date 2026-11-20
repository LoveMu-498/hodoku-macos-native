// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

struct LegacySessionSavePoint: Codable, Equatable {
    var name: String?
    var date: Date?
    var progress: BoardProgress
}

struct LegacySessionContext: Codable, Equatable {
    var activeCell: Int?
    var completed: Bool
    var completedLevel: Int
    var completedGameMode: String
    var replayId: String
    var replayFrameCount: Int
    var replayElapsedMillis: Int64
    var name: String?
    var savePoints: [LegacySessionSavePoint]
    var historyEligible: Bool
    var completionRecorded: Bool
    var previouslySolved: Bool
    var levelOrdinal: Int? { (1...5).contains(completedLevel) ? completedLevel : nil }
    var gameMode: String? { ["PLAYING","LEARNING","PRACTISING"].contains(completedGameMode) ? completedGameMode : nil }
}

struct LegacyImportedGame {
    let progress: BoardProgress
    let context: LegacySessionContext
    let sourceURL: URL
    let recoveredBackup: Bool
    let sourceBytes: Data
}

enum LegacySessionReader {
    static func read(_ url: URL) throws -> LegacyImportedGame {
        do { return try decodeFile(url, backup: false) }
        catch {
            let backup = url.appendingPathExtension("bak")
            guard url.pathExtension.lowercased() != "bak", FileManager.default.fileExists(atPath: backup.path) else { throw error }
            return try decodeFile(backup, backup: true)
        }
    }

    private static func decodeFile(_ url: URL, backup: Bool) throws -> LegacyImportedGame {
        let info = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard info.isRegularFile == true, let size = info.fileSize, (1...(256*1024*1024)).contains(size)
        else { throw LegacySessionError.invalid("会话文件为空、过大或不可读。") }
        let bytes = try Data(contentsOf: url)
        let objects = try LegacySessionXML.objects(bytes)
        guard objects.count == 1, let session = objects.first, session.className == "sudoku.SessionSnapshot",
              (1...2).contains(try session.number("formatVersion", 1)), let gui = session["guiState"] else {
            throw LegacySessionError.invalid("会话版本或根对象不受支持。")
        }
        let row = try session.number("activeRow", 4), col = try session.number("activeCol", 4)
        guard (row == -1 && col == -1) || ((0..<9).contains(row) && (0..<9).contains(col)) else {
            throw LegacySessionError.invalid("活动格超出棋盘。")
        }
        let saved = try (session["savePoints"]?.elements ?? []).compactMap { point -> LegacySessionSavePoint? in
            if point.className == "null" { return nil }
            let stamp = try point["timestamp"]?.arguments.first?.int()
            return LegacySessionSavePoint(name: point["name"]?.scalar, date: stamp.map { Date(timeIntervalSince1970: Double($0)/1000) },
                                          progress: try progress(point))
        }
        let context = try LegacySessionContext(activeCell: row < 0 ? nil : row*9+col, completed: session.flag("completed"),
            completedLevel: session.number("completedLevel"), completedGameMode: session["completedGameMode"]?.scalar ?? "PLAYING",
            replayId: session["replayId"]?.scalar ?? "", replayFrameCount: session.number("replayFrameCount"),
            replayElapsedMillis: Int64(session.number("replayElapsedMillis")), name: gui["name"]?.scalar, savePoints: saved,
            historyEligible: session.flag("historyEligible"), completionRecorded: session.flag("completionRecorded"),
            previouslySolved: session.flag("previouslySolved"))
        return LegacyImportedGame(progress: try progress(gui), context: context, sourceURL: url, recoveredBackup: backup, sourceBytes: bytes)
    }

    static func board(_ bean: LegacyBean) throws -> NativeBoardSnapshot {
        guard bean.className == "sudoku.Sudoku2" else { throw LegacySessionError.invalid("盘面类型不受支持。") }
        func array(_ key: String, fill: Int, max: Int) throws -> [Int] {
            let values = try bean[key]?.integers(count: 81, default: fill) ?? Array(repeating: fill, count: 81)
            guard values.allSatisfy((0...max).contains) else { throw LegacySessionError.invalid("盘面字段 \(key) 超界。") }
            return values
        }
        let result = try NativeBoardSnapshot(values: array("values", fill:0, max:9).map(UInt8.init),
                    fixed: array("fixed", fill:0, max:1).map { $0 != 0 },
                    candidates: array("cells", fill:511, max:511).map(UInt16.init),
                    userCandidates: array("userCells", fill:0, max:511).map(UInt16.init))
        try result.validate()
        return result
    }

    static func progress(_ gui: LegacyBean) throws -> BoardProgress {
        guard gui.className == "sudoku.GuiState", let sudoku = gui["sudoku"] else {
            throw LegacySessionError.invalid("会话中缺少棋盘。")
        }
        var result = BoardProgress()
        result.current.board = try board(sudoku)
        if let level = sudoku["level"], level.className == "sudoku.DifficultyLevel" {
            var context = NativeGameContext()
            if let ordinal = level["ordinal"] { context.difficulty = try ordinal.int() }
            else if let type = level["type"]?.scalar { context.difficulty = NativePuzzleHSOL.difficulties.firstIndex(of: type) }
            if context.difficulty != nil { context.score = try sudoku.number("score"); result.extra = context }
        }
        result.boardUndo = try (gui["undoStack"]?.elements ?? []).map(board)
        result.boardRedo = try (gui["redoStack"]?.elements ?? []).map(board)
        func marks(_ cells: LegacyBean?, _ candidates: LegacyBean?) throws -> [BoardMark] {
            var marks: [BoardMark] = []
            for (map, candidate) in [(cells,false),(candidates,true)] {
                for (key, color) in map?.entries ?? [] {
                    let n = try key.int()
                    guard candidate ? ReplayJavaAnnotations.validAtom(n) : (0..<81).contains(n) else {
                        throw LegacySessionError.invalid("着色格或候选无效。")
                    }
                    let rgb = try LegacySessionInk.rgb(color)
                    marks.append(BoardMark(cell: candidate ? n/10 : n, digit: candidate ? n%10 : 0,
                                           color: ReplayJavaAnnotations.group(rgb), light: ReplayJavaAnnotations.light(rgb)))
                }
            }
            return marks
        }
        result.current.marks = try marks(gui["coloringMap"], gui["coloringCandidateMap"])
        guard try gui.flag("includeAnnotations") else { try result.validate(); return result }
        func markHistory(_ way: String) throws -> [[BoardMark]] {
            try zip(gui["coloring" + way + "Cells"]?.elements ?? [], gui["coloring" + way + "Candidates"]?.elements ?? []).map(marks)
        }
        result.markUndo = try markHistory("Undo"); result.markRedo = try markHistory("Redo")
        func boxes(_ bean: LegacyBean?) throws -> BoxToolState {
            var result = BoxToolState()
            for (i, set) in (bean?.elements ?? []).enumerated() {
                guard i < 6, set.className == "sudoku.SudokuSet" else { throw LegacySessionError.invalid("选框色组无效。") }
                let low = UInt64(bitPattern: Int64(try set.number("mask1")))
                let high = UInt64(bitPattern: Int64(try set.number("mask2")))
                result.groups[i] = Set((0..<81).filter { $0 < 64 ? low & (1 << $0) != 0 : high & (1 << ($0-64)) != 0 })
            }
            return result
        }
        result.current.boxes = try boxes(gui["boxReasoningGroups"])
        result.boxHistory.undo = try (gui["boxReasoningUndoHistory"]?.elements ?? []).map(boxes)
        result.boxHistory.redo = try (gui["boxReasoningRedoHistory"]?.elements ?? []).map(boxes)
        result.current.ink = try LegacySessionInk.state(gui["doodleStrokes"]?.elements ?? [], mask: gui.number("doodleHypothesisConsumedMask"), restoringCurrent: true)
        func inkHistory(_ way: String) throws -> [InkToolState] {
            let masks = try (gui["doodleHypothesis" + way + "Masks"]?.elements ?? []).map { try $0.int() }
            return try (gui["doodle" + way + "History"]?.elements ?? []).enumerated().map { i, strokes in
                try LegacySessionInk.state(strokes.elements, mask: masks.indices.contains(i) ? masks[i] : 63)
            }
        }
        result.inkHistory.undo = try inkHistory("Undo"); result.inkHistory.redo = try inkHistory("Redo")
        result.current.chains = try chains(gui["userChains"])
        func chainHistory(_ key: String) throws -> [ChainToolState] {
            var history = [ChainToolState]()
            for layer in gui[key]?.elements ?? [] {
                let state = try chains(layer)
                if history.last != state { history.append(state) }
            }
            return history
        }
        result.chainHistory.undo = try chainHistory("userChainUndoHistory")
        result.chainHistory.redo = try chainHistory("userChainRedoHistory")
        try result.validate()
        return result
    }

    private static func chains(_ bean: LegacyBean?) throws -> ChainToolState {
        var state = ChainToolState()
        for chain in bean?.elements ?? [] {
            guard chain.className == "sudoku.UserChain" else { throw LegacySessionError.invalid("自由链无效。") }
            if try chain.flag("active") { continue }
            var nodes: [ChainToolNode] = []
            for node in chain["nodes"]?.elements ?? [] {
                let digit = try node.number("candidate")
                let cells = try node["groupCells"]?.integers() ?? [node.number("cellIndex")]
                let atoms: [Int]
                if let members = node["memberCandidates"], members.className != "null" { atoms = try members.integers() }
                else {
                    guard cells.allSatisfy((0..<81).contains), (1...9).contains(digit) else { throw BoardFileError.invalid }
                    atoms = cells.map { $0*10+digit }
                }
                nodes.append(.init(atoms:atoms.sorted(), color: ReplayJavaAnnotations.group(try LegacySessionInk.rgb(node["color"]))))
            }
            let colors = chain["relationColors"]?.elements ?? []
            let edges = try (chain["strongRelations"]?.elements ?? []).enumerated().map { i, flag in
                try ChainToolEdge(strong: flag.bool(), color: ReplayJavaAnnotations.group(LegacySessionInk.rgb(colors.indices.contains(i) ? colors[i] : nil)))
            }
            if !nodes.isEmpty { state.paths.append(ChainToolPath(nodes:nodes, edges:edges, closed:try chain.flag("closed"))) }
        }
        try state.validate()
        return state
    }
}
