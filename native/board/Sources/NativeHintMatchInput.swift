// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

enum NativeHintMatchInput: Equatable {
    enum Kind: String { case boxes, chain, digits }

    case boxes(groups: [Set<Int>], active: Int, digit: UInt8?)
    case chain(NativeFineChain)
    case digits(Set<UInt8>)

    var kind: Kind {
        switch self {
        case .boxes: return .boxes
        case .chain: return .chain
        case .digits: return .digits
        }
    }

    var description: String {
        switch self {
        case .boxes: return "选框"
        case .chain: return "自由链"
        case .digits(let digits): return "数字 " + digits.sorted().map(String.init).joined(separator: "、")
        }
    }

    var source: NativeHintRequests.Source {
        switch self {
        case .boxes: return .tabBoxes
        case .chain: return .tabChain
        case .digits: return .tabDigits
        }
    }

    func steps(on board: NativeBoardSnapshot, config: NativeSolverConfig, firstOnly: Bool,
               preparingSingles: Bool = false,
               cancelled: () -> Bool) throws -> [NativeHintStep] {
        let parts: [(NativeFineHints.Scope, UInt8?)]
        switch self {
        case let .boxes(groups, active, digit):
            let group = groups[active]
            let all = Set(groups.joined())
            var scopes: [NativeFineHints.Scope] = []
            if !group.isEmpty { scopes.append(.boxes(group, active: true, allowPartial: false)) }
            if group != all { scopes.append(.boxes(all, active: false, allowPartial: false, groups: groups)) }
            parts = scopes.map { ($0, digit) }
        case .chain(let path): parts = [(.chain(path), nil)]
        case .digits(let digits): parts = [(.digits(digits), nil)]
        }
        var result = [NativeHintStep]()
        for (scope, digit) in parts {
            if cancelled() { return [] }
            if firstOnly {
                if let step = try NativeFineHints.lookup(scope, board: board, config: config,
                                                        preferredDigit: digit, preparingSingles: preparingSingles,
                                                        cancelled: cancelled) { return [step] }
                // A miss in a bounded prefix says nothing about the rest of this
                // scope. A later scope must never take precedence over it.
                if preparingSingles { return [] }
            } else {
                for step in try NativeFineHints.matches(scope, board: board, config: config,
                                                       preferredDigit: digit, cancelled: cancelled) where !result.contains(step) {
                    result.append(step)
                }
            }
        }
        return cancelled() ? [] : result
    }
}
