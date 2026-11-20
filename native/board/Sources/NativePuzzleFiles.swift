// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

enum NativePuzzleError: LocalizedError {
    case file, grid, history, archive, projection, metadata
    var errorDescription: String? {
        switch self {
        case .file: return "请选择有效的 HSOL、TXT 或 SS 题目文件。"
        case .grid: return "无法辨认完整的 81 格题面、候选或落子记录。"
        case .history: return "题目历史记录无效。"
        case .archive: return "题目压缩包中的 SudokuData 已损坏或不受支持。"
        case .projection: return "所选格式无法完整表示这组普通候选。请使用 HSOL 格式。"
        case .metadata: return "此题目含暂时无法导出为 HSOL 的 Java 解题资料。原文件仍可使用；当前盘面可另存为题目文本。"
        }
    }
}

enum NativePuzzleFormat: String, CaseIterable {
    case hsol, clues, filledValues, formattedClues, pencilMarks, pencilMarksWithStep, combined, library, simpleSudoku
    var title: String {
        switch self {
        case .hsol: return "HoDoKu 题目"
        case .clues: return "单行题面"
        case .filledValues: return "当前数字"
        case .formattedClues: return "格式化题面"
        case .pencilMarks: return "候选格"
        case .pencilMarksWithStep: return "候选格与提示"
        case .combined: return "题面、当前数字和候选"
        case .library: return "HoDoKu 库格式"
        case .simpleSudoku: return "Simple Sudoku"
        }
    }
    var fileExtension: String { self == .hsol ? "hsol" : self == .simpleSudoku ? "ss" : "txt" }
}

enum NativePuzzleFiles {
    static func read(_ url: URL) throws -> BoardProgress {
        var fromClues = false
        return try read(url, fromClues: &fromClues)
    }

    static func read(_ url: URL, fromClues: inout Bool) throws -> BoardProgress {
        fromClues = false
        let info = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard info.isRegularFile == true, let size = info.fileSize, size <= NativePuzzleZip.maximumXMLBytes else { throw NativePuzzleError.file }
        let data = try Data(contentsOf: url)
        switch url.pathExtension.lowercased() {
        case "hsol": return try NativePuzzleHSOL.read(data)
        case "txt", "ss":
            guard var text = String(data: data, encoding: .utf8) else { throw NativePuzzleError.file }
            if text.first == "\u{feff}" { text.removeFirst() }
            return url.pathExtension.lowercased() == "ss" ? try readSS(text) : try readText(text, fromClues: &fromClues)
        default: throw NativePuzzleError.file
        }
    }

    static func readText(_ text: String) throws -> BoardProgress {
        var fromClues = false
        return try readText(text, fromClues: &fromClues)
    }

    static func readText(_ text: String, fromClues: inout Bool) throws -> BoardProgress {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count < 4_194_304 else { throw NativePuzzleError.grid }
        let lines = trimmed.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        if lines.count == 1 {
            let raw = lines[0]
            let fields = raw.components(separatedBy: ":")
            if fields.count == 7 || fields.count == 8 {
                var board = try oneLine(fields[3], allowEntered: true)
                for deletion in fields[4].split(whereSeparator: \.isWhitespace) {
                    let digits = Array(deletion.utf8)
                    guard digits.count == 3, digits.allSatisfy({ (49...57).contains($0) }) else { throw NativePuzzleError.grid }
                    let cell = Int(digits[1]-49)*9 + Int(digits[2]-49)
                    board.candidates[cell] &= ~NativeBoardSnapshot.bit(digits[0]-48)
                }
                return BoardProgress(current: BoardPage(board: board))
            }
            let csv = raw.components(separatedBy: ",")
            let grid = (csv.count >= 7 ? csv[4] : raw).components(separatedBy: "#")[0]
            fromClues = true
            return BoardProgress(current: BoardPage(board: try oneLine(grid)))
        }
        var groups = [[[String]]]()
        var rows = [[String]]()
        for line in lines {
            if line.contains("---") { continue }
            // The suffix of a PM grid may describe a step and contain cell numbers.
            if [9, 18, 27].contains(groups.count * 9 + rows.count), !line.contains("|"), !isGridRow(line) { break }
            let row = line.split { $0.isWhitespace || $0 == "|" }.map { token in
                String(token.filter { $0 == "." || $0.isASCII && $0.isNumber })
            }.filter { !$0.isEmpty }
            guard !row.isEmpty else { continue }
            rows.append(row)
            if rows.count == 9 { groups.append(rows); rows = [] }
        }
        if groups.count == 1 && rows.count == 1 && rows[0].joined().count == 81 { rows = [] }
        guard rows.isEmpty, (1...3).contains(groups.count), let last = groups.last else { throw NativePuzzleError.grid }
        let rawValues = last.map { $0.joined() }.joined()
        if groups.count == 1 && last.allSatisfy({ $0.joined().count == 9 }) {
            fromClues = true
            return BoardProgress(current: BoardPage(board: try oneLine(rawValues)))
        }
        guard last.allSatisfy({ $0.count == 9 }) else { throw NativePuzzleError.grid }
        let tokens = last.flatMap { $0 }
        var masks = [UInt16]()
        for token in tokens {
            if token == "." || token == "0" { masks.append(0); continue }
            let digits = token.utf8
            guard (1...9).contains(digits.count), digits.allSatisfy({ (49...57).contains($0) }),
                  Set(digits).count == digits.count else { throw NativePuzzleError.grid }
            masks.append(digits.reduce(0) { $0 | NativeBoardSnapshot.bit($1-48) })
        }
        let zero = Array(repeating: UInt8(0), count: 81)
        var board = NativeBoardSnapshot(values: zero, fixed: zero.map { _ in false }, candidates: masks,
                                        userCandidates: Array(repeating: 0, count: 81))
        let givens = groups.count > 1 ? try oneLine(groups[0].flatMap { $0 }.joined()) : nil
        let placed = groups.count > 2 ? try oneLine(groups[1].flatMap { $0 }.joined()) : givens
        for cell in 0..<81 where board.candidates[cell].nonzeroBitCount == 1 {
            let bit = board.candidates[cell]
            let digit = UInt8(bit.trailingZeroBitCount + 1)
            if let placed = placed {
                guard placed.values[cell] != 0 else { continue }
                guard placed.values[cell] == digit else { throw NativePuzzleError.grid }
            } else {
                let peer = (0..<81).contains { i in
                    i != cell && board.values[i] == 0 && board.candidates[i] & bit != 0 &&
                    (i/9 == cell/9 || i%9 == cell%9 || (i/27 == cell/27 && i%9/3 == cell%9/3))
                }
                if peer { continue }
            }
            board.setValue(digit, at: cell)
            board.fixed[cell] = givens?.fixed[cell] ?? true
        }
        if let placed = placed, placed.values != board.values { throw NativePuzzleError.grid }
        if let givens = givens, givens.fixed != board.fixed { throw NativePuzzleError.grid }
        try board.validate()
        return BoardProgress(current: BoardPage(board: board))
    }

    private static func isGridRow(_ line: String) -> Bool {
        line.allSatisfy { $0.isWhitespace || $0 == "." || $0.isASCII && $0.isNumber }
    }
    private static func oneLine(_ line: String, allowEntered: Bool = false) throws -> NativeBoardSnapshot {
        var values = [UInt8](), fixed = [Bool](), entered = false
        for c in line.utf8 {
            if [9, 32].contains(c) { continue }
            if c == 43 && allowEntered && !entered { entered = true; continue }
            guard c == 46 || (48...57).contains(c) else { throw NativePuzzleError.grid }
            let d = c == 46 ? 0 : c-48
            guard !entered || d != 0 else { throw NativePuzzleError.grid }
            values.append(d); fixed.append(d > 0 && !entered); entered = false
        }
        guard values.count == 81, !entered else { throw NativePuzzleError.grid }
        let empty = Array(repeating: UInt16(0), count: 81)
        var board = NativeBoardSnapshot(values: values, fixed: fixed, candidates: empty, userCandidates: empty)
        for cell in values.indices where values[cell] == 0 { board.candidates[cell] = board.legalMask(at: cell) }
        return board
    }

    private static func readSS(_ text: String) throws -> BoardProgress {
        let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        let start = lines.firstIndex { $0.first == "I" || $0.first == "E" } ?? lines.count
        var board = try readText(lines[..<start].joined(separator: "\n")).current.board
        for line in lines[start...] where !line.isEmpty {
            let part = Array(line.utf8)
            guard (part.count == 4 && part[0] == 73) || (part.count == 6 && part[0] == 69),
                  part.dropFirst().allSatisfy({ (48...57).contains($0) }) else { throw NativePuzzleError.grid }
            let cell = Int(part[1]-48)*10 + Int(part[2]-48)
            guard cell < 81, let value = UInt8(String(decoding: part.dropFirst(3), as: UTF8.self)),
                  (1...9).contains(value) else { throw NativePuzzleError.grid }
            if part[0] == 73 {
                guard !board.fixed[cell] else { throw NativePuzzleError.grid }
                board.setValue(value, at: cell)
            } else { board.candidates[cell] &= ~NativeBoardSnapshot.bit(value) }
        }
        return BoardProgress(current: BoardPage(board: board))
    }

    static func encode(_ progress: BoardProgress, as format: NativePuzzleFormat, step reading: NativeHintReading? = nil, useZero: Bool = false) throws -> Data {
        try progress.validate()
        if format == .hsol { return try NativePuzzleHSOL.encode(progress) }
        let board = progress.current.board
        let blank = useZero && format != .simpleSudoku ? "0" : "."
        let clues = board.values.indices.map { board.fixed[$0] ? String(board.values[$0]) : blank }
        let values = board.values.map { $0 == 0 ? blank : String($0) }
        var text: String
        switch format {
        case .hsol: throw NativePuzzleError.file
        case .clues: text = clues.joined()
        case .filledValues: text = values.joined()
        case .formattedClues: text = grid(clues)
        case .pencilMarks, .combined, .pencilMarksWithStep:
            let hint = format == .pencilMarksWithStep && reading?.source == board ? reading : nil
            let pm = board.values.indices.map { i -> String in
                if board.values[i] != 0 { return String(board.values[i]) }
                let digits = (1...9).filter { board.candidates[i] & NativeBoardSnapshot.bit(UInt8($0)) != 0 }
                if digits.isEmpty { return blank }
                let marks = digits.map { digit in
                    hint.map { $0.step.deletions[i] & NativeBoardSnapshot.bit(UInt8(digit)) != 0 } == true ? "-\(digit)" : String(digit)
                }.joined()
                return hint?.step.premises.contains(i) == true ? "*" + marks : marks
            }
            text = (format == .combined ? grid(clues) + "\n\n" + grid(values) + "\n\n" : "") + grid(pm)
            if let hint = hint { text += "\n" + hint.stages.map(\.text).joined(separator: " ").components(separatedBy: .newlines).joined(separator: " ") }
        case .library, .simpleSudoku:
            var removals = [String](), entered = [String]()
            for i in board.values.indices {
                if board.values[i] != 0 && !board.fixed[i] { entered.append(String(format: "I%02d%d", i, Int(board.values[i]))) }
                guard board.values[i] == 0 else { continue }
                let legal = board.legalMask(at: i)
                guard board.candidates[i] & ~legal == 0 else { throw NativePuzzleError.projection }
                for d in 1...9 where legal & ~board.candidates[i] & NativeBoardSnapshot.bit(UInt8(d)) != 0 {
                    removals.append(format == .library ? "\(d)\(i/9+1)\(i%9+1)" : String(format: "E%02d%03d", i, d))
                }
            }
            if format == .library {
                let cells = board.values.indices.map { board.values[$0] != 0 && !board.fixed[$0] ? "+" + values[$0] : values[$0] }
                text = ":0000:x:" + cells.joined() + ":" + removals.joined(separator: " ") + "::"
            } else {
                text = grid(clues, compact: true) + "\n\n" + (entered + removals).joined(separator: "\n") + "\n"
            }
        }
        return Data(text.utf8)
    }

    private static func grid(_ cells: [String], compact: Bool = false) -> String {
        let width = (0..<9).map { col in (0..<9).map { cells[$0*9+col].count }.max() ?? 1 }
        let gap = compact ? "" : " "
        let border = compact ? "*-----------*" : "+" + (0..<3).map { box in
            String(repeating: "-", count: width[(box*3)..<(box*3+3)].reduce(0, +) + 4)
        }.joined(separator: "+") + "+"
        var rows = [border]
        for row in 0..<9 {
            if row > 0 && row%3 == 0 { rows.append(compact ? "|---+---+---|" : border) }
            let boxes = (0..<3).map { box in
                (box*3..<box*3+3).map { col in cells[row*9+col].padding(toLength: width[col], withPad: " ", startingAt: 0) }
                    .joined(separator: gap)
            }
            rows.append("|" + gap + boxes.joined(separator: gap+"|"+gap) + gap + "|")
        }
        rows.append(border)
        return rows.joined(separator: "\n")
    }
}
