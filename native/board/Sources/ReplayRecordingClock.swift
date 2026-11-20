import Foundation
import HodokuEngine

extension NativeBoardSnapshot {
    fileprivate var replayCells: [HodokuReplayCell] {
        guard values.count == 81, fixed.count == 81, candidates.count == 81, userCandidates.count == 81 else { return [] }
        return values.indices.map { i in
            HodokuReplayCell(value: values[i], fixed: fixed[i] ? 1 : 0, candidates: candidates[i],
                             user_candidates: userCandidates[i])
        }
    }

    var completeAndCorrect: Bool {
        guard values.count == 81, !values.contains(0) else { return false }
        var result = HodokuCountResult()
        return hodoku_count_solutions_v1(values, values.count, nil, 0, 1, 1, nil, &result) == 0
            && result.termination == HODOKU_EXHAUSTED && result.count == 1
    }
}

struct NativeReplayRecorder {
    var document: NativeReplayDocument
    private var pauses = Set<String>()
    private var lastNanos: UInt64
    private var fractionNanos: UInt64 = 0

    init(initial: BoardPage, nowNanos: UInt64, wallMillis: Int64) {
        var first = NativeReplayFrame(operationID: 0, wallTimeMillis: wallMillis, elapsedMillis: 0,
                                      kind: "initial", label: "起始盘面", page: initial)
        first.branchPage = initial
        self.init(document: NativeReplayDocument(id: UUID().uuidString, startedAt: wallMillis, frames: [first]),
                  nowNanos: nowNanos)
        if initial.board.completeAndCorrect { seal(wallMillis: wallMillis) }
    }

    init(document: NativeReplayDocument, nowNanos: UInt64) {
        self.document = document
        lastNanos = nowNanos
    }

    mutating func checkpoint(nowNanos: UInt64) {
        let delta = nowNanos >= lastNanos ? nowNanos - lastNanos : 0
        lastNanos = nowNanos
        guard pauses.isEmpty, !document.completed, document.format == .native else { return }
        let nanos = fractionNanos + delta % 1_000_000
        let millis = Int64(delta / 1_000_000 + nanos / 1_000_000)
        fractionNanos = nanos % 1_000_000
        document.elapsedMillis += min(millis, Int64.max - document.elapsedMillis)
    }

    mutating func setPaused(_ reason: String, _ paused: Bool, nowNanos: UInt64) {
        checkpoint(nowNanos: nowNanos)
        if paused { pauses.insert(reason) } else { pauses.remove(reason) }
    }

    @discardableResult
    mutating func capture(_ frames: [NativeReplayFrame], nowNanos: UInt64, wallMillis: Int64) -> Bool {
        guard document.format == .native, !document.completed,
              let prior = document.frames.last, prior.operationID < Int64.max, let last = frames.last else { return false }
        let baseline = prior.board.replayCells
        for frame in frames {
            let cells = frame.board.replayCells
            let relation = hodoku_replay_relation_v1(baseline, baseline.count, cells, cells.count)
            guard relation >= 1 else { return false }
            if frames.count == 1, relation == 2, frame.kind == "manual" { return false }
        }
        checkpoint(nowNanos: nowNanos)
        let operation = prior.operationID + 1
        for var frame in frames {
            frame.operationID = operation
            frame.operationGroup = String(operation)
            frame.elapsedMillis = document.elapsedMillis
            frame.wallTimeMillis = wallMillis
            document.frames.append(frame)
        }
        if last.board.completeAndCorrect { seal(wallMillis: wallMillis) }
        return true
    }

    private mutating func seal(wallMillis: Int64) {
        document.completed = true
        document.retained = true
        document.endedAt = wallMillis
    }
}

extension NativeReplayDocument {
    func validateNativeRecording() throws {
        guard format == .native, originalBytes == nil, !id.isEmpty, elapsedMillis >= 0,
              let first = frames.first, let last = frames.last, first.kind == "initial",
              first.elapsedMillis == 0, first.operationID == 0,
              (sourceReplayID == nil) == (sourceFrameIndex == nil), (sourceFrameIndex ?? 0) >= 0,
              bookmarks.allSatisfy({ frames.indices.contains($0.frameIndex) }),
              !completed || last.board.completeAndCorrect else { throw BoardFileError.invalid }
        let initial = first.board.replayCells
        var ids = Set<String>()
        var prior = first
        for frame in frames {
            let cells = frame.board.replayCells
            guard !frame.id.isEmpty, ids.insert(frame.id).inserted,
                  frame.operationID >= prior.operationID, frame.operationID - prior.operationID <= 1,
                  frame.operationGroup == String(frame.operationID), frame.elapsedMillis >= prior.elapsedMillis,
                  frame.elapsedMillis <= elapsedMillis, (frame.branchPage?.board ?? frame.board) == frame.board,
                  hodoku_replay_relation_v1(initial, initial.count, cells, cells.count) >= 1
            else { throw BoardFileError.invalid }
            try BoardProgress(current: frame.page).validate()
            if let editable = frame.branchPage, editable != frame.page { try BoardProgress(current: editable).validate() }
            prior = frame
        }
    }
}
