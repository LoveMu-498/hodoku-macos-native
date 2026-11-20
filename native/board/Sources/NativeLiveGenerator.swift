// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import HodokuEngine

enum NativeGenerationError: LocalizedError {
    case invalidRequest, cancelled, searchLimit, patternRejected, noTraining
    var errorDescription: String? {
        switch self {
        case .invalidRequest: return "出题设置无效。"
        case .cancelled: return "出题已取消。"
        case .searchLimit: return "本次搜索达到上限，尚未找到符合条件的题目。可以重试或调整难度和训练技巧。"
        case .patternRejected: return "使用当前给定数图案未能得到唯一解。可以重试或更换图案。"
        case .noTraining: return "请选择至少一种训练技巧。"
        }
    }
}

private final class GenerationCancellation {
    let stop: () -> Bool
    init(_ stop: @escaping () -> Bool) { self.stop = stop }
}

enum NativeLiveGenerator {
    /// Options selects a custom pattern only when its saved valid flag is true.
    static func pattern(from legacyXML: Data?) throws -> [UInt8]? {
        guard let data = legacyXML else { return nil }
        let objects = try LegacySessionXML.objects(data)
        guard objects.count == 1, let opts = objects.first, opts.className == "sudoku.Options" else {
            throw NativeGenerationError.invalidRequest
        }
        return try NativePatternSettings(opts).activeCells
    }

    static func checkPattern(_ pattern: NativeCluePattern, seed: Int64 = .random(in: .min ... .max),
                             cancelled: @escaping () -> Bool) throws {
        guard pattern.cells.count == 81, pattern.givens >= 17 else {
            throw WorkspaceProblem("至少需要 17 个给定数才能检查图案。")
        }
        _ = try clues(seed: seed, pattern: pattern.cells.map { $0 ? 1 : 0 }, stop: GenerationCancellation(cancelled))
    }

    private static func clues(seed: Int64, pattern: [UInt8]?, stop: GenerationCancellation) throws -> [UInt8] {
        var clues = Array(repeating: UInt8(0), count: 81)
        let request: HodokuGenerationCancelled = { ptr in
            guard let ptr = ptr else { return 1 }
            return Unmanaged<GenerationCancellation>.fromOpaque(ptr).takeUnretainedValue().stop() ? 1 : 0
        }
        let context = Unmanaged.passUnretained(stop).toOpaque()
        let result: Int32 = withExtendedLifetime(stop) {
            if let pattern = pattern {
                return hodoku_generate_clues_v1(seed, 1, pattern, pattern.count, 1024, request, context, &clues, 81)
            }
            return hodoku_generate_clues_v1(seed, 1, nil, 0, 1024, request, context, &clues, 81)
        }
        switch result {
        case 0: return clues
        case 1: throw NativeGenerationError.cancelled
        case 2: throw NativeGenerationError.searchLimit
        case 3: throw NativeGenerationError.patternRejected
        default: throw NativeGenerationError.invalidRequest
        }
    }

    /// Run on a worker queue. Each accepted game is certified by the clue-removal
    /// counter and rated by the same ordered logical solver used by the workbench.
    static func next(level: Int, mode: String, training: Set<String>, recent: [String],
                     config: NativeSolverConfig, pattern: [UInt8]? = nil,
                     seed: Int64 = .random(in: .min ... .max), attemptLimit: Int = 20_001,
                     timeout: TimeInterval = 60, cancelled: @escaping () -> Bool) throws -> BoardProgress {
        guard (1...5).contains(level), ["PLAYING", "PRACTISING", "LEARNING"].contains(mode),
              attemptLimit >= 0, timeout.isFinite, timeout >= 0, pattern == nil || pattern?.count == 81 else {
            throw NativeGenerationError.invalidRequest
        }
        let trainingSteps = mode == "PLAYING" ? Set<String>() : training
        if mode != "PLAYING" && trainingSteps.isEmpty { throw NativeGenerationError.noTraining }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        let stop = GenerationCancellation { cancelled() || ProcessInfo.processInfo.systemUptime >= deadline }
        let recentClues = Set(recent)
        for attempt in 0..<attemptLimit {
            do {
                let values = try clues(seed: seed &+ Int64(attempt), pattern: pattern, stop: stop)
                let clueString = String(decoding: values.map { $0 + 48 }, as: UTF8.self)
                if recentClues.contains(clueString) { continue }
                var progress = BoardProgress()
                var board = NativeBoardSnapshot(values: values, fixed: values.map { $0 != 0 },
                    candidates: Array(repeating: 0, count: 81), userCandidates: Array(repeating: 0, count: 81))
                for cell in 0..<81 where values[cell] == 0 { board.candidates[cell] = board.legalMask(at: cell) }
                let path = try NativeLogicalEngine.rate(board, config: config, fromClues: true,
                    maxLevel: mode == "LEARNING" ? 5 : level, rejectTooLowScore: true, training: trainingSteps, cancelled: stop.stop)
                if stop.stop() { throw NativeGenerationError.cancelled }
                guard path.solved, mode == "LEARNING" || path.difficulty == level else { continue }
                if mode != "PLAYING" {
                    guard let first = path.steps.firstIndex(where: { trainingSteps.contains($0.trainingKey) }) else { continue }
                    if mode == "LEARNING" {
                        for step in path.steps[..<first] {
                            guard let next = step.applying(to: board) else { throw BoardFileError.invalid }
                            board = next
                        }
                    }
                }
                progress.current.board = board
                var context = NativeGameContext()
                context.difficulty = path.difficulty
                context.requestedDifficulty = level
                context.score = path.score
                context.mode = mode
                progress.extra = context
                try progress.validate()
                return progress
            } catch {
                if cancelled() { throw NativeGenerationError.cancelled }
                if ProcessInfo.processInfo.systemUptime >= deadline { throw NativeGenerationError.searchLimit }
                throw error
            }
        }
        if cancelled() { throw NativeGenerationError.cancelled }
        throw NativeGenerationError.searchLimit
    }
}
