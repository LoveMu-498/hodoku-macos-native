// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import HodokuEngine

/// Private source copy for titles, solution paths and savepoints. Export builds a fresh,
/// data-only description. No Java expressions from this archive are copied into the writer.
struct NativePuzzleArchive: Codable, Equatable {
    let original: Data
}

enum NativePuzzleHSOL {
    static let difficulties = ["INCOMPLETE", "EASY", "MEDIUM", "HARD", "UNFAIR", "EXTREME"]
    private static let lists = ["java.util.ArrayList", "java.util.LinkedList", "java.util.Vector", "java.util.Stack"]
    private static func parts(_ data: Data) throws -> (LegacyBean, [LegacyBean]) {
        let values = try LegacySessionXML.objects(NativePuzzleZip.xml(data))
        guard let first = values.first else { throw NativePuzzleError.archive }
        let offset = first.className == "sudoku.Sudoku" ? 2 : 1
        guard (offset == 1 && first.className == "sudoku.Sudoku2") || (offset == 2 && values.count > 1 && values[1].className == "sudoku.Sudoku"),
              [offset+4, offset+5].contains(values.count), values[offset].className == "int[]",
              values[(offset+1)...].allSatisfy({ lists.contains($0.className) }) else { throw NativePuzzleError.archive }
        return (first, Array(values.dropFirst(offset)))
    }

    static func read(_ data: Data) throws -> BoardProgress {
        let (bean, tail) = try parts(data)
        let board = try bean.className == "sudoku.Sudoku" ? oldBoard(bean) : LegacySessionReader.board(bean)
        var context = NativeGameContext()
        context.puzzleArchive = NativePuzzleArchive(original: data)
        if tail.count == 5 {
            context.savePoints = try tail[4].elements.compactMap { try savedPoint($0) }
        }
        if let type = bean["level"]?["type"]?.scalar { context.difficulty = difficulties.firstIndex(of: type) }
        else if let level = try bean["level"]?["ordinal"]?.int(), difficulties.indices.contains(level) { context.difficulty = level }
        if bean.className == "sudoku.Sudoku2" { context.score = try bean.number("score") }
        var game = BoardProgress(current: BoardPage(board: board))
        game.extra = context
        return game
    }

    private static func oldBoard(_ bean: LegacyBean) throws -> NativeBoardSnapshot {
        guard let cells = bean["cells"], cells.length == nil || cells.length == 81,
              cells.indexed.keys.allSatisfy((0..<81).contains) else { throw NativePuzzleError.archive }
        var grid = "", deletions = [String]()
        for i in 0..<81 {
            let cell = cells.indexed[i] ?? LegacyBean("default")
            guard cell.className == "sudoku.SudokuCell" || cell.className == "default" else { throw NativePuzzleError.archive }
            let value = try cell.number("value")
            guard (0...9).contains(value) else { throw NativePuzzleError.archive }
            let fixed = try cell.flag("isFixed")
            grid += value == 0 ? "." : (fixed ? "" : "+") + String(value)
            if value != 0 { continue }
            let masks = try cell["candidates"]?.integers(count: 3) ?? [0, 0, 0]
            guard masks.allSatisfy((0...511).contains) else { throw NativePuzzleError.archive }
            for d in 1...9 where masks[2] & ~masks[1] & Int(NativeBoardSnapshot.bit(UInt8(d))) != 0 {
                deletions.append("\(d)\(i/9+1)\(i%9+1)")
            }
        }
        return try NativePuzzleFiles.readText(":0000:x:" + grid + ":" + deletions.joined(separator: " ") + "::").current.board
    }

    static func validation(_ values: [UInt8], _ masks: [UInt16]?) -> (String, [UInt8]?) {
        if !values.contains(where: { $0 != 0 }) { return ("EMPTY", nil) }
        var result = HodokuCountResult()
        let rc: Int32
        if let masks = masks {
            rc = hodoku_count_solutions_v1(values, 81, masks, 81, 1, Int32(HODOKU_DEFAULT_MAX_TRIES), nil, &result)
        } else { rc = hodoku_count_solutions_v1(values, 81, nil, 0, 1, Int32(HODOKU_DEFAULT_MAX_TRIES), nil, &result) }
        if rc != 0 { return (rc == 1 ? "INVALID" : "UNKNOWN", nil) }
        if result.count > 1 { return ("MULTIPLE_SOLUTIONS", nil) }
        if result.termination != HODOKU_EXHAUSTED { return ("UNKNOWN", nil) }
        if result.count == 0 { return ("INVALID", nil) }
        return ("VALID", withUnsafeBytes(of: result.solution) { Array($0) })
    }

    private static func savedPoint(_ bean: LegacyBean) throws -> NativeGameSavePoint? {
        guard bean.className != "null" else { return nil }
        let progress = try LegacySessionReader.progress(bean)
        // Untitled or undated historical records remain in the source archive for lossless re-export.
        guard let name = bean["name"]?.scalar, let stamp = try bean["timestamp"]?.arguments.first?.int() else { return nil }
        return NativeGameSavePoint(name: name, date: Date(timeIntervalSince1970: Double(stamp)/1000), progress: progress)
    }

    private static func boardXML(_ board: NativeBoardSnapshot, context: NativeGameContext?, old: LegacyBean?,
                                 encoder: NativePuzzleBeanWriter) throws -> String {
        if let old = old, old.className == "sudoku.Sudoku2", try LegacySessionReader.board(old) == board {
            return try encoder.value(old)
        }
        let validation = Self.validation(board.values, board.candidates)
        let givens = zip(board.fixed, board.values).map { $0 ? $1 : 0 }
        let givenStatus = Self.validation(givens, nil).0
        func property(_ name: String, _ value: String) -> String { "<void property=\"\(name)\">\(value)</void>" }
        func array<T>(_ type: String, _ values: [T]) -> String {
            let cells = values.enumerated().map { "<void index=\"\($0.offset)\"><\(type)>\($0.element)</\(type)></void>" }
            return "<array class=\"\(type)\" length=\"\(values.count)\">" + cells.joined() + "</array>"
        }
        func enumValue(_ type: String, _ name: String) -> String {
            "<object class=\"java.lang.Enum\" method=\"valueOf\"><class>sudoku.\(type)</class><string>\(name)</string></object>"
        }
        var content = "<object class=\"sudoku.Sudoku2\">" + property("values", array("int", board.values))
            + property("fixed", array("boolean", board.fixed)) + property("cells", array("short", board.candidates))
            + property("userCells", array("short", board.userCandidates))
            + property("unsolvedCellsAnz", "<int>\(board.values.filter { $0 == 0 }.count)</int>")
            + property("status", enumValue("SudokuStatus", validation.0)) + property("statusGivens", enumValue("SudokuStatus", givenStatus))
        if let solution = validation.1 {
            content += property("solution", array("int", solution)) + property("solutionSet", "<boolean>true</boolean>")
        }
        let clues = givens.map { $0 == 0 ? "." : String($0) }.joined()
        content += property("initialState", "<string>:0000:x:\(clues):::</string>")
        if let score = context?.score { content += property("score", "<int>\(score)</int>") }
        if let oldLevel = old?["level"] { content += property("level", try encoder.value(oldLevel)) }
        else if let level = context?.difficulty, difficulties.indices.contains(level) {
            content += property("level", "<object class=\"sudoku.DifficultyLevel\">" + property("type", enumValue("DifficultyType", difficulties[level])) + "</object>")
        }
        return content + "</object>"
    }

    private static let emptyList = "<object class=\"java.util.ArrayList\"/>"
    private static func collection(_ elements: [String], type: String = "java.util.ArrayList") -> String {
        "<object class=\"\(type)\">" + elements.map { "<void method=\"add\">" + $0 + "</void>" }.joined() + "</object>"
    }

    private static func pointXML(_ point: NativeGameSavePoint, encoder: NativePuzzleBeanWriter) throws -> String {
        let p = point.progress
        var remainder = p
        remainder.extra = nil
        remainder.boardUndo = []; remainder.boardRedo = []
        remainder.current.board = .example
        guard remainder == BoardProgress() else { throw NativePuzzleError.metadata }
        func property(_ key: String, _ xml: String) -> String { "<void property=\"\(key)\">" + xml + "</void>" }
        let name = try encoder.value(LegacyBean("string", point.name))
        let millis = point.date.timeIntervalSince1970 * 1000
        guard millis.isFinite && abs(millis) < Double(Int64.max) else { throw NativePuzzleError.metadata }
        let date = "<object class=\"java.util.Date\"><long>\(Int64(millis.rounded()))</long></object>"
        let board = try boardXML(p.current.board, context: p.extra, old: nil, encoder: encoder)
        func stack(_ boards: [NativeBoardSnapshot]) throws -> String {
            try collection(boards.map { try boardXML($0, context: p.extra, old: nil, encoder: encoder) }, type: "java.util.Stack")
        }
        let fields = [property("name", name), property("timestamp", date), property("sudoku",board),
                      try property("undoStack", stack(p.boardUndo)), try property("redoStack", stack(p.boardRedo)),
                      property("titels", collection(["<string>1</string>"])), property("tabSteps", collection([emptyList])),
                      property("steps",emptyList), property("anzSteps","<array class=\"int\" length=\"0\"/>")]
        return "<object class=\"sudoku.GuiState\">" + fields.joined() + "</object>"
    }

    static func encode(_ game: BoardProgress) throws -> Data {
        let prior = try game.extra?.puzzleArchive.map { try parts($0.original) }
        let encoder = NativePuzzleBeanWriter()
        var content = try boardXML(game.current.board, context: game.extra, old: prior?.0, encoder: encoder)
        if let (_, tail) = prior {
            for bean in tail.prefix(4) { content += try encoder.value(bean) }
        } else {
            content += "<array class=\"int\" length=\"0\"/>" + emptyList + collection(["<string>1</string>"]) + collection([emptyList])
        }
        var pending = game.extra?.savePoints ?? []
        var points = [String]()
        if let (_, tail) = prior, tail.count == 5 {
            for bean in tail[4].elements {
                guard let imported = try savedPoint(bean) else { points.append(try encoder.value(bean)); continue }
                if let i = pending.firstIndex(of: imported) {
                    points.append(try encoder.value(bean))
                    pending.remove(at: i)
                }
            }
        }
        for point in pending { points.append(try pointXML(point, encoder: encoder)) }
        content += collection(points)
        return try NativePuzzleZip.pack(Data(("<?xml version=\"1.0\" encoding=\"UTF-8\"?><java class=\"java.beans.XMLDecoder\">" + content + "</java>").utf8))
    }
}
