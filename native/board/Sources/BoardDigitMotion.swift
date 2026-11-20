import CoreGraphics
import Foundation

/// Presentation of one committed edit. The board already contains the final values and masks.
struct BoardDigitMotion {
    static let duration: TimeInterval = 0.12
    private static let removalDuration: TimeInterval = 0.09

    let before: NativeBoardSnapshot
    let after: NativeBoardSnapshot
    let start: TimeInterval
    private let changesValues: Bool
    private let explicitRemovals: [UInt16]

    init(before: NativeBoardSnapshot, after: NativeBoardSnapshot, explicitRemovals: [UInt16], start: TimeInterval) {
        self.before = before
        self.after = after
        self.explicitRemovals = explicitRemovals
        self.start = start
        changesValues = before.values != after.values
    }

    static func opacity(elapsed: TimeInterval) -> (added: CGFloat, removed: CGFloat) {
        let entering = CGFloat(min(1, max(0, elapsed / duration)))
        let exiting = CGFloat(1 - min(1, max(0, elapsed / removalDuration)))
        return (entering * entering, exiting * exiting)
    }

    func candidateChanges(at cell: Int, previous: UInt16, current: UInt16) -> (added: UInt16, removed: UInt16) {
        if changesValues, before.values[cell] == after.values[cell] {
            let explicit = explicitRemovals.indices.contains(cell) ? explicitRemovals[cell] : 0
            return (0, previous & ~current & explicit)
        }
        return (current & ~previous, previous & ~current)
    }
}
