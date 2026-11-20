import Foundation
import HodokuEngine

enum NativeHintTechnique: Hashable {
    case fullHouse, nakedSingle, hiddenSingle, lockedPair, lockedTriple, pointing, claiming

    case userChain, userInk
    case logical(String)
    static let prefix: [Self] = [.fullHouse,.nakedSingle,.hiddenSingle,.lockedPair,.lockedTriple,.pointing,.claiming]
    static let prefixKeys = ["FULL_HOUSE","NAKED_SINGLE","HIDDEN_SINGLE","LOCKED_PAIR","LOCKED_TRIPLE","LOCKED_CANDIDATES_1","LOCKED_CANDIDATES_2"]
    init?(rawValue: UInt8) {
        guard (1...7).contains(rawValue) else { return nil }
        self = Self.prefix[Int(rawValue)-1]
    }
    init(key: String) { self = Self.prefixKeys.firstIndex(of:key).map { Self.prefix[$0] } ?? .logical(key) }
    var key: String {
        switch self {
        case let .logical(key): return key
        case .userChain: return "USER_CHAIN"
        case .userInk: return "USER_INK"
        default: return Self.prefixKeys[Self.prefix.firstIndex(of:self)!]
        }
    }
    static let localized: [String:String] = {
        guard let url = Bundle.main.url(forResource:"training-names",withExtension:"json"),
              let data = try? Data(contentsOf:url), let names = try? JSONDecoder().decode([String:String].self,from:data) else { return [:] }
        return names
    }()

    var name: String {
        switch self {
        case let .logical(key): return Self.localized[key] ?? key
        case .userChain: return "自画链"
        case .userInk: return "涂鸦结论"
        case .fullHouse: return "唯一空格"
        case .nakedSingle: return "显性单数"
        case .hiddenSingle: return "隐性单数"
        case .lockedPair: return "锁定数对"
        case .lockedTriple: return "锁定三数组"
        case .pointing: return "锁定候选数 1 型"
        case .claiming: return "锁定候选数 2 型"
        }
    }
}

struct NativeHintStep: Equatable {
    let technique: NativeHintTechnique
    let house: Int?
    let digits: UInt16
    let premises: [Int]
    let placementCell: Int?
    let placementDigit: UInt8
    let deletions: [UInt16]
    var logical: NativeLogicalStep? = nil
    var authoredConclusions: ChainConclusions? = nil
    var inkConclusions: ChainConclusions? = nil

    func applying(to source: NativeBoardSnapshot) -> NativeBoardSnapshot? {
        if let ink = inkConclusions { return InkReasoning.applying(ink, to: source) }
        if let proof = logical { return proof.applying(to: source) }
        guard deletions.count == 81, source.values.count == 81, source.fixed.count == 81,
              source.candidates.count == 81, source.userCandidates.count == 81,
              !premises.isEmpty, premises.allSatisfy({ (0..<81).contains($0) }) else { return nil }
        var result = source
        if let cell = placementCell {
            guard (0..<81).contains(cell), (1...9).contains(placementDigit), !deletions.contains(where: { $0 != 0 }),
                  source.values[cell] == 0, !source.fixed[cell],
                  source.candidates[cell] & NativeBoardSnapshot.bit(placementDigit) != 0 else { return nil }
            result.setValue(placementDigit, at: cell)
        } else {
            guard placementDigit == 0 else { return nil }
            for (cell, mask) in deletions.enumerated() where mask != 0 {
                guard result.values[cell] == 0, result.candidates[cell] & mask == mask else { return nil }
                // SimpleSolver.doStep uses Sudoku2.delCandidate on the ordinary grid.
                result.candidates[cell] &= ~mask
            }
        }
        return result == source ? nil : result
    }
}

enum NativeHintError: LocalizedError {
    case contradiction, engine
    var errorDescription: String? {
        switch self {
        case .contradiction: return "当前数字或候选数有冲突，请检查盘面。"
        case .engine: return "无法读取这一步，请重试。"
        }
    }
}

enum NativeHintEngine {
    static func next(for board: NativeBoardSnapshot) throws -> NativeHintStep? {
        var output = HodokuHintStep()
        let status = hodoku_next_step_v1(board.values, board.values.count, board.candidates, board.candidates.count, &output)
        return try decode(output, status: status)
    }

    static func next(for board: NativeBoardSnapshot, cells: [Int]) throws -> NativeHintStep? {
        guard !cells.isEmpty, cells.count <= 81, cells.allSatisfy({ (0..<81).contains($0) }),
              Set(cells).count == cells.count else { throw NativeHintError.engine }
        var output = HodokuHintStep()
        let selected = cells.map(UInt8.init)
        let status = hodoku_step_for_cells_v1(board.values, board.values.count, board.candidates, board.candidates.count,
                                             selected, selected.count, &output)
        return try decode(output, status: status)
    }

    static func decode(_ output: HodokuHintStep, status: Int32) throws -> NativeHintStep? {
        guard status == 0 else { throw status == 1 ? NativeHintError.contradiction : NativeHintError.engine }
        guard output.technique != 0 else { return nil }
        guard let technique = NativeHintTechnique(rawValue: output.technique), technique != .userChain,
              output.premise_count > 0, output.premise_count <= 9, output.digits > 0, output.digits <= 511,
              output.house < 27 || output.house == 255 else { throw NativeHintError.engine }
        let premises = withUnsafeBytes(of: output.premises) { $0.prefix(Int(output.premise_count)).map(Int.init) }
        let deletions = withUnsafeBytes(of: output.deletions) { Array($0.bindMemory(to: UInt16.self)) }
        let placement = output.placement_cell == 255 ? nil : Int(output.placement_cell)
        guard premises.allSatisfy({ (0..<81).contains($0) }),
              deletions.count == 81, deletions.allSatisfy({ $0 <= 511 }),
              placement.map({ (0..<81).contains($0) && (1...9).contains(output.placement_digit) && !deletions.contains(where: { $0 != 0 }) })
                  ?? (output.placement_digit == 0 && deletions.contains(where: { $0 != 0 })) else { throw NativeHintError.engine }
        switch technique {
        case .fullHouse, .hiddenSingle:
            guard placement != nil, output.house < 27 else { throw NativeHintError.engine }
        case .nakedSingle:
            guard placement != nil else { throw NativeHintError.engine }
        default:
            guard placement == nil, output.house < 27, (0..<27).contains(where: { h in
                (h >= 18) != (output.house >= 18) && premises.allSatisfy(NativeHintReference.house(h).cells.contains)
            }) else { throw NativeHintError.engine }
        }
        return NativeHintStep(technique: technique, house: output.house == 255 ? nil : Int(output.house),
                              digits: output.digits, premises: premises, placementCell: placement,
                              placementDigit: output.placement_digit, deletions: deletions)
    }
}

struct NativeHintReference: Equatable {
    let label: String
    let cells: [Int]
    var digits: UInt16 = 0
    var removal = false

    static func cell(_ cell: Int, digits: UInt16 = 0, removal: Bool = false) -> Self {
        Self(label: "R\(cell / 9 + 1)C\(cell % 9 + 1)", cells: [cell], digits: digits, removal: removal)
    }

    static func house(_ index: Int) -> Self {
        let kind = index / 9
        let n = index % 9
        let label = ["行", "列", "宫"][kind]
        let cells = (0..<81).filter { cell in
            switch kind {
            case 0: return cell / 9 == n
            case 1: return cell % 9 == n
            default: return cell / 27 * 3 + cell % 9 / 3 == n
            }
        }
        return Self(label: "第\(n + 1)\(label)", cells: cells)
    }
}

struct NativeHintStage {
    struct Definition {
        let term: String
        let textRange: NSRange
        let sectionRange: NSRange
    }

    let title: String
    let text: String
    let definition: Definition?
    let references: [NativeHintReference]
    let textLinks: [(NSRange, Int)]

    init(title: String, text: String, references source: [NativeHintReference], definition: Definition? = nil) {
        self.title = title
        self.text = text
        self.definition = definition
        let body = text as NSString
        var occurrences = [(range: NSRange, reference: NativeHintReference)]()
        // A repeated cell can identify different candidates in an authored chain.
        // Consume the supplied references in occurrence order for a shared label.
        for (label, choices) in Dictionary(grouping: source, by: \.label) where !label.isEmpty {
            var offset = 0, occurrence = 0
            while offset < body.length {
                let hit = body.range(of: label, options: [], range: NSRange(location: offset, length: body.length - offset))
                guard hit.location != NSNotFound else { break }
                occurrences.append((hit, choices[min(occurrence, choices.count - 1)]))
                offset = NSMaxRange(hit)
                occurrence += 1
            }
        }
        occurrences.sort { $0.range.location != $1.range.location ? $0.range.location < $1.range.location : $0.range.length > $1.range.length }
        var refs = [NativeHintReference]()
        var links = [(NSRange, Int)]()
        var run = [NativeHintReference]()
        var start = 0, end = 0
        // SudokuReferenceParser.previewSequence appends the whole enumeration
        // after its individual members. Its synthetic union is keyboard-only.
        func finishRun() {
            if run.count > 1 {
                let label = body.substring(with: NSRange(location: start, length: end - start))
                refs.append(.init(label: label, cells: Set(run.flatMap(\.cells)).sorted()))
            }
            run.removeAll()
        }
        for occurrence in occurrences where occurrence.range.location >= end {
            let ref = occurrence.reference
            let gap = body.substring(with: NSRange(location: end, length: occurrence.range.location - end))
                .trimmingCharacters(in: .whitespaces).lowercased()
            let kind = ref.label.hasPrefix("R") ? "cell" : String(ref.label.suffix(1))
            let preceding = run.last.map { $0.label.hasPrefix("R") ? "cell" : String($0.label.suffix(1)) }
            if preceding != kind || !["、", ",", "，", "及", "与", "和", "and"].contains(gap) { finishRun() }
            if run.isEmpty { start = occurrence.range.location }
            links.append((occurrence.range, refs.count))
            refs.append(ref)
            run.append(ref)
            end = NSMaxRange(occurrence.range)
        }
        finishRun()
        references = refs
        textLinks = links
    }
}

struct NativeHintReading {
    let id = UUID()
    let source: NativeBoardSnapshot
    let step: NativeHintStep
    let stages: [NativeHintStage]
    let answerDiagram: BoardAnswerDiagram
    var index = 0
    var current: NativeHintStage { stages[index] }
    var isFinal: Bool { index == stages.count - 1 }

    // Keep authorship and execution on the live session. This copy supplies only
    // the old reading position and the exact set of still outstanding deletions.
    func remainingProof(on board: NativeBoardSnapshot) -> NativeLogicalStep? {
        guard var proof = step.logical, !proof.deletes.isEmpty else { return nil }
        for target in proof.deletes where board.values[target.cell] == target.digit { return nil }
        let pending = proof.deletes.filter { target in
            board.values[target.cell] == 0 && board.candidates[target.cell] & NativeBoardSnapshot.bit(target.digit) != 0
        }
        guard !pending.isEmpty, pending.count < proof.deletes.count else { return nil }
        proof.deletes = pending
        return proof
    }

    func revalidated(on board: NativeBoardSnapshot, config: NativeSolverConfig,
                     cancelled: () -> Bool) throws -> NativeHintAnswer? {
        let fixedProofFamilies = ["NAKED_PAIR","NAKED_TRIPLE","NAKED_QUADRUPLE","HIDDEN_PAIR","HIDDEN_TRIPLE",
            "HIDDEN_QUADRUPLE","LOCKED_PAIR","LOCKED_TRIPLE","LOCKED_CANDIDATES_1","LOCKED_CANDIDATES_2",
            "X_WING","SWORDFISH","JELLYFISH"]
        guard let expected = remainingProof(on:board), fixedProofFamilies.contains(expected.kind) else { return nil }
        let result = try NativeLogicalEngine.rate(board,config:config,only:expected.kind,catalogue:true,cancelled:cancelled)
        guard let verified = result.steps.first(where: { $0 == expected }) else { return nil }
        let next = NativeHintReading(step:verified.hint(),source:board)
        guard next.stages.indices.contains(index) else { return nil }
        for n in 0...index {
            guard stages[n].title == next.stages[n].title, stages[n].references == next.stages[n].references,
                  (n == stages.count - 1) == (n == next.stages.count - 1) else { return nil }
        }
        return .step(next.step, stages:next.stages, index:index)
    }

    /// FineHintSession limits early stages to disclosed text. At the final
    /// stage MainFrame.StepFootprint uses actual premises and conclusions.
    var wholeReferences: [NativeHintReference] {
        guard isFinal else { return current.references }
        if step.inkConclusions != nil { return current.references.filter { $0.cells.count == 1 } }
        let cells = Set(step.premises + step.deletions.indices.filter { step.deletions[$0] != 0 } +
                        (step.placementCell.map { [$0] } ?? []))
        return cells.sorted().map { cell in
            if step.deletions[cell] != 0 { return .cell(cell, digits: step.deletions[cell], removal: true) }
            return .cell(cell, digits: source.candidates[cell] & step.digits)
        }
    }

    init(step: NativeHintStep, source: NativeBoardSnapshot, stages supplied: [NativeHintStage]? = nil) {
        self.source = source
        self.step = step
        self.answerDiagram = BoardAnswerDiagram(step: step, board: source)
        if let stages = supplied, !stages.isEmpty { self.stages = stages; return }
        if let proof = step.logical { self.stages = proof.stages(source); return }
        let cell = step.premises[0]
        let unit = step.house.map(NativeHintReference.house)
        let columnBand = step.house.map { (9..<18).contains($0) } ?? false
        let band = columnBand ? cell % 9 / 3 : cell / 27
        let area = NativeHintReference(label: "第\(band + 1)大" + (columnBand ? "列" : "行"),
                                       cells: (0..<81).filter { (columnBand ? $0 % 9 / 3 : $0 / 27) == band })
        var result = [NativeHintStage(title: "观察范围", text: "先观察\(area.label)。", references: [area])]
        let digits = Self.digits(step.digits)
        let group = step.premises.map { NativeHintReference.cell($0, digits: source.candidates[$0] & step.digits) }
        let labels = group.map(\.label).joined(separator: "、")
        var reason: String
        var finalRefs: [NativeHintReference]
        if let placed = step.placementCell {
            let position = NativeHintReference.cell(placed)
            switch step.technique {
            case .fullHouse:
                result.append(.init(title: "观察单元", text: "\(unit!.label)只剩一个空格。", references: [unit!]))
                reason = "\(unit!.label)只剩 \(position.label) 为空格，其余八个数字各不相同，缺少 \(digits)。"
                finalRefs = [unit!, position]
            case .hiddenSingle:
                result.append(.init(title: "观察落点", text: "在\(unit!.label)中找候选数字 \(digits) 还能放在哪里。", references: [unit!]))
                reason = "候选数字 \(digits) 在\(unit!.label)中仅出现在 \(position.label)。"
                finalRefs = [unit!, position]
            default:
                result.append(.init(title: "观察位置", text: "检查 \(position.label) 当前还剩哪些候选。", references: [position]))
                reason = "\(position.label) 只剩候选数字 \(digits)。"
                finalRefs = [position]
            }
            reason += "因此 \(position.label) 填入 \(digits)。"
        } else {
            let house = unit!
            let other = (0..<27).filter { ($0 >= 18) != (step.house! >= 18) }.map(NativeHintReference.house)
                .first { candidate in step.premises.allSatisfy { candidate.cells.contains($0) } }!
            if step.technique == .lockedPair || step.technique == .lockedTriple {
                result.append(.init(title: "观察起点", text: "在\(house.label)中，\(group[0].label) 的候选为 \(Self.digits(source.candidates[cell]))。", references: [house, group[0]]))
                reason = "\(labels) 共同位于\(house.label)和\(other.label)，这 \(group.count) 格的候选合在一起只有 \(digits)。"
                result.append(.init(title: "完整格组", text: reason, references: group + [house, other]))
                reason += "这些数字必定占据这组格，两个单元中的其他格均可排除相应候选。"
            } else {
                result.append(.init(title: "观察数字", text: "观察候选数字 \(digits)。", references: []))
                reason = "数字 \(digits) 在\(house.label)的全部落点 \(labels) 都位于\(other.label)。"
                result.append(.init(title: "观察交集", text: reason, references: [house] + group + [other]))
                reason += "\(other.label) 中交集以外的格均可排除该数字。"
            }
            let removals = step.deletions.indices.filter { step.deletions[$0] != 0 }.map {
                NativeHintReference.cell($0, digits: step.deletions[$0], removal: true)
            }
            reason += "\n删除 " + removals.map { "\($0.label) 的 \(Self.digits($0.digits))" }.joined(separator: "，") + "。"
            finalRefs = group + [house, other] + removals
        }
        result.append(.init(title: step.technique.name, text: reason, references: finalRefs))
        stages = result
    }

    private static func digits(_ mask: UInt16) -> String {
        (1...9).filter { mask & NativeBoardSnapshot.bit(UInt8($0)) != 0 }.map(String.init).joined(separator: "、")
    }
}
