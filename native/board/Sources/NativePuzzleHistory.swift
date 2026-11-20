// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

struct NativePuzzleHistoryEntry: Codable, Equatable, Identifiable {
    let clues: String
    let level: Int
    let score: Int
    let lastStartedAt: Int64
    let finalGrid: String?
    let completedAt: Int64
    var id: String { clues }
    var isCompleted: Bool { finalGrid != nil }
    var puzzleForOpen: String {
        guard let final = finalGrid else { return clues }
        return ":0000:x:" + zip(clues, final).map { $0 == "0" ? "+" + String($1) : String($1) }.joined() + ":::"
    }

    static func parse(_ encoded: String) throws -> Self {
        let parts = encoded.components(separatedBy: "#")
        guard [4, 7].contains(parts.count), let level = Int32(parts[1]), level >= 0, let score = Int32(parts[2]),
              let time = Int64(parts[3]), time >= 0 else { throw NativePuzzleError.history }
        let clues = try normalize(parts[0], complete: false)
        var final: String?
        var completed: Int64 = 0
        if parts.count == 7 {
            switch parts[4] {
            case "I" where parts[5].isEmpty: break
            case "C":
                let value = try normalize(parts[5], complete: true)
                guard zip(clues, value).allSatisfy({ $0 == "0" || $0 == $1 }),
                      let end = Int64(parts[6]), end >= 0 else { throw NativePuzzleError.history }
                final = value
                completed = end
            default: throw NativePuzzleError.history
            }
        }
        return Self(clues: clues, level: Int(level), score: Int(score), lastStartedAt: time,
                    finalGrid: final, completedAt: completed)
    }

    private static func normalize(_ value: String, complete: Bool) throws -> String {
        let grid = value.filter { !$0.isWhitespace }.replacingOccurrences(of: ".", with: "0")
        guard grid.utf8.count == 81, grid.utf8.allSatisfy({ (complete ? 49 : 48)...57 ~= $0 }) else {
            throw NativePuzzleError.history
        }
        return grid
    }

    func encode() -> String {
        [clues, String(level), String(score), String(lastStartedAt), isCompleted ? "C" : "I",
         finalGrid ?? "", String(completedAt)].joined(separator: "#")
    }
}

enum NativePuzzleHistory {
    static func record(_ board: NativeBoardSnapshot, level: Int, score: Int, at time: Int64,
                       completed: Bool, limit: Int, in entries: inout [NativePuzzleHistoryEntry]) throws {
        try board.validate()
        guard level >= 0, time >= 0 else { throw NativePuzzleError.history }
        let clues = zip(board.fixed, board.values).map { $0 ? String($1) : "0" }.joined()
        let prior = entries.first { $0.clues == clues }
        if completed && board.values.contains(0) { throw NativePuzzleError.history }
        let entry = NativePuzzleHistoryEntry(clues: clues, level: level, score: score,
            lastStartedAt: completed ? prior?.lastStartedAt ?? time : time,
            finalGrid: completed ? board.values.map(String.init).joined() : prior?.finalGrid,
            completedAt: completed ? time : prior?.completedAt ?? 0)
        entries.removeAll { $0.clues == clues }
        entries.insert(entry, at: 0)
        if entries.count > max(0, limit) { entries.removeLast(entries.count - max(0, limit)) }
    }
}
