// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

struct NativeGameContext: Codable, Equatable {
    var name: String?
    var editingClues: Bool?
    var difficulty: Int?
    var requestedDifficulty: Int?
    var mode: String?
    var score: Int?
    var historyAllowsStart: Bool?
    var historyTransition: NativeHistoryTransition?
    var activeCell: Int?
    var sourceName: String?
    var sourceSessionXML: Data?
    var legacy: LegacySessionContext?
    var puzzleArchive: NativePuzzleArchive?
    var savePoints: [NativeGameSavePoint]?
}

/// History completion belongs to the work session. Undoing a solved board can create a new replay.
struct NativeHistoryTransition: Codable, Equatable {
    var started: Bool
    var recorded: Bool
    var previouslySolved: Bool
}

struct NativeGameSavePoint: Codable, Equatable {
    var name: String
    var date: Date
    var progress: BoardProgress
}

struct WorkspaceProblem: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
