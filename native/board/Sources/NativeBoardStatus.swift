// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Presentation of the actual selection and filters, including the displayed frozen frame.
struct NativeBoardStatus {
    let filled: Int
    let mode: String
    let grade: String?
    let score: Int?
    let selection: String?
    let selectedContent: String?
    let selectionDetail: String?
    let showingCandidates: Bool
    let showingBoardCandidates: Bool
    let placed: [Int]
    let availableDigits: UInt16
    let filterDigits: UInt16
    let filterCounts: Set<Int>
    let filterSummary: String

    var filtered: Bool { filterDigits != 0 || !filterCounts.isEmpty }

    static func digits(_ mask: UInt16) -> String {
        (1...9).filter { mask & NativeBoardSnapshot.bit(UInt8($0)) != 0 }.map(String.init).joined(separator: "、")
    }

    init(model: NativeBoardModel) {
        let context = model.progress.extra
        let frozen = model.frozen
        let board = frozen?.page.board ?? model.progress.current.board
        let cells = frozen?.selectionCells ?? model.selectionCells
        var counts = [Int](repeating: 0, count: 10)
        for value in board.values { counts[Int(value)] += 1 }
        placed = counts
        filled = 81 - counts[0]
        showingCandidates = model.showingSelectedCandidates
        // Selection-only reveal changes the selection readout, not the full-board filter.
        showingBoardCandidates = model.showingBoardCandidates
        let boardMasks = showingBoardCandidates ? board.candidates : board.userCandidates
        availableDigits = board.values.indices.reduce(0) { board.values[$1] == 0 ? $0 | boardMasks[$1] : $0 }
        if context?.editingClues == true {
            mode = "录题"
        } else {
            switch context?.mode {
            case "PRACTISING": mode = "练习"
            case "LEARNING": mode = "学习"
            case "PLAYING": mode = "普通"
            default: mode = "作答"
            }
        }
        let levels = ["容易", "中等", "困难", "艰难", "极难"]
        grade = context?.difficulty.flatMap { (1...levels.count).contains($0) ? levels[$0 - 1] : nil }
        score = grade == nil ? nil : context?.score

        let masks = showingCandidates ? board.candidates : board.userCandidates
        let label = showingCandidates ? "候选" : "笔记"
        if cells.count == 1, let cell = cells.first {
            selection = "R\(cell / 9 + 1)C\(cell % 9 + 1)"
            if board.values[cell] != 0 {
                selectedContent = "\(board.fixed[cell] ? "给定" : "已填") \(board.values[cell])"
            } else {
                selectedContent = masks[cell] == 0 ? "无\(label)" : label + " " + Self.digits(masks[cell])
            }
            selectionDetail = nil
        } else if !cells.isEmpty {
            selection = "已选 \(cells.count) 格"
            let empty = cells.filter { board.values[$0] == 0 }
            if let first = empty.first {
                let common = empty.reduce(masks[first]) { $0 & masks[$1] }
                let any = empty.reduce(UInt16(0)) { $0 | masks[$1] }
                selectedContent = common == 0 ? "无共同\(label)" : "共同\(label) " + Self.digits(common)
                selectionDetail = "\(empty.count) 个空格" + (any == 0 ? "，无\(label)" : "，合计\(label) " + Self.digits(any))
            } else {
                let given = cells.filter { board.fixed[$0] }.count
                selectedContent = "给定 \(given) 格，已填 \(cells.count - given) 格"
                selectionDetail = nil
            }
        } else {
            selection = nil
            selectedContent = nil
            selectionDetail = nil
        }

        filterDigits = frozen?.digitFilter ?? model.hintDigits
        filterCounts = frozen?.countFilters ?? model.countFilters
        var rules: [String] = []
        if filterDigits != 0 {
            var digits = Self.digits(filterDigits)
            if filterDigits.nonzeroBitCount > 1 {
                digits += (frozen?.filterAnyDigit ?? model.mouseOptions.useOrInsteadOfAndForFilter) ? "（含其一）" : "（同时含有）"
            }
            rules.append(digits)
        }
        if filterCounts.contains(2) { rules.append("双值格") }
        if filterCounts.contains(3) { rules.append("三值格") }
        let inverted = frozen?.inverseFilter ?? model.inverseFilter
        filterSummary = rules.isEmpty ? "筛选候选数字或候选个数" : (inverted ? "反选 " : "筛选 ") + rules.joined(separator: " 或 ")
    }
}
