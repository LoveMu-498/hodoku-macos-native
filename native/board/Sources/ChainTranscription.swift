// SPDX-License-Identifier: GPL-3.0-or-later
import CoreGraphics

/// All atomic conclusions of an authored chain, including conclusions outside its displayed step.
struct ChainConclusions: Equatable {
    let truths: Set<Int>
    let falses: Set<Int>

    init(trueAtoms: Set<Int>, falseAtoms: Set<Int>) {
        truths = trueAtoms
        falses = falseAtoms
    }

    init(truths: [UInt16], falses: [UInt16]) {
        func atoms(_ masks: [UInt16]) -> Set<Int> {
            var result = Set<Int>()
            for (cell, mask) in masks.enumerated() where mask != 0 {
                for digit in 1...9 where mask & NativeBoardSnapshot.bit(UInt8(digit)) != 0 {
                    result.insert(cell * 10 + digit)
                }
            }
            return result
        }
        self.truths = atoms(truths)
        self.falses = atoms(falses)
    }

    func replacing(_ ink: InkToolState, group: Int, board: NativeBoardSnapshot, width: CGFloat, light: Bool? = nil) -> InkToolState? {
        guard (0..<6).contains(group), !truths.isEmpty || !falses.isEmpty else { return nil }
        let starts = ink.strokes.filter { $0.group == group && $0.start }
        guard let kind = starts.first?.kind, kind == .circle || kind == .cross else { return nil }
        func present(_ atom: Int) -> Bool {
            let cell = atom / 10
            return board.values.indices.contains(cell) && (1...9).contains(atom % 10) &&
                board.values[cell] == 0 && board.candidates[cell] & NativeBoardSnapshot.bit(UInt8(atom % 10)) != 0
        }
        var conditions = Set<Int>()
        for mark in starts {
            guard mark.kind == kind, let cell = mark.cell, let digit = mark.digit,
                  present(cell * 10 + digit) else { return nil }
            conditions.insert(cell * 10 + digit)
        }
        guard truths.allSatisfy(present), falses.allSatisfy(present) else { return nil }
        let circles = kind == .circle && conditions.count == 1 ? truths.subtracting(conditions) : truths
        let crosses = kind == .cross ? falses.subtracting(conditions) : falses
        var changed = ink
        changed.strokes.removeAll { $0.group == group && !$0.start }
        // Reconcile ownership before appending ordinary marks at possibly reused coordinates.
        InkReasoning.reconcile(&changed)
        for (atoms, role) in [(circles, InkStroke.Kind.circle), (crosses, .cross)] {
            for atom in atoms.sorted() {
                changed.strokes.append(InkStroke(kind: role, group: group, width: width,
                    cell: atom / 10, digit: atom % 10, ownsProof: false, light: light))
            }
        }
        changed.consumedGroups.insert(group)
        return changed
    }
}
