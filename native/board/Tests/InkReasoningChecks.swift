import Foundation

// Shared positions with DoodleContradictionBasisProbe and DoodleConsensusBasisProbe.
#if !COMBINED_BOARD_CHECKS
@main
#endif
enum InkReasoningChecks {
    private static var empty: NativeBoardSnapshot {
        NativeBoardSnapshot(values: Array(repeating: 0, count: 81), fixed: Array(repeating: false, count: 81),
                            candidates: Array(repeating: 511, count: 81), userCandidates: Array(repeating: 511, count: 81))
    }
    private static func mark(_ cell: Int, _ digit: Int, _ kind: InkStroke.Kind,
                             start: Bool = false, group: Int = 0) -> InkStroke {
        var s = InkStroke(kind: kind, group: group, width: 0.005, cell: cell, digit: digit)
        s.start = start
        return s
    }
    private static func check(_ condition: @autoclosure () -> Bool, _ label: String) {
        precondition(condition(), label)
    }

    static func main() throws {
        try startsAndOutlines()
        try contradiction()
        consensusAndCompletion()
        rectangleEvidence()
        projection()
        print("PASS P reasoning: G start roles, circle/cross transaction, shared outline invalidation, batch fill/delete, refutation, persistent OR source, consensus and authored completion")
    }

    static func startsAndOutlines() throws {
        var board = empty
        var ink = InkToolState()
        func toggle(_ c: Int, _ d: Int, _ k: InkStroke.Kind, _ g: Bool) -> Bool {
            InkReasoning.toggleMark(mark(c, d, k), in: &ink, board: board, enteringStart: g)
        }
        check(toggle(80, 5, .circle, false) && ink.strokes[0].start, "first ordinary mark starts the group")
        check(toggle(79, 4, .circle, true), "G appends homogeneous starts")
        let saved = ink
        check(!toggle(80, 5, .cross, true) && ink == saved, "opposite start refuses atomically")
        check(InkReasoning.clearStarts(in: &ink, group: 0) && ink.strokes.count == 2 && !ink.strokes.contains(where: \.start), "double G preserves ink")
        check(toggle(80, 5, .circle, true) && ink.strokes[0].start, "existing G circle only changes role")
        check(toggle(80, 5, .cross, true) && ink.strokes.last?.kind == .cross && ink.strokes.last?.start == true, "sole opposite start replacement")
        check(InkReasoning.clearStarts(in: &ink, group: 0) && toggle(60, 3, .circle, false) && !ink.strokes.last!.start, "clearing role preserves consumed first mark")
        var separate = InkToolState()
        separate.strokes = [mark(0, 3, .circle), mark(1, 3, .circle), mark(0, 4, .cross), mark(10, 4, .cross)]
        func outline(_ c: Int, _ d: Int, _ k: InkStroke.Kind, group: Int = 0) -> Bool {
            InkReasoning.toggleOutline(in: &separate, group: group, cell: c, digit: d, kind: k, board: board)
        }
        check(outline(0, 3, .circle) && !outline(1, 3, .circle) && !outline(0, 4, .cross), "peer circles and different digits on an outlined cell rejected")
        check(outline(10, 4, .cross) && InkReasoning.apply(in: &separate, group: 0, board: &board), "explicit batch")
        check(board.values[0] == 3 && (board.candidates[10] | board.userCandidates[10]) & 8 == 0, "P deletes ordinary and user masks before fills")
        board = empty
        separate.strokes = [mark(1, 2, .cross, group: 1), mark(1, 2, .cross, group: 2)]
        check(outline(1, 2, .cross) && separate.strokes.contains { $0.outlineSources == [1, 2] }, "shared sources can be selected from a third palette group")
        separate.strokes.removeFirst()
        InkReasoning.reconcile(&separate)
        check(!separate.strokes.contains(where: \.outlined) && !InkReasoning.apply(in: &separate, group: 0, board: &board), "source loss cancels shared selection")
    }

    static func contradiction() throws {
        var board = empty
        board.candidates[32] = 1 | 64 | 256
        let before = board
        var ink = InkToolState()
        ink.strokes = [mark(80, 5, .circle, start: true), mark(32, 1, .cross), mark(32, 7, .cross)]
        check(!InkReasoning.apply(in: &ink, group: 0, board: &board), "absent handwriting is not a false candidate")
        ink.strokes.append(mark(32, 9, .cross))
        let display = InkReasoning.display(ink, group: 0, board: board)
        check(display.strokes.filter(\.witness).count == 3 && display.strokes.contains { $0.kind == .cross && $0.cell == 80 && $0.outlined }, "inverse and witness render without mutating ink")
        check(InkReasoning.apply(in: &ink, group: 0, board: &board) && board.candidates[80] & 16 == 0 && board.userCandidates[80] & 16 == 0, "refutation deletes original circle")
        board = before
        ink.strokes = [mark(80, 5, .cross, start: true), mark(79, 4, .cross, start: true),
                       mark(32, 1, .cross), mark(32, 7, .cross), mark(32, 9, .cross)]
        let proof = ink.strokes
        check(InkReasoning.apply(in: &ink, group: 0, board: &board) && board == before && ink.proofs[0] == proof, "whole inverted premise becomes a saved OR with provenance")
        check(ink.strokes.count == 2 && ink.strokes.allSatisfy { $0.start && $0.kind == .circle } &&
              !InkReasoning.apply(in: &ink, group: 0, board: &board), "OR does not fill either member individually")
        let beforePreview = ink
        func projected(_ tool: BoardTool, _ group: Int, _ held: Bool, _ step: Bool = false) -> [InkStroke] {
            InkProofPreview.sources(in: ink, tool: tool, inkGroup: group, optionOrMiddle: held, displayingStep: step)
        }
        let archive = projected(.ink, 0, true)
        check(archive.count == 5 && archive.allSatisfy { !$0.start && !$0.outlined && !$0.witness } &&
              archive.map(\.cell) == proof.map(\.cell), "held preview shows exactly the five original ink marks without roles")
        check(projected(.chain, 0, true) == archive && projected(.chain, 1, true).isEmpty &&
              projected(.ink, 0, false).isEmpty && projected(.ink, 0, true, true).isEmpty &&
              projected(.boxes, 0, true).isEmpty, "P palette controls L preview; release, S and displayed solver step hide the archive")
        let roundTrip = try JSONDecoder().decode(InkToolState.self, from: JSONEncoder().encode(ink))
        check(InkProofPreview.sources(in: roundTrip, tool: .ink, inkGroup: 0, optionOrMiddle: true, displayingStep: false) == archive &&
              beforePreview == ink && before == board, "archives reopen readonly; held preview has no board or history mutation")
        var cancelled = ink
        check(InkReasoning.clearStarts(in: &cancelled, group: 0) &&
              InkProofPreview.sources(in: cancelled, tool: .ink, inkGroup: 0, optionOrMiddle: true, displayingStep: false) == archive,
              "G only clears start roles, the original adopted circles still own their archived geometry")
        cancelled.strokes = [mark(1,1,.circle,start:true)]
        InkReasoning.reconcile(&cancelled)
        check(cancelled.proofs.isEmpty, "unrelated new start cannot retain or expose old proof")
        var legacy = ink
        for i in legacy.strokes.indices { legacy.strokes[i].ownsProof = nil }
        check(InkProofPreview.sources(in: legacy, tool: .ink, inkGroup: 0, optionOrMiddle: true, displayingStep: false) == archive,
              "older native archives use their recorded all-false atoms to identify the true owners")
        board.setValue(5, at: 80)
        InkReasoning.pruneStale(in: &ink, board: board)
        check(ink.strokes.isEmpty && ink.proofs.isEmpty, "one true OR member ends the entire derived source")
    }

    static func projection() {
        let board = empty
        var ink = InkToolState()
        ink.strokes = [mark(0,4,.circle,start:true), mark(9,4,.circle,start:true), mark(80,3,.cross)]
        let or = InkReasoning.previewProjection(state: ink, group: 0, board: board)
        check(or.fills.isEmpty && or.peers.contains(184) && !or.peers.contains(94) &&
              !or.peers.contains(804) && or.removed == [803], "OR only fades common peers, raw cross hidden")
        ink.strokes = [mark(80,5,.circle,start:true),mark(0,3,.circle),mark(0,3,.cross),mark(0,4,.circle)]
        let refuted = InkReasoning.previewProjection(state: ink, group: 0, board: board)
        check(refuted.conflicts == [3,4] && refuted.protected == [3,4,805] && refuted.removed.isEmpty &&
              refuted.fills.isEmpty, "witnesses, starts and touched cells remain candidates")
        ink.strokes = [mark(80,5,.circle,start:true),mark(80,5,.cross,start:true,group:1),
                       mark(10,4,.circle),mark(10,4,.circle,group:1)]
        let common = InkReasoning.previewProjection(state: ink, group: 0, board: board)
        check(common.protected == [805,104] && common.fills.isEmpty, "covered branch roots and common conclusion are protected")
    }

    static func rectangleEvidence() {
        // DoodleUrContradictionProbe's real four corners, with the opposite 7
        // already removed from R5C9. P may use the value swap only after uniqueness.
        let givens = "029001006001900200000072139254000000890024060000000428038210000000005603900400810"
        var board = empty
        board.values = givens.utf8.map { $0 - 48 }
        board.fixed = board.values.map { $0 != 0 }
        for c in 0..<81 where board.values[c] != 0 { board.candidates[c] = 0; board.userCandidates[c] = 0 }
        board.candidates[44] = 17
        var ink = InkToolState()
        ink.strokes = [mark(30,1,.circle), mark(35,7,.circle), mark(39,7,.circle), mark(44,1,.circle,start:true)]
        // The fixture's legal masks matter to the independent local consistency checks.
        for cell in 0..<81 where board.values[cell] == 0 {
            for peer in 0..<81 where board.values[peer] != 0 &&
                    (cell / 9 == peer / 9 || cell % 9 == peer % 9 || cell / 27 == peer / 27 && cell % 9 / 3 == peer % 9 / 3) {
                board.candidates[cell] &= ~NativeBoardSnapshot.bit(board.values[peer])
            }
        }
        check(!InkReasoning.display(ink, group: 0, board: board).strokes.contains(where: \.outlined), "uncertified uniqueness cannot justify a rectangle")
        let cache = InkUniqueness()
        var answered = false
        check(!cache.evidence(for: board, ink: ink) { answered = true }, "uniqueness returns asynchronously")
        let until = Date().addingTimeInterval(4)
        while !answered && Date() < until { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        check(answered && cache.evidence(for: board, ink: ink) {}, "givens alone prove uniqueness despite edited candidates")
        let shown = InkReasoning.display(ink, group: 0, board: board, unique: true)
        check(shown.strokes.filter(\.witness).compactMap(\.cell).sorted() == [30,35,39] &&
              shown.strokes.contains { $0.cell == 44 && $0.digit == 1 && $0.kind == .cross && $0.outlined },
              "unique rectangle has exactly Java's three witnesses and one inverse")
        check(InkReasoning.apply(in: &ink, group: 0, board: &board, unique: true) && board.candidates[44] & 1 == 0,
              "explicit Enter applies rectangle inverse")
        var unrelated = empty
        unrelated.values[0] = 6
        check(!cache.evidence(for: unrelated, ink: ink) {}, "a prior puzzle's uniqueness cannot authorize new givens")
    }

    static func consensusAndCompletion() {
        var board = empty
        var ink = InkToolState()
        ink.strokes = [mark(80,5,.circle,start:true), mark(80,5,.cross,start:true,group:1),
                       mark(0,3,.cross), mark(0,3,.cross,group:1), mark(10,4,.circle), mark(10,4,.circle,group:1)]
        let shown = InkReasoning.display(ink, group: 0, board: board)
        check(shown.strokes.filter(\.outlined).count == 2 &&
              !InkReasoning.apply(in: &ink, group: 2, board: &board), "only exhaustively covered branches authorize their common results")
        check(InkReasoning.apply(in: &ink, group: 0, board: &board) && board.values[10] == 4 &&
              board.candidates[0] & 4 == 0 && ink.strokes.contains { $0.cell == 80 && $0.group == 0 && $0.start }, "consensus result retains live origin")
        let solved = "534678912672195348198342567859761423426853791713924856961537284287419635345286179"
        board = empty
        board.values = solved.utf8.map { $0 - 48 }
        board.fixed = Array(repeating: true, count: 81)
        board.candidates = Array(repeating: 0, count: 81)
        board.userCandidates = Array(repeating: 0, count: 81)
        for cell in [0, 80] {
            board.candidates[cell] = NativeBoardSnapshot.bit(board.values[cell])
            board.values[cell] = 0
            board.fixed[cell] = false
        }
        ink = InkToolState()
        ink.strokes = [mark(0, 5, .circle, start: true), mark(80, 9, .circle)]
        check(InkReasoning.apply(in: &ink, group: 0, board: &board) && !board.values.contains(0), "entire authored completion validates all 27 houses")
    }
}
