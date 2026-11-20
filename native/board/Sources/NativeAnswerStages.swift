// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Progressive readings for BasicHintStrategy's naked subsets, kite and turbot.
/// House numbers and encoded chain directions come from the validated Rust step.
extension NativeLogicalStep {
    func basicAnswerStages(on board: NativeBoardSnapshot) -> [NativeHintStage]? {
        let subsetSizes = ["NAKED_PAIR": 2, "NAKED_TRIPLE": 3, "NAKED_QUADRUPLE": 4]
        guard subsetSizes[kind] != nil || kind == "TWO_STRING_KITE" || kind == "TURBOT_FISH",
              !deletes.isEmpty, deletes.allSatisfy({ board.candidates[$0.cell] & NativeBoardSnapshot.bit($0.digit) != 0 })
        else { return nil }

        typealias Ref = NativeHintReference
        typealias Stage = NativeHintStage
        let houses = (0..<27).map(Ref.house)
        func common(_ cells: [Int]) -> [Int] {
            houses.indices.filter { house in cells.allSatisfy(houses[house].cells.contains) }
        }
        func region(_ house: Int) -> Ref {
            let band = (house % 9) / 3, column = (9..<18).contains(house)
            return Ref(label: "第\(band + 1)大" + (column ? "列" : "行"),
                       cells: (0..<81).filter { (column ? $0 % 9 / 3 : $0 / 27) == band })
        }
        func opening(_ ref: Ref) -> Stage {
            Stage(title: "观察范围", text: "先观察\(ref.label)。", references: [ref])
        }
        func labels(_ refs: [Ref]) -> String { refs.map(\.label).joined(separator: "、") }
        func stageWithDefinition(_ title: String, _ text: String, term: String, explanation: String,
                                 references: [Ref], notation: String = "") -> Stage {
            let prefix = text + "\n\n"
            let definition = term + "：" + explanation
            let body = prefix + definition
            let start = text.utf16.count
            let textRange = NSRange(location: prefix.utf16.count, length: definition.utf16.count)
            let sectionRange = NSRange(location: start, length: NSMaxRange(textRange) - start)
            return Stage(title: title, text: body + notation, references: references,
                         definition: .init(term: term, textRange: textRange, sectionRange: sectionRange))
        }
        let cuts = deletes.map { Ref.cell($0.cell, digits: NativeBoardSnapshot.bit($0.digit), removal: true) }
        let targets = zip(cuts, deletes).map { "\($0.0.label) 的候选数字 \($0.1.digit)" }.joined(separator: "，")
        let cutText = "因此删除" + targets + "。"
        let notationEnd = " ⇒ " + zip(cuts, deletes).map { "\($0.0.label)≠\($0.1.digit)" }.joined(separator: "，")

        if let n = subsetSizes[kind] {
            let mask = values.reduce(UInt16(0)) { $0 | NativeBoardSnapshot.bit($1) }
            let shared = common(indices)
            guard indices.count == n, Set(indices).count == n, mask.nonzeroBitCount == n,
                  indices.reduce(UInt16(0), { $0 | board.candidates[$1] }) == mask,
                  let firstHouse = shared.first, let first = indices.first,
                  deletes.allSatisfy({ cut in !indices.contains(cut.cell) && values.contains(cut.digit)
                      && shared.contains(where: { houses[$0].cells.contains(cut.cell) }) })
            else { return nil }
            let places = indices.map { Ref.cell($0, digits: board.candidates[$0]) }
            let units = shared.map { houses[$0] }
            let digits = values.sorted().map(String.init).joined(separator: "、")
            let firstDigits = (1...9).filter { board.candidates[first] & NativeBoardSnapshot.bit(UInt8($0)) != 0 }
                .map(String.init).joined(separator: "、")
            let structure = "\(labels(places)) 同在\(labels(units))。这 \(n) 格的候选合在一起只有 \(digits)。"
            let definition = "同一行、列或宫内，若 n 个未填格的候选合起来恰有 n 种数字，这些数字就被限定在这 n 个格内。"
            let notation = "\n\n{" + digits + "} 位于 " + labels(places) + notationEnd
            return [
                opening(region(firstHouse)),
                Stage(title: "观察起点", text: "\(units[0].label)中，\(places[0].label) 的候选为 \(firstDigits)。", references: [units[0], places[0]]),
                stageWithDefinition("完整格组", structure, term: "显性数组", explanation: definition, references: places + units),
                stageWithDefinition("完整理由与结果", structure + "这 \(n) 格必须用完这 \(n) 个数字，同一单元内的其他格不能再用它们。" + cutText,
                                    term: "显性数组", explanation: definition, references: places + units + cuts + cuts, notation: notation)
            ]
        }

        guard values.count == 1, let digit = values.first, deletes.allSatisfy({ $0.digit == digit }) else { return nil }
        let bit = NativeBoardSnapshot.bit(digit)
        func conjugate(_ a: Int, _ b: Int, in unit: Int) -> Bool {
            let group = houses[unit].cells
            return !group.contains { board.values[$0] == digit }
                && Set(group.filter { board.candidates[$0] & bit != 0 }) == Set([a,b])
        }
        let kite = kind == "TWO_STRING_KITE"
        let path: [Int]
        let firstHouse, secondHouse, middleHouse: Int
        if kite {
            guard indices.count == 4 else { return nil }
            path = [indices[0], indices[2], indices[3], indices[1]]
            firstHouse = path[0] / 9
            secondHouse = 9 + path[3] % 9
            middleHouse = 18 + path[1] / 27 * 3 + path[1] % 9 / 3
            guard houses[middleHouse].cells.contains(path[2]) else { return nil }
        } else {
            guard chains.count == 1, let chain = chains.first, chain.count == 4,
                  chain.allSatisfy({ $0 >= 0 && $0 >> 26 == 0 && $0 & 15 == Int32(digit) }),
                  chain[1] & 16 != 0, chain[2] & 16 == 0, chain[3] & 16 != 0
            else { return nil }
            path = chain.map { Int($0 >> 5) & 127 }
            guard path.allSatisfy(board.values.indices.contains),
                  let first = common(Array(path[0...1])).first(where: { conjugate(path[0], path[1], in: $0) }),
                  let second = common(Array(path[2...3])).first(where: { conjugate(path[2], path[3], in: $0) }),
                  let middle = common(Array(path[1...2])).first else { return nil }
            (firstHouse, secondHouse, middleHouse) = (first, second, middle)
        }
        guard Set(path).count == 4, conjugate(path[0], path[1], in: firstHouse), conjugate(path[2], path[3], in: secondHouse),
              deletes.allSatisfy({ !path.contains($0.cell) && !common([$0.cell, path[0]]).isEmpty && !common([$0.cell, path[3]]).isEmpty })
        else { return nil }
        let places = path.map { Ref.cell($0, digits: bit) }
        let first = houses[firstHouse], second = houses[secondHouse], middle = houses[middleHouse]
        let firstPair = "\(first.label)中，候选数字 \(digit) 只出现在 \(places[0].label)、\(places[1].label)。"
        let secondPair = "\(second.label)中，候选数字 \(digit) 只出现在 \(places[2].label)、\(places[3].label)。"
        let bridge = "\(places[1].label)、\(places[2].label) 同在\(middle.label)，不能同时为 \(digit)。"
        let explain = "如果 \(places[0].label) 和 \(places[3].label) 都不取 \(digit)，两个连接点就必须同时为 \(digit)，产生冲突。两端至少一格为 \(digit)，同时看见两端的格可排除这个候选。"
        let links = places + [first, second, middle]
        let digitRef = Ref(label: "候选数字 \(digit)", cells: board.candidates.indices.filter { board.candidates[$0] & bit != 0 }, digits: bit)
        let notation = kite
            ? "\(digit) 位于 \(places[0].label)、\(places[3].label)（连接于 \(places[1].label)、\(places[2].label)）"
            : "\(places[0].label) =\(digit)= \(places[1].label) -\(digit)- \(places[2].label) =\(digit)= \(places[3].label)"
        let detail = kite ? firstPair + secondPair + bridge : secondPair + bridge
        let definition = "同一数字在同一行、列或宫内只剩两个候选位置，其中恰有一个成立。"
        return [
            opening(kite ? middle : region(firstHouse)),
            Stage(title: "观察数字", text: "观察\(digitRef.label)。", references: [digitRef]),
            stageWithDefinition(kite ? "第一组位置" : "第一条关系", firstPair, term: "共轭对", explanation: definition, references: links),
            stageWithDefinition(kite ? "两组关系" : "第二条关系", detail, term: "共轭对", explanation: definition, references: links),
            stageWithDefinition("完整理由与结果", firstPair + secondPair + bridge + explain + cutText,
                                term: "共轭对", explanation: definition, references: links + cuts + cuts, notation: "\n\n" + notation + notationEnd)
        ]
    }
}
