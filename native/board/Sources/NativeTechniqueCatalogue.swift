import Foundation
import HodokuEngine

private final class CollectedHints {
    var steps = [NativeHintStep]()
    var error: Error?
}

extension NativeHintEngine {
    static func catalogue(for board: NativeBoardSnapshot) throws -> [NativeHintStep] {
        let list = CollectedHints()
        let status = hodoku_hint_catalog_v1(board.values, board.values.count, board.candidates, board.candidates.count,
            { context, pointer in
                guard let context = context, let pointer = pointer else { return }
                let list = Unmanaged<CollectedHints>.fromOpaque(context).takeUnretainedValue()
                do {
                    guard let step = try NativeHintEngine.decode(pointer.pointee, status: 0) else { throw NativeHintError.engine }
                    list.steps.append(step)
                } catch { list.error = error }
            }, Unmanaged.passUnretained(list).toOpaque())
        guard status == 0 else { throw status == 1 ? NativeHintError.contradiction : NativeHintError.engine }
        if let error = list.error { throw error }
        return list.steps
    }
}

/// A choice made after the source selection, filters, or annotations changed
/// must never adopt an instance computed for the previous input.
struct CurrentReasoningInput: Equatable {
    let board: NativeBoardSnapshot
    let boxes: Set<Int>
    let chains: ChainToolState
    let marks: [BoardMark]
    let selection: Set<Int>
    let digits: UInt16

    func agrees(with solution: [UInt8]) -> Bool {
        guard solution.count == board.values.count else { return false }
        return solution.indices.allSatisfy { i in
            let value = solution[i]
            guard (1...9).contains(value) else { return false }
            return board.values[i] == 0
                ? board.candidates[i] & NativeBoardSnapshot.bit(value) != 0
                : board.values[i] == value
        }
    }

    private func roles(_ step: NativeHintStep) -> Set<Int> {
        var premise = Set<Int>(), conclusion = Set<Int>()
        func record(_ cell: Int, _ digit: UInt8) {
            if board.values.indices.contains(cell), (1...9).contains(digit),
               board.candidates[cell] & NativeBoardSnapshot.bit(digit) != 0 { premise.insert(cell * 10 + Int(digit)) }
        }
        for (cell, mask) in step.deletions.enumerated() where mask != 0 {
            for digit in 1...9 where mask & NativeBoardSnapshot.bit(UInt8(digit)) != 0 { conclusion.insert(cell * 10 + digit) }
        }
        if let proof = step.logical {
            if proof.deletes.isEmpty, !proof.values.isEmpty {
                for (i, cell) in proof.indices.enumerated() {
                    conclusion.insert(cell * 10 + Int(proof.values[min(i, proof.values.count - 1)]))
                }
            }
            if NativeFineHints.indexedPremises.contains(proof.kind) || NativeFineHints.fish(proof.kind)
                || NativeFineHints.rectangle(proof.kind) || ["DUAL_TWO_STRING_KITE","DUAL_EMPTY_RECTANGLE"].contains(proof.kind) {
                for c in proof.indices { for d in proof.values { record(c, d) } }
            }
            for x in proof.fins + proof.endoFins { record(x.cell, x.digit) }
            for c in proof.colors.keys { for d in proof.values { record(c, d) } }
            for (cells, ds) in zip(proof.alsCells, proof.alsDigits) {
                for c in cells { for d in ds { record(c, UInt8(d)) } }
            }
            for chain in proof.chains {
                for (ref, _) in proof.nodes(chain) {
                    for c in ref.cells { for d in UInt8(1)...9 where ref.digits & NativeBoardSnapshot.bit(d) != 0 { record(c, d) } }
                }
            }
        } else {
            if let c = step.placementCell { conclusion.insert(c * 10 + Int(step.placementDigit)) }
            if step.technique == .userChain {
                for path in chains.paths { for node in path.nodes { premise.formUnion(node.atoms) } }
            } else if step.placementCell == nil {
                for c in step.premises { for d in UInt8(1)...9 where step.digits & NativeBoardSnapshot.bit(d) != 0 { record(c, d) } }
            }
        }
        return premise.union(conclusion)
    }

    func overlaps(_ step: NativeHintStep, kind: NativeHintMatchInput.Kind) -> Bool {
        let atoms = roles(step)
        switch kind {
        case .boxes:
            return atoms.contains { boxes.contains($0 / 10) }
        case .chain:
            return chains.paths.contains { path in path.nodes.contains { !atoms.isDisjoint(with: $0.atoms) } }
        case .digits:
            return atoms.contains { digits & NativeBoardSnapshot.bit(UInt8($0 % 10)) != 0 }
        }
    }
}

/// Catalogue ordinals are assigned before filtering or ranking. Equal proofs may
/// be returned more than once, so a step's value cannot identify its ordinal.
struct NativeTechniqueInstance {
    let sourceID: UUID
    let number: Int
    let total: Int
    let step: NativeHintStep
    let cells: [Int]
    let score: Double

    init(sourceID: UUID, number: Int, total: Int, step: NativeHintStep, input: CurrentReasoningInput) {
        self.sourceID = sourceID
        self.number = number
        self.total = total
        self.step = step
        var targets = Set(step.premises)
        var atoms = Set<Int>()
        var links = Set<Set<Int>>()
        func record(_ cell: Int, _ digit: UInt8) {
            targets.insert(cell)
            atoms.insert(cell * 10 + Int(digit))
        }
        func visible(_ cell: Int, _ digit: UInt8) {
            if input.board.candidates[cell] & NativeBoardSnapshot.bit(digit) != 0 { record(cell, digit) }
        }
        func link(_ a: Int, _ b: Int, strong: Bool) -> Set<Int> { [a, b, strong ? -1 : -2] }
        if let proof = step.logical {
            for c in proof.indices + Array(proof.colors.keys) { for d in proof.values { visible(c, d) } }
            for x in proof.deletes + proof.fins + proof.endoFins + proof.cannibalistic { record(x.cell, x.digit) }
            for (cs, ds) in zip(proof.alsCells, proof.alsDigits) {
                for c in cs { for d in ds { visible(c, UInt8(d)) } }
            }
            for chain in proof.chains {
                var previous: Int?
                for entry in chain {
                    if entry == .min { previous = nil; continue }
                    let raw = Int(abs(entry)), cell = (raw >> 5) & 127, d = raw & 15
                    guard cell < 81, (1...9).contains(d) else { continue }
                    record(cell, UInt8(d))
                    if ((raw >> 26) & 3) == 1 {
                        for c in [(raw >> 12) & 127, (raw >> 19) & 127] where c < 81 { record(c, UInt8(d)) }
                    }
                    let atom = cell * 10 + d
                    if let previous = previous, entry >= 0 { links.insert(link(previous, atom, strong: raw & 16 != 0)) }
                    previous = atom
                }
            }
        } else {
            for c in step.premises {
                for d in UInt8(1)...9 where step.digits & NativeBoardSnapshot.bit(d) != 0 { visible(c, d) }
            }
            for (c, mask) in step.deletions.enumerated() where mask != 0 {
                for d in UInt8(1)...9 where mask & NativeBoardSnapshot.bit(d) != 0 { record(c, d) }
            }
        }
        if let c = step.placementCell { targets.insert(c) }
        cells = targets.sorted()
        let colored = input.marks.filter { $0.digit == 0 }.map(\.cell)
        let coloredAtoms = input.marks.filter { $0.digit != 0 }.map { $0.cell * 10 + $0.digit }
        let chainAtoms = input.chains.paths.flatMap { $0.nodes.flatMap(\.atoms) }
        var drawnLinks = Set<Set<Int>>()
        for path in input.chains.paths {
            for (i, edge) in path.edges.enumerated() {
                let (a, b) = path.endpoints(i)
                if a.atoms.count == 1, b.atoms.count == 1 { drawnLinks.insert(link(a.atoms[0], b.atoms[0], strong: edge.strong)) }
            }
        }
        let chainScore = 18 * links.intersection(drawnLinks).count + 12 * atoms.intersection(chainAtoms).count
        let colorScore = 8 * atoms.intersection(coloredAtoms).count + 3 * targets.intersection(colored).count
        score = Double(chainScore + colorScore + targets.intersection(input.selection).count) / sqrt(Double(max(1, cells.count)))
    }
}

struct NativeTechniqueRelation {
    let kind: NativeHintMatchInput.Kind
    let source: String
    let matching: Bool

    var label: String { (matching ? "匹配 " : "相关 ") + source }
}

final class NativeTechniqueCatalogue {
    private struct BoardCatalogue {
        let board: NativeBoardSnapshot
        let config: NativeSolverConfig
        let steps: [NativeHintTechnique: [NativeHintStep]]
    }
    private struct ResultSet {
        let steps: [NativeHintTechnique: [NativeHintStep]]
        let matched: [[NativeHintStep]]
        let boardCatalogue: BoardCatalogue?
    }

    private let queue: DispatchQueue
    private let prepared: NativePreparedHints
    private var operation: BlockOperation?
    private var cachedBoard: BoardCatalogue?
    private(set) var sourceID = UUID()
    private var numbered = [NativeHintTechnique: [NativeTechniqueInstance]]()
    private var matched = [[NativeHintStep]]()
    private(set) var context: CurrentReasoningInput?
    private(set) var scope: NativeHintMatchInput?
    private(set) var scopes = [NativeHintMatchInput]()
    private(set) var instances = [NativeHintTechnique: [NativeHintStep]]()
    private(set) var preferredOrder = [NativeHintTechnique]()
    private(set) var error: String?
    private(set) var pending = false
    var previewCells: [Int]?
    var source: NativeBoardSnapshot? { context?.board }

    init(queue: DispatchQueue, prepared: NativePreparedHints = NativePreparedHints()) {
        self.queue = queue
        self.prepared = prepared
    }

    func open(_ input: CurrentReasoningInput, config: NativeSolverConfig, scopes: [NativeHintMatchInput],
              changed: @escaping () -> Void) {
        clear()
        context = input
        self.scopes = scopes
        pending = true
        let cached = cachedBoard.flatMap { $0.board == input.board && $0.config == config ? $0 : nil }
        let prepared = self.prepared
        let task = BlockOperation()
        operation = task
        task.addExecutionBlock { [weak self, weak task] in
            guard let task, !task.isCancelled else { return }
            let cancelled = { task.isCancelled }
            let response = Result {
                let started = DispatchTime.now().uptimeNanoseconds
                let base = try cached ?? BoardCatalogue(board: input.board, config: config,
                    steps: Self.search(input.board, config: config, cancelled: cancelled))
                let matches = try scopes.map { scope in
                    try prepared.steps(scope, on: input.board, config: config, firstOnly: false, cancelled: cancelled)
                }
                let enabled = Set(config.rules.filter(\.enabled).flatMap { NativeFineHints.types($0.kind) })
                var groups = base.steps
                for step in matches.joined() where Self.isEnabled(step.technique, in: enabled) {
                    if cancelled() { throw CancellationError() }
                    if !(groups[step.technique] ?? []).contains(step) {
                        groups[step.technique, default: []].append(step)
                    }
                }
                // The unscoped catalogue predates scoped memoization. Keep at most one
                // reusable catalogue, and only within the same proof-size allowance.
                let reusable = cached != nil || Self.fitsCache(base.steps)
                NativeSearchDiagnostics.record("catalogue", counts: ["baseHit": cached == nil ? 0 : 1,
                    "retained": reusable ? 1 : 0, "scopes": scopes.count, "steps": groups.values.reduce(0) { $0 + $1.count },
                    "cancelled": cancelled() ? 1 : 0], elapsedMS: Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)
                return ResultSet(steps: groups, matched: matches, boardCatalogue: reusable ? base : nil)
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.operation === task else { return }
                changed()
                self.operation = nil
                self.pending = false
                switch response {
                case .success(let result):
                    self.instances = result.steps
                    self.matched = result.matched
                    self.cachedBoard = result.boardCatalogue
                case .failure(let error):
                    self.error = error.localizedDescription
                }
            }
        }
        queue.async { task.start() }
    }

    func showMatches(_ steps: [NativeHintStep], input: CurrentReasoningInput, scope: NativeHintMatchInput) {
        clear()
        context = input
        self.scope = scope
        instances = Dictionary(grouping: steps, by: \.technique)
        var seen = Set<NativeHintTechnique>()
        preferredOrder = steps.map(\.technique).filter { seen.insert($0).inserted }
    }

    private static func isEnabled(_ technique: NativeHintTechnique, in kinds: Set<String>) -> Bool {
        let key = technique.key
        return kinds.contains(key) ||
            (key.hasPrefix("SIMPLE_COLORS_") && kinds.contains("SIMPLE_COLORS")) ||
            (key.hasPrefix("MULTI_COLORS_") && kinds.contains("MULTI_COLORS"))
    }

    static func fitsCache(_ groups: [NativeHintTechnique: [NativeHintStep]]) -> Bool {
        var bytes = 0
        for group in groups.values {
            for step in group {
                bytes += step.estimatedPreparedBytes
                if bytes > NativePreparedHints.defaultByteLimit { return false }
            }
        }
        return true
    }

    private static func search(_ board: NativeBoardSnapshot, config: NativeSolverConfig, cancelled: () -> Bool)
        throws -> [NativeHintTechnique: [NativeHintStep]] {
        let excluded: Set<String> = ["GIVE_UP", "INCOMPLETE", "BRUTE_FORCE"]
        let enabled = Set(config.rules.filter(\.enabled).flatMap { NativeFineHints.types($0.kind) }).subtracting(excluded)
        let prefix = Set(NativeHintTechnique.prefixKeys)
        let basic = try NativeHintEngine.catalogue(for: board)
        var groups = Dictionary(grouping: basic.filter {
            enabled.contains($0.technique.key) && $0.applying(to: board) != nil
        }, by: \.technique)
        // The table solver builds the same graph for each subtype, then filters the
        // ordered family result. Enumerate a family once and retain each subtype's order.
        var queries = Dictionary(uniqueKeysWithValues: enabled.subtracting(prefix).map { ($0, Set([$0])) })
        for family in ["NICE_LOOP", "GROUPED_NICE_LOOP", "FORCING_CHAIN", "FORCING_NET"] {
            let members = enabled.intersection(NativeFineHints.types(family))
            guard members.count > 1, config.rules.filter({ $0.kind == family }).count <= 1 else { continue }
            for member in members { queries.removeValue(forKey: member) }
            queries[family] = members
        }
        for (kind, accepted) in queries.sorted(by: { $0.key < $1.key }) {
            if cancelled() { return [:] }
            let catalogue = try NativeLogicalEngine.rate(board, config: config, only: kind,
                                                         catalogue: true, cancelled: cancelled)
            // The find-all fish settings can exclude an enabled solver technique.
            let proofs = try catalogue.steps.isEmpty && NativeFineHints.fish(kind) && !cancelled()
                ? NativeLogicalEngine.rate(board, config: config, firstOnly: true, only: kind, cancelled: cancelled).steps
                : catalogue.steps
            for proof in proofs {
                if cancelled() { return [:] }
                let step = proof.hint()
                // Queries may include siblings disabled by the current policy.
                if isEnabled(step.technique, in: accepted), step.applying(to: board) != nil {
                    groups[step.technique, default: []].append(step)
                }
            }
        }
        return groups
    }

    func relations(for steps: [NativeHintStep], input: CurrentReasoningInput,
                   currentScopes: [NativeHintMatchInput]) -> [NativeTechniqueRelation] {
        guard scope == nil, !steps.isEmpty else { return [] }
        let sources: [(NativeHintMatchInput.Kind, String, Bool)] = [
            (.boxes, "选框", !input.boxes.isEmpty),
            (.chain, "自由链", !input.chains.paths.isEmpty),
            (.digits, "数字 " + NativeBoardStatus.digits(input.digits), input.digits != 0)
        ]
        return sources.compactMap { kind, label, present in
            guard present else { return nil }
            let strict = currentScopes.first { $0.kind == kind }
            if let strict, let index = scopes.firstIndex(of: strict), matched.indices.contains(index),
               steps.contains(where: matched[index].contains) {
                return NativeTechniqueRelation(kind: kind, source: label, matching: true)
            }
            if steps.contains(where: { input.overlaps($0, kind: kind) }) {
                return NativeTechniqueRelation(kind: kind, source: label, matching: false)
            }
            return nil
        }
    }

    func numberedInstances(_ kind: NativeHintTechnique) -> [NativeTechniqueInstance] {
        guard let steps = instances[kind], let context else { return [] }
        if let cached = numbered[kind] { return cached }
        let rows = steps.enumerated().map { offset, step in
            NativeTechniqueInstance(sourceID: sourceID, number: offset + 1, total: steps.count, step: step, input: context)
        }
        let sorted = scope == nil ? rows.sorted {
            $0.score == $1.score ? $0.number < $1.number : $0.score > $1.score
        } : rows
        numbered[kind] = sorted
        return sorted
    }

    func owns(_ row: NativeTechniqueInstance) -> Bool {
        guard row.sourceID == sourceID, let original = instances[row.step.technique],
              original.indices.contains(row.number - 1) else { return false }
        return original.count == row.total && original[row.number - 1] == row.step
    }

    func discardCachedBoard() { cachedBoard = nil }

    func clear() {
        operation?.cancel()
        operation = nil
        context = nil
        scope = nil
        scopes.removeAll()
        sourceID = UUID()
        numbered.removeAll()
        matched.removeAll()
        preferredOrder.removeAll()
        pending = false
        previewCells = nil
        error = nil
        instances.removeAll()
    }
}
