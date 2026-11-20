// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

enum WorkspaceCrashRecovery {
    /// A pending quit and its independently saved replay must describe the same attempt
    /// and the same instant. Prefer a newer live session after cancel, or a changed game.
    static func pending(checkpoint data: Data?, replay replayData: Data?, current: BoardProgress,
                        recorded: NativeReplayDocument?, sessionDigest: String?) -> (BoardProgress, NativeReplayDocument)? {
        let decoder = JSONDecoder()
        guard let data = data, let checkpoint = try? decoder.decode(WorkspaceCheckpoint.self, from: data),
              !checkpoint.clean, let replayData = replayData,
              let replay = try? decoder.decode(NativeReplayDocument.self, from: replayData),
              replay.id == checkpoint.attempt, replay.frames.count == checkpoint.frames,
              replay.elapsedMillis == checkpoint.elapsed, let last = replay.frames.last,
              (try? replay.validateNativeRecording()) != nil else { return nil }
        if let expected = checkpoint.baseSessionSHA256, expected != sessionDigest { return nil }
        if let prior = recorded {
            guard prior.id == replay.id, prior.elapsedMillis <= replay.elapsedMillis,
                  replay.frames.starts(with: prior.frames) else { return nil }
        } else {
            guard let snapshot = checkpoint.progress,
                  sessionDigest == nil || checkpoint.baseSessionSHA256 == sessionDigest,
                  snapshot.current.board == last.board else { return nil }
        }

        var recovered: BoardProgress
        if let snapshot = checkpoint.progress {
            // A checkpoint written without an observed session cannot replace a later
            // annotation-only change at the same frame with equal elapsed time.
            if checkpoint.baseSessionSHA256 == nil, let prior = recorded,
               replay.frames.count == prior.frames.count, replay.elapsedMillis == prior.elapsedMillis { return nil }
            recovered = snapshot
        } else if current.current.board == last.board {
            recovered = current
        } else {
            // Earlier checkpoints did not embed an undo stack. Keep only the history
            // we can reconstruct from the durable current page and the recovered frames.
            recovered = BoardProgress(current: last.branchPage ?? last.page)
            recovered.extra = current.extra
            if let count = recorded?.frames.count {
                var previous = current.current.board
                for frame in replay.frames.dropFirst(count) where frame.board != previous {
                    recovered.boardUndo.append(previous)
                    previous = frame.board
                }
            }
        }
        guard recovered.current.board == last.board, (try? recovered.validate()) != nil,
              recovered != current || replay != recorded else { return nil }
        return (recovered, replay)
    }
}
