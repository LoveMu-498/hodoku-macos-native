// SPDX-License-Identifier: GPL-3.0-or-later
import CoreGraphics
import Foundation

struct NativeHintLayout {
    let panel: CGRect
    let centeredGrid: CGRect
    let grid: CGRect
    let availableShift: CGFloat
    let boardShift: CGFloat
    let cellWidth: CGFloat

    var overlapWidth: CGFloat {
        let intersection = grid.intersection(panel)
        return intersection.isNull ? 0 : intersection.width
    }
    var overlapLimit: CGFloat { cellWidth / 2 }
    var exceedsOverlapLimit: Bool { overlapWidth > overlapLimit }

    init(size: CGSize, open: Bool, separatedBoxes: Bool, fits: (CGFloat, CGFloat) -> Bool) {
        let gap: CGFloat = 8
        let full = CGRect(origin: .zero, size: size)
        let geometry = BoardGeometry(bounds: full, separatedBoxes: separatedBoxes, showsCoordinates: true)
        centeredGrid = geometry.grid
        cellWidth = geometry.unit
        let width = min(max(0, size.width - 2 * gap), min(340, max(248, (size.width * 0.31).rounded())))
        let height = max(0, size.height - 2 * gap)
        let labelsStart = geometry.coordinateRect(BoardHouse(.row, index: 0)).minX
        availableShift = max(0, floor(labelsStart - 10))

        let overlapAtRest = geometry.grid.maxX - (size.width - gap - width)
        let relief = open
            ? Self.distribute(overlap: overlapAtRest, gap: gap, cellWidth: geometry.unit, availableShift: availableShift,
                              width: width, canNarrow: fits(width, height), fits: { fits($0, height) })
            : (shift: CGFloat(0), narrowing: CGFloat(0))
        boardShift = relief.shift
        let panelWidth = width - relief.narrowing
        panel = open ? CGRect(x: size.width - gap - panelWidth, y: gap, width: panelWidth, height: height) : .null
        grid = centeredGrid.offsetBy(dx: -boardShift, dy: 0)
    }

    private static func distribute(overlap: CGFloat, gap: CGFloat, cellWidth: CGFloat, availableShift: CGFloat,
                                   width: CGFloat, canNarrow: Bool, fits: (CGFloat) -> Bool)
        -> (shift: CGFloat, narrowing: CGFloat) {
        let separation = max(0, ceil(overlap + gap))
        guard separation > 0 else { return (0, 0) }
        let budget = canNarrow ? min(separation, 36, max(0, floor(width - 248))) : 0

        func split(_ relief: CGFloat) -> (shift: CGFloat, narrowing: CGFloat)? {
            let maximum = min(relief, budget)
            let minimum = max(0, relief - availableShift)
            guard maximum >= minimum else { return nil }
            if maximum == relief, relief > 0, fits(width - relief) { return (0, relief) }
            let preferred = min(maximum, max(minimum, (relief * 0.75).rounded()))
            for amount in stride(from: preferred, through: minimum, by: -1) {
                if amount == 0 || (amount < relief && fits(width - amount)) {
                    return (relief - amount, amount)
                }
            }
            return nil
        }

        if let clear = split(separation) { return clear }
        if let touching = split(max(0, ceil(overlap))) { return touching }
        if let halfCell = split(max(0, ceil(overlap - cellWidth / 2))) { return halfCell }

        // With a screen-limited width, use the room we actually have.
        let largestFitting = stride(from: budget, through: 1, by: -1).first { fits(width - $0) } ?? 0
        return (availableShift, largestFitting)
    }
}

enum NativeHintWindowWidth {
    static func expanded(from size: CGSize, to screenWidth: CGFloat, layout: (CGSize) -> NativeHintLayout) -> CGFloat {
        let current = layout(size)
        guard current.exceedsOverlapLimit, screenWidth > size.width else { return size.width }
        var bestWidth = size.width
        var bestExcess = current.overlapWidth - current.overlapLimit
        // Scan integral points. Width rounding and text wrapping can change the result by one point.
        var width = min(screenWidth, floor(size.width) + 1)
        while width > size.width {
            let candidate = layout(CGSize(width: width, height: size.height))
            if !candidate.exceedsOverlapLimit { return width }
            let excess = candidate.overlapWidth - candidate.overlapLimit
            if excess < bestExcess {
                bestWidth = width
                bestExcess = excess
            }
            guard width < screenWidth else { break }
            width = min(screenWidth, width + 1)
        }
        return bestWidth
    }

    static func frame(for width: CGFloat, current: CGRect, visible: CGRect) -> CGRect {
        let left = min(max(current.midX - width / 2, visible.minX), visible.maxX - width)
        return CGRect(x: left, y: current.minY, width: width, height: current.height)
    }
}

struct NativeHintBoardTravel: Equatable {
    let from: CGFloat
    let to: CGFloat
    let start: Date
    let duration: TimeInterval

    var end: Date { start.addingTimeInterval(duration) }

    static func forToggle(from: CGFloat, to: CGFloat, cellWidth: CGFloat, showing: Bool,
                          reduceMotion: Bool, now: Date) -> NativeHintBoardTravel? {
        guard !reduceMotion, abs(from - to) >= max(24, cellWidth / 2) else { return nil }
        return NativeHintBoardTravel(from: from, to: to, start: now, duration: showing ? 0.21 : 0.18)
    }

    func shift(at time: Date) -> CGFloat {
        let progress = CGFloat(min(1, max(0, time.timeIntervalSince(start) / duration)))
        let eased = progress * progress * (3 - 2 * progress)
        return from + (to - from) * eased
    }
}
