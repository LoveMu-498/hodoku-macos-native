// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Consumes the bounded Java proof format without executing a technique or
/// inferring board changes. Authored geometry is decoded separately.
enum ReplayJavaProof {
    struct Placement {
        let cell: Int
        let digit: Int
        let technique: String

        var description: String {
            let name = ["FULL_HOUSE":"摒余解", "HIDDEN_SINGLE":"隐性单数", "NAKED_SINGLE":"显性单数"][technique]!
            return "\(name) R\(cell / 9 + 1)C\(cell % 9 + 1) = \(digit)"
        }
        func display(in page: inout BoardPage, applied: Bool) {
            let filled = applied && page.board.values[cell] == digit
            ReplayJavaAnnotations.mark(&page, cell: cell, digit: filled ? 0 : digit, group: 4)
        }
    }

    @discardableResult static func validate(_ data: Data) throws -> Placement? {
        var r = ReplayJavaInput(data: data)
        guard try r.int() == 0x48525046 else { throw ReplayJavaError.invalid }
        let version = try r.int(), technique = try r.utf()
        guard (1...2).contains(version), !technique.isEmpty else { throw ReplayJavaError.invalid }
        let subtype = try r.utf()
        for _ in 0..<7 { _ = try r.int() }
        _ = try r.boolean(); _ = try r.boolean()
        @discardableResult func ints(_ input: inout ReplayJavaInput, _ range: ClosedRange<Int>) throws -> [Int] {
            var result = [Int]()
            for _ in 0..<(try input.count(16384)) {
                let n = try input.int()
                guard range.contains(n) else { throw ReplayJavaError.invalid }
                result.append(n)
            }
            return result
        }
        let digits = try ints(&r, 1...9), cells = try ints(&r, 0...80)
        var simple = ["FULL_HOUSE","HIDDEN_SINGLE","NAKED_SINGLE"].contains(technique)
            && subtype.isEmpty && digits.count == 1 && cells.count == 1
        func layers(_ input: inout ReplayJavaInput) throws -> Int {
            let n = try input.count(16384)
            if n != 0 { simple = false }
            return n
        }
        for _ in 0..<4 {
            for _ in 0..<(try layers(&r)) {
                _ = try r.count(80)
                guard try (1...9).contains(r.int()) else { throw ReplayJavaError.invalid }
            }
        }
        for _ in 0..<2 {
            for _ in 0..<(try layers(&r)) { _ = try r.count(3); _ = try r.count(9) }
        }
        for _ in 0..<(try layers(&r)) {
            let start = try r.int(), end = try r.int(), count = try r.count(16384)
            guard start >= 0, end >= start, end < count else { throw ReplayJavaError.invalid }
            _ = try r.bytes(count * 4)
        }
        let alsCount = try layers(&r)
        for _ in 0..<alsCount { try ints(&r, 0...80); try ints(&r, 1...9); _ = try r.int() }
        for _ in 0..<(try layers(&r)) { _ = try r.count(80); guard try r.int() >= 0 else { throw ReplayJavaError.invalid } }
        for _ in 0..<(try layers(&r)) {
            guard try (0..<alsCount).contains(r.int()), try (0..<alsCount).contains(r.int()),
                  try (1...9).contains(r.int()), try (0...9).contains(r.int()) else { throw ReplayJavaError.invalid }
            _ = try r.int()
        }
        let potential = try ints(&r, 0...80), alternatives = try ints(&r, 0...80)
        if !potential.isEmpty || !alternatives.isEmpty { simple = false }
        if version == 2 {
            for _ in 0..<(try layers(&r)) {
                let count = try r.count(16384)
                guard count > 0 else { throw ReplayJavaError.invalid }
                for _ in 0..<count {
                    let atoms = try r.count(729)
                    guard atoms > 0 else { throw ReplayJavaError.invalid }
                    for _ in 0..<atoms {
                        guard try ReplayJavaAnnotations.validAtom(r.int()) else { throw ReplayJavaError.invalid }
                    }
                    _ = try r.boolean()
                }
            }
            let diagram = try ReplayJavaAnnotations.geometry(r.blob(), pending: true)
            if !diagram.0.footprint.isEmpty || !diagram.1.paths.isEmpty { simple = false }
        }
        guard r.remaining == 0 else { throw ReplayJavaError.invalid }
        return simple ? Placement(cell: cells[0], digit: digits[0], technique: technique) : nil
    }
}
