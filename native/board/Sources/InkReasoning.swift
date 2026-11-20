// SPDX-License-Identifier: GPL-3.0-or-later
// Port of SudokuPanel's P transactions and Doodle{Contradiction,Completion,Consensus}Basis.
import Foundation

struct InkPreviewProjection: Equatable {
    var fills = [Int: Int]()
    var removed = Set<Int>()
    var conflicts = Set<Int>()
    var peers = Set<Int>()
    var protected = Set<Int>()
}

enum InkReasoning {
    private static let houses = (0..<27).map { NativeHintReference.house($0).cells }

    private static func atom(_ s: InkStroke) -> Int? {
        guard s.kind == .circle || s.kind == .cross, let cell = s.cell, let digit = s.digit,
              (0..<81).contains(cell), (1...9).contains(digit) else { return nil }
        return cell * 10 + digit
    }

    private static func present(_ a: Int, on board: NativeBoardSnapshot, user: Bool = false) -> Bool {
        let cell = a / 10
        let masks = board.candidates[cell] | (user ? board.userCandidates[cell] : 0)
        return board.values[cell] == 0 && masks & NativeBoardSnapshot.bit(UInt8(a % 10)) != 0
    }

    private static func peers(_ a: Int, _ b: Int) -> Bool {
        a != b && (a / 9 == b / 9 || a % 9 == b % 9 || a / 27 == b / 27 && a % 9 / 3 == b % 9 / 3)
    }

    private static func sources(of stroke: InkStroke, in state: InkToolState) -> Set<Int> {
        Set(state.strokes.filter { $0.cell == stroke.cell && $0.digit == stroke.digit && $0.kind == stroke.kind }.map(\.group))
    }

    static func reconcile(_ state: inout InkToolState) {
        for i in state.strokes.indices {
            let stroke = state.strokes[i]
            if !stroke.outlineSources.isEmpty && sources(of: stroke, in: state) != stroke.outlineSources {
                state.strokes[i].outlined = false
                state.strokes[i].outlineSources = []
            }
        }
        for (group, archive) in state.proofs where !state.strokes.contains(where: {
            $0.group == group && InkProofPreview.owns($0, archived: archive)
        }) {
            state.proofs.removeValue(forKey: group)
        }
    }

    static func pruneStale(in state: inout InkToolState, board: NativeBoardSnapshot) {
        let starts = Dictionary(grouping: state.strokes.filter(\.start), by: \.group)
        let satisfied = Set(starts.compactMap { group, members -> Int? in
            guard members.count > 1, members.allSatisfy({ $0.kind == .circle }),
                  members.contains(where: { s in atom(s).map { board.values[$0 / 10] == $0 % 10 } == true }) else { return nil }
            return group
        })
        state.strokes.removeAll { s in
            s.start && satisfied.contains(s.group) || atom(s).map { !present($0, on: board, user: true) } == true
        }
        reconcile(&state)
    }

    @discardableResult
    static func toggleMark(_ stroke: InkStroke, in state: inout InkToolState, board: NativeBoardSnapshot, enteringStart: Bool, unique: Bool = false) -> Bool {
        guard let a = atom(stroke), present(a, on: board), (0..<6).contains(stroke.group) else { return false }
        let group = stroke.group
        func samePosition(_ s: InkStroke) -> Bool { s.group == group && atom(s) == a }
        let matching = state.strokes.indices.filter { samePosition(state.strokes[$0]) && state.strokes[$0].kind == stroke.kind }
        let oppositeStart = state.strokes.contains { $0.group == group && $0.start && $0.kind != stroke.kind &&
            !(enteringStart && matching.isEmpty && samePosition($0)) }
        if enteringStart, let index = matching.last {
            if state.strokes[index].start { state.strokes[index].start = false }
            else if oppositeStart { return false }
            else { state.strokes[index].start = true }
            state.consumedGroups.insert(group)
        } else if !matching.isEmpty {
            state.strokes.removeAll { samePosition($0) && $0.kind == stroke.kind }
        } else {
            let isStart = enteringStart || !state.consumedGroups.contains(group)
            if isStart && oppositeStart { return false }
            if enteringStart { state.strokes.removeAll { samePosition($0) && $0.kind != stroke.kind } }
            else if state.strokes.contains(where: { $0.group == group && $0.cell == stroke.cell && $0.outlined }) { return false }
            var new = stroke
            new.ownsProof = false
            new.start = isStart
            state.strokes.append(new)
            state.consumedGroups.insert(group)
        }
        reconcile(&state)
        cancelSupersededOutlines(&state, board: board, unique: unique)
        return true
    }

    @discardableResult
    static func clearStarts(in state: inout InkToolState, group: Int) -> Bool {
        let marked = state.strokes.indices.filter { state.strokes[$0].group == group && state.strokes[$0].start }
        guard !marked.isEmpty else { return false }
        for index in marked { state.strokes[index].start = false }
        reconcile(&state)
        return true
    }

    @discardableResult
    static func toggleOutline(in state: inout InkToolState, group: Int, cell: Int, digit: Int,
                              kind: InkStroke.Kind? = nil, board: NativeBoardSnapshot, unique: Bool = false) -> Bool {
        guard (0..<81).contains(cell), (1...9).contains(digit), present(cell * 10 + digit, on: board, user: true),
              derived(state, group: group, board: board, unique: unique) == nil else { return false }
        let local = state.strokes.indices.reversed().filter {
            let s = state.strokes[$0]
            return s.cell == cell && s.digit == digit && (kind == nil || s.kind == kind)
        }
        guard let index = local.first(where: { state.strokes[$0].group == group }) ??
                local.first(where: { sources(of: state.strokes[$0], in: state).count > 1 }) else { return false }
        let target = state.strokes[index]
        if target.outlined {
            state.strokes[index].outlined = false
            state.strokes[index].outlineSources = []
            return true
        }
        let active = state.strokes.indices.filter { state.strokes[$0].outlined &&
            (state.strokes[$0].group == group || !state.strokes[$0].outlineSources.isEmpty) }
        guard !active.contains(where: { i in
            let s = state.strokes[i]
            return s.cell == cell && s.digit != digit || (s.kind == .circle && target.kind == .circle &&
                  s.digit == digit && s.cell.map { peers(cell, $0) } == true)
        }) else { return false }
        for i in active where state.strokes[i].cell == cell {
            state.strokes[i].outlined = false
            state.strokes[i].outlineSources = []
        }
        let contributors = sources(of: target, in: state)
        state.strokes[index].outlined = true
        state.strokes[index].outlineSources = contributors.count > 1 ? contributors : []
        return true
    }

    private struct Branch {
        var starts = Set<Int>()
        var startKind: InkStroke.Kind?
        var validStart = true
        var circles = Set<Int>()
        var crosses = Set<Int>()
        var witnesses = Set<Int>()
        var refuted: Bool { validStart && !starts.isEmpty && !witnesses.isEmpty }
    }

    private static func branch(_ strokes: [InkStroke], board: NativeBoardSnapshot, unique: Bool) -> Branch {
        var result = Branch()
        for s in strokes where s.start {
            guard let a = atom(s) else { result.validStart = false; continue }
            if !present(a, on: board) || (result.startKind != nil && result.startKind != s.kind) { result.validStart = false }
            result.starts.insert(a)
            result.startKind = s.kind
        }
        let orGroup = result.validStart && result.startKind == .circle && result.starts.count > 1
        for s in strokes {
            guard let a = atom(s), present(a, on: board) else { continue }
            if s.kind == .cross { result.crosses.insert(a) }
            else if !s.start || !orGroup { result.circles.insert(a) }
        }
        if result.circles.isEmpty && result.crosses.isEmpty { return result }
        result.witnesses = result.circles.intersection(result.crosses)
        for first in result.circles {
            for second in result.circles where second > first && (first / 10 == second / 10 ||
                    first % 10 == second % 10 && peers(first / 10, second / 10)) {
                result.witnesses.formUnion([first, second])
            }
            if board.values.indices.contains(where: { board.values[$0] == UInt8(first % 10) && peers($0, first / 10) }) {
                result.witnesses.insert(first)
            }
        }
        if unique, result.circles.count >= 4 {
            var chosen = [Int: Int]()
            for a in result.circles where board.values[a / 10] == 0 && !board.fixed[a / 10] {
                let cell = a / 10, digit = a % 10
                chosen[cell] = chosen[cell].map { $0 == digit ? digit : -1 } ?? digit
            }
            for (a, first) in chosen where first > 0 {
                for (b, second) in chosen where second > 0 && first != second && b / 9 == a / 9 && b > a {
                    for row in (a / 9 + 1)..<9 where (row / 3 == a / 27) != (b % 9 / 3 == a % 9 / 3) {
                        let c = row * 9 + a % 9, d = row * 9 + b % 9
                        if chosen[c] == second && chosen[d] == first {
                            let corners = Set([a * 10 + first, b * 10 + second, c * 10 + second, d * 10 + first])
                            result.witnesses.formUnion(corners.subtracting(result.starts))
                        }
                    }
                }
            }
        }
        if !result.crosses.isEmpty {
            func testFalse(_ candidates: [Int]) {
                if !candidates.isEmpty && candidates.allSatisfy(result.crosses.contains) { result.witnesses.formUnion(candidates) }
            }
            for c in 0..<81 where board.values[c] == 0 {
                testFalse((1...9).map { c * 10 + $0 }.filter { present($0, on: board) })
            }
            for house in houses {
                for d in 1...9 where !house.contains(where: { board.values[$0] == UInt8(d) }) {
                    testFalse(house.map { $0 * 10 + d }.filter { present($0, on: board) })
                }
            }
            if orGroup && result.starts.isSubset(of: result.crosses) { result.witnesses.formUnion(result.starts) }
        }
        return result
    }

    private struct Conclusions {
        var fills = Set<Int>()
        var removals = Set<Int>()
        var adopt = Set<Int>()
        var origins = Set<Int>()
        var witnesses = Set<Int>()
    }

    private static func resultingBoard(_ conclusions: Conclusions, board: NativeBoardSnapshot) -> NativeBoardSnapshot {
        var result = board
        for a in conclusions.removals where present(a, on: result, user: true) {
            let mask = ~NativeBoardSnapshot.bit(UInt8(a % 10))
            result.candidates[a / 10] &= mask
            result.userCandidates[a / 10] &= mask
        }
        for a in conclusions.fills.sorted() where present(a, on: result, user: true) {
            result.setValue(UInt8(a % 10), at: a / 10)
        }
        return result
    }

    private static func compatible(_ result: Conclusions, board before: NativeBoardSnapshot) -> Bool {
        if !result.fills.isDisjoint(with: result.removals) { return false }
        let after = resultingBoard(result, board: before)
        if result.fills.contains(where: { after.values[$0 / 10] != $0 % 10 }) { return false }
        for c in 0..<81 where before.candidates[c] != 0 && after.values[c] == 0 && after.candidates[c] == 0 { return false }
        for house in houses {
            var seen = Set<UInt8>()
            for c in house where after.values[c] > 0 {
                if !seen.insert(after.values[c]).inserted { return false }
            }
            for d in 1...9 where !seen.contains(UInt8(d)) {
                if house.contains(where: { present($0 * 10 + d, on: before) }) &&
                        !house.contains(where: { present($0 * 10 + d, on: after) }) { return false }
            }
        }
        return true
    }

    private static func derived(_ state: InkToolState, group: Int, board: NativeBoardSnapshot, unique: Bool,
                                includingConsensus: Bool = false) -> Conclusions? {
        let marks = state.strokes.filter { $0.group == group }
        guard marks.contains(where: { $0.start }) else { return nil }
        let current = branch(marks, board: board, unique: unique)
        if current.refuted {
            var result = Conclusions(witnesses: current.witnesses)
            if current.startKind == .circle { result.removals = current.starts }
            else if current.starts.count == 1 { result.fills = current.starts }
            else { result.adopt = current.starts }
            return result
        }
        guard current.validStart, current.witnesses.isEmpty, current.starts.count == 1, let first = current.starts.first else { return nil }
        let completion = Conclusions(fills: current.circles)
        let allCirclesMatch = marks.allSatisfy { s in
            guard s.kind == .circle, let a = atom(s) else { return true }
            return board.values[a / 10] == a % 10 || present(a, on: board)
        }
        let contradictsGiven = marks.contains { s in
            s.kind == .cross && atom(s).map { board.values[$0 / 10] == $0 % 10 } == true
        }
        let isComplete = allCirclesMatch && !contradictsGiven && current.circles.count == board.values.filter({ $0 == 0 }).count &&
            !current.circles.isEmpty && compatible(completion, board: board) &&
            !resultingBoard(completion, board: board).values.contains(0)
        if isComplete && !includingConsensus { return completion }
        var common = Conclusions()
        for other in Set(state.strokes.map(\.group)).subtracting([group]) {
            let b = branch(state.strokes.filter { $0.group == other }, board: board, unique: unique)
            guard b.validStart, b.witnesses.isEmpty, b.starts.count == 1,
                  let second = b.starts.first, first / 10 == second / 10 else { continue }
            let covers = first == second ? current.startKind != b.startKind :
                current.startKind == b.startKind && board.candidates[first / 10].nonzeroBitCount == 2
            if covers {
                let sharedFills = current.circles.intersection(b.circles)
                let sharedDeletions = current.crosses.intersection(b.crosses)
                if !sharedFills.isEmpty || !sharedDeletions.isEmpty { common.origins.formUnion([first, second]) }
                common.fills.formUnion(sharedFills)
                common.removals.formUnion(sharedDeletions)
            }
        }
        if (!common.fills.isEmpty || !common.removals.isEmpty) && compatible(common, board: board) {
            if isComplete { common.fills.formUnion(completion.fills) }
            return common
        }
        return isComplete ? completion : nil
    }

    static func cancelSupersededOutlines(_ state: inout InkToolState, board: NativeBoardSnapshot, unique: Bool) {
        for group in Set(state.strokes.filter(\.outlined).flatMap { [$0.group] + $0.outlineSources }) {
            if derived(state, group: group, board: board, unique: unique) != nil {
                for i in state.strokes.indices where state.strokes[i].group == group || state.strokes[i].outlineSources.contains(group) {
                    state.strokes[i].outlined = false
                    state.strokes[i].outlineSources = []
                }
            }
        }
    }

    static func previewProjection(state: InkToolState, group: Int, board: NativeBoardSnapshot, unique: Bool = false) -> InkPreviewProjection {
        var view = InkPreviewProjection()
        let marks = state.strokes.filter { $0.group == group }
        let branch = branch(marks, board: board, unique: unique)
        view.conflicts = branch.witnesses
        view.protected = branch.witnesses
        if branch.refuted { view.protected.formUnion(branch.starts) }
        else if let known = derived(state, group: group, board: board, unique: unique, includingConsensus: true) {
            view.protected.formUnion(known.fills)
            view.protected.formUnion(known.removals)
            view.protected.formUnion(known.origins)
        }
        let groupedStart = marks.filter(\.start).count > 1 && marks.filter(\.start).allSatisfy { $0.kind == .circle }
        var sources = [[Int]]()
        var alternatives = [Int]()
        var circles = [Int: Set<Int>]()
        for s in marks {
            guard let a = atom(s), present(a, on: board, user: true) else { continue }
            if s.kind == .cross {
                if !view.protected.contains(a) { view.removed.insert(a) }
            } else if s.start && groupedStart {
                alternatives.append(a)
            } else {
                circles[a / 10, default: []].insert(a % 10)
                sources.append([a])
            }
        }
        if !alternatives.isEmpty { sources.append(alternatives) }
        for source in sources {
            let d = source[0] % 10
            guard source.allSatisfy({ $0 % 10 == d }) else { continue }
            for cell in 0..<81 where present(cell * 10 + d, on: board, user: true) &&
                    source.allSatisfy({ peers(cell, $0 / 10) }) {
                view.peers.insert(cell * 10 + d)
            }
        }
        let protectedCells = Set(view.protected.map { $0 / 10 })
        for (cell, digits) in circles where digits.count == 1 && !protectedCells.contains(cell) {
            view.fills[cell] = digits.first
        }
        return view
    }

    static func display(_ state: InkToolState, group: Int, board: NativeBoardSnapshot, unique: Bool = false) -> InkToolState {
        guard let computed = derived(state, group: group, board: board, unique: unique) else { return state }
        var preview = state
        for i in preview.strokes.indices where preview.strokes[i].group == group {
            preview.strokes[i].outlined = false
            if let a = atom(preview.strokes[i]) { preview.strokes[i].witness = computed.witnesses.contains(a) }
        }
        for (targets, kind) in [(computed.fills.union(computed.adopt), InkStroke.Kind.circle), (computed.removals, .cross)] {
            for a in targets.sorted() {
                if let existing = preview.strokes.firstIndex(where: { $0.group == group && atom($0) == a && $0.kind == kind }) {
                    preview.strokes[existing].outlined = true
                } else if var projected = preview.strokes.first(where: { $0.group == group && atom($0) == a }) {
                    projected.kind = kind
                    projected.start = false
                    projected.witness = false
                    projected.outlined = true
                    preview.strokes.append(projected)
                }
            }
        }
        return preview
    }

    /// A P conclusion is evaluated once against the unmodified board. OR adoption
    /// changes only annotations and therefore has no board answer to confirm.
    struct Proposal {
        let ink: InkToolState
        let board: NativeBoardSnapshot
        let step: NativeHintStep?
        let stage: NativeHintStage?
    }

    static func applying(_ atoms: ChainConclusions, to source: NativeBoardSnapshot) -> NativeBoardSnapshot? {
        let changed = resultingBoard(Conclusions(fills: atoms.truths, removals: atoms.falses), board: source)
        return changed == source ? nil : changed
    }

    static func proposal(in input: InkToolState, group: Int, board: NativeBoardSnapshot, unique: Bool) -> Proposal? {
        var state = input
        reconcile(&state)
        let marks = state.strokes.filter { $0.group == group }
        let starts = marks.filter(\.start)
        var result = derived(state, group: group, board: board, unique: unique)
        let manualOutlines = result == nil
        if manualOutlines {
            var manual = Conclusions()
            for s in state.strokes where s.outlined && (s.group == group || !s.outlineSources.isEmpty) {
                guard let a = atom(s), present(a, on: board, user: true) else { continue }
                if s.kind == .cross { manual.removals.insert(a) }
                else if !(s.start && state.strokes.filter({ $0.group == s.group && $0.start }).count > 1) { manual.fills.insert(a) }
            }
            result = manual
        }
        guard let confirmed = result else { return nil }
        if !confirmed.adopt.isEmpty {
            state.proofs[group] = (state.proofs[group] ?? []) + marks
            state.strokes.removeAll { $0.group == group }
            for var s in starts where atom(s).map(confirmed.adopt.contains) == true {
                s.kind = .circle
                s.ownsProof = true
                s.outlined = false
                s.outlineSources = []
                state.strokes.append(s)
            }
            state.consumedGroups.insert(group)
            return Proposal(ink: state, board: board, step: nil, stage: nil)
        }
        let changed = resultingBoard(confirmed, board: board)
        guard changed != board else { return nil }
        pruneStale(in: &state, board: changed)
        state.strokes.removeAll { $0.group == group && !$0.start }
        for i in state.strokes.indices where state.strokes[i].group == group {
            state.strokes[i].outlined = false
            state.strokes[i].outlineSources = []
        }
        if !state.strokes.contains(where: { $0.group == group && $0.start }) { state.consumedGroups.remove(group) }
        reconcile(&state)
        // A fill can make other candidates disappear automatically. Only the
        // explicit conclusions belong to the answer and its linked text.
        let truths = Set(confirmed.fills.filter { board.values[$0 / 10] == 0 && changed.values[$0 / 10] == $0 % 10 })
        let falses = Set(confirmed.removals.filter { present($0, on: board, user: true) })
        let atoms = ChainConclusions(trueAtoms: truths, falseAtoms: falses)
        var refs = [NativeHintReference]()
        var operations = [String]()
        for (targets, removal) in [(truths, false), (falses, true)] {
            for target in targets.sorted() {
                let digit = UInt8(target % 10)
                let ref = NativeHintReference.cell(target / 10, digits: NativeBoardSnapshot.bit(digit), removal: removal)
                refs.append(ref)
                operations.append(ref.label + (removal ? " 排除候选数字 " : " 填入 ") + String(digit))
            }
        }
        let reason: String
        if manualOutlines { reason = "根据已框定的圈叉" }
        else if !confirmed.witnesses.isEmpty { reason = "这组假设产生冲突，反推起点" }
        else if !confirmed.origins.isEmpty { reason = "各个可能分支得出相同结论" }
        else { reason = "当前圈定的数字构成完整解" }
        let stage = NativeHintStage(title: "涂鸦结论", text: reason + "，" + operations.joined(separator: "；") + "。", references: refs)
        let step = NativeHintStep(technique: .userInk, house: nil, digits: refs.reduce(0) { $0 | $1.digits },
            premises: Set(refs.flatMap(\.cells)).sorted(), placementCell: nil, placementDigit: 0,
            deletions: Array(repeating: 0, count: 81), inkConclusions: atoms)
        return Proposal(ink: state, board: changed, step: step, stage: stage)
    }

    @discardableResult
    static func apply(in state: inout InkToolState, group: Int, board: inout NativeBoardSnapshot, unique: Bool = false) -> Bool {
        guard let answer = proposal(in: state, group: group, board: board, unique: unique) else { return false }
        state = answer.ink
        board = answer.board
        return true
    }
}
