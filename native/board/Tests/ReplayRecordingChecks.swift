import Foundation

#if !COMBINED_BOARD_CHECKS
@main
#endif
enum ReplayRecordingChecks {
    private static func manual(_ page: BoardPage, kind: String = "manual") -> NativeReplayFrame {
        NativeReplayFrame(operationID: 0, wallTimeMillis: 0, elapsedMillis: 0, kind: kind, label: "编辑", page: page)
    }

    static func main() throws {
        let initial = BoardPage()
        var recorder = NativeReplayRecorder(initial: initial, nowNanos: 0, wallMillis: 50)
        recorder.setPaused("inactive", true, nowNanos: 8_500_000)
        recorder.setPaused("viewer", true, nowNanos: 15_000_000)
        recorder.setPaused("inactive", false, nowNanos: 18_000_000)
        recorder.setPaused("viewer", false, nowNanos: 23_000_000)
        recorder.checkpoint(nowNanos: 24_500_000)
        precondition(recorder.document.elapsedMillis == 10)
        var after = initial
        after.board.setValue(4, at: 2)
        let frame = BoardFrame(page: initial, selected: 2, reference: 2)
        let proof = try NativeReplayFrame.capture(frame, kind: "proof", label: "依据", text: "原盘证明", freeze: true)
        precondition(proof.previewPNG == (try? BoardPainter.png(frame)))
        precondition(recorder.capture([proof, manual(after, kind: "apply")], nowNanos: 34_500_000, wallMillis: 2))
        precondition(recorder.document.frames.suffix(2).allSatisfy { $0.elapsedMillis == 20 && $0.operationID == 1 })
        precondition(recorder.document.frames[1].page == initial && recorder.document.frames[2].page == after)
        precondition(!recorder.capture([manual(after)], nowNanos: 34_500_000, wallMillis: 5))
        var other = after
        other.board.values[0] = 2
        precondition(!recorder.capture([manual(after), manual(other)], nowNanos: 34_500_000, wallMillis: 5))
        precondition(recorder.document.frames.count == 3)
        after.marks.append(BoardMark(cell: 2, digit: 0, color: 0))
        precondition(!recorder.capture([manual(after)], nowNanos: 40_500_000, wallMillis: 4))
        precondition(recorder.document.frames.count == 3)
        after.board.setValue(6, at: 3)
        precondition(recorder.capture([manual(after)], nowNanos: 44_500_000, wallMillis: 4))
        precondition(recorder.document.frames.last?.page.marks == after.marks)
        recorder.checkpoint(nowNanos: 54_500_000)
        try recorder.document.validateNativeRecording()

        let saved = try JSONEncoder().encode(recorder.document)
        let restored = try JSONDecoder().decode(NativeReplayDocument.self, from: saved)
        precondition(restored == recorder.document)
        var player = NativeReplayPlayer(document: restored)
        player.seek(10)
        precondition(player.index == 0)
        player.stepOperation(1)
        precondition(player.index == 1 && player.frame?.previewPNG == proof.previewPNG)
        player.stepFrame(1)
        player.stepOperation(-1)
        precondition(player.index == 0)
        player.seek(20)
        precondition(player.index == 1)
        player.setPlaying(true, nowNanos: 0)
        player.tick(nowNanos: 699_000_000)
        precondition(player.index == 1 && player.cursorMillis == 20)
        player.tick(nowNanos: 700_000_000)
        precondition(player.index == 2 && player.cursorMillis == 20)
        player.tick(nowNanos: 705_000_000)
        precondition(player.index == 2 && player.cursorMillis == 25)
        player.setPlaying(false, nowNanos: 706_000_000)
        precondition(!player.playing && player.cursorMillis == 26)
        player.setPlaying(true, nowNanos: 1_000_000_000)
        player.tick(nowNanos: 1_004_000_000)
        precondition(player.index == 3 && player.cursorMillis == 30 && player.playing)
        player.tick(nowNanos: 1_014_000_000)
        precondition(player.cursorMillis == 40 && !player.playing)
        player.setPlaying(true, nowNanos: 2_000_000_000)
        precondition(player.index == 0 && player.playing)

        var branch = initial
        branch.board.values = Array("534678912672195348198342567859761423426853791713924856961537284287419635345286179".utf8).map { $0 - 48 }
        branch.board.candidates = Array(repeating: 0, count: 81)
        let complete = NativeReplayRecorder(initial: branch, nowNanos: 0, wallMillis: 100)
        precondition(complete.document.completed && complete.document.retained && complete.document.endedAt == 100)
        branch.board.values[0] = 9
        precondition(!NativeReplayRecorder(initial: branch, nowNanos: 0, wallMillis: 100).document.completed)
        var foreign = restored
        foreign.format = .frame02
        var readonly = NativeReplayRecorder(document: foreign, nowNanos: 0)
        precondition(!readonly.capture([manual(after)], nowNanos: 3_000_000, wallMillis: 3))
        print("Replay recording, effective time, frozen proof, playback and sealing passed")
    }
}
