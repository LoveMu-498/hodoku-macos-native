// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

struct NativeMouseOptions: Codable, Equatable {
    var operationSoundsEnabled = false
    var singleClickMode = false
    var showCandidates = true
    var showDeviations = true
    var useShiftForRegionSelect = true
    var autoHighlighting = false

    var useOrInsteadOfAndForFilter = false
    var onlySmallFilters = false
    var highlightingGivens = false
    var editModeAutoAdvance = false

    init() {}

    init(from decoder: Decoder) throws {
        self.init()
        let values = try decoder.container(keyedBy: CodingKeys.self)
        for (key, field) in Self.fields {
            if let value = try values.decodeIfPresent(Bool.self, forKey: key) {
                self[keyPath: field] = value
            }
        }
    }

    private enum CodingKeys: String, CodingKey {
        case operationSoundsEnabled, singleClickMode, showCandidates, showDeviations, useShiftForRegionSelect, autoHighlighting
        case useOrInsteadOfAndForFilter, onlySmallFilters, highlightingGivens, editModeAutoAdvance
    }

    private static let fields: [(CodingKeys, WritableKeyPath<Self, Bool>)] = [
        (.operationSoundsEnabled, \.operationSoundsEnabled), (.singleClickMode, \.singleClickMode), (.showCandidates, \.showCandidates),
        (.showDeviations, \.showDeviations), (.useShiftForRegionSelect, \.useShiftForRegionSelect),
        (.autoHighlighting, \.autoHighlighting), (.useOrInsteadOfAndForFilter, \.useOrInsteadOfAndForFilter),
        (.onlySmallFilters, \.onlySmallFilters), (.highlightingGivens, \.highlightingGivens),
        (.editModeAutoAdvance, \.editModeAutoAdvance)
    ]

    init(_ options: LegacyBean) throws {
        self.init()
        for (key, field) in Self.fields {
            self[keyPath: field] = try options.flag(key.stringValue, self[keyPath: field])
        }
    }

    func displayedMask(_ board: NativeBoardSnapshot, at cell: Int) -> UInt16 {
        showCandidates ? board.candidates[cell] : board.userCandidates[cell]
    }
}

/// Ordinary clicks pair by two releases on the same cell and geometric ninth.
/// An annotation single, in contrast, can be rolled back within a shorter press-to-press window.
struct NativePlayMouse {
    var previous: (cell: Int, digit: Int, at: Int)?
    var press: BoardPress?
    var deselectOnRelease = false
    var moved = false
    var secondPress = false

    static func marquee(from start: Int?, to end: CGPoint, geometry: BoardGeometry) -> [Int] {
        guard let start = start, geometry.unit > 0 else { return [] }
        let anchor = geometry.rect(start)
        let x = min(anchor.midX, end.x)...max(anchor.midX, end.x)
        let y = min(anchor.midY, end.y)...max(anchor.midY, end.y)
        return (0..<81).filter { cell in
            let rect = geometry.rect(cell)
            return rect.minX <= x.upperBound && rect.maxX > x.lowerBound &&
                rect.minY <= y.upperBound && rect.maxY > y.lowerBound
        }
    }

    mutating func released(cell: Int, digit: Int, at now: Int, interval: Int) -> Bool {
        if let previous = previous, previous.cell == cell, previous.digit == digit,
           (0...interval).contains(now - previous.at) {
            self.previous = nil
            return true
        }
        previous = (cell, digit, now)
        return false
    }
}
