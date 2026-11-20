import CoreGraphics
import Foundation

/// All points are logical points, with the origin at the top left.
struct BoardGeometry {
    static let coordinateGutter: CGFloat = 20
    let bounds: CGRect
    let grid: CGRect
    let gap: CGFloat
    let showsCoordinates: Bool
    var unit: CGFloat { (grid.width - 2 * gap) / 9 }

    init(bounds: CGRect, separatedBoxes: Bool = false, showsCoordinates: Bool = false) {
        self.bounds = bounds
        self.showsCoordinates = showsCoordinates
        let gutter = showsCoordinates ? Self.coordinateGutter : 0
        let side = max(0, min(bounds.width, bounds.height) - 20 - gutter)
        gap = separatedBoxes ? side / 100 : 0
        grid = CGRect(x: bounds.midX + (gutter - side) / 2, y: bounds.midY + (gutter - side) / 2, width: side, height: side)
    }

    func coordinateRect(_ house: BoardHouse) -> CGRect {
        let gutter = Self.coordinateGutter
        switch house.kind {
        case .row:
            let row = rect(house.index * 9)
            return CGRect(x: grid.minX - gutter, y: row.minY, width: gutter, height: unit)
        case .column:
            let column = rect(house.index)
            return CGRect(x: column.minX, y: grid.minY - gutter, width: unit, height: gutter)
        case .box:
            return CGRect(x: grid.minX - gutter, y: grid.minY - gutter, width: gutter, height: gutter)
        }
    }

    func coordinateHitRect(_ house: BoardHouse) -> CGRect {
        let rect = coordinateRect(house)
        // Split the space between separated boxes between the adjacent labels.
        let before = house.index > 0 && house.index.isMultiple(of: 3) ? gap / 2 : 0
        let after = house.index < 8 && (house.index + 1).isMultiple(of: 3) ? gap / 2 : 0
        switch house.kind {
        case .row: return CGRect(x: rect.minX, y: rect.minY - before, width: rect.width, height: rect.height + before + after)
        case .column: return CGRect(x: rect.minX - before, y: rect.minY, width: rect.width + before + after, height: rect.height)
        case .box: return rect
        }
    }

    func coordinate(at point: CGPoint) -> BoardHouse? {
        guard showsCoordinates, unit > 0 else { return nil }
        let gutter = Self.coordinateGutter
        let x = grid.minX, y = grid.minY
        let kind: BoardHouse.Kind
        if (x - gutter..<x).contains(point.x), (y..<grid.maxY).contains(point.y) {
            kind = .row
        } else if (y - gutter..<y).contains(point.y), (x..<grid.maxX).contains(point.x) {
            kind = .column
        } else {
            return nil
        }
        return (0..<9).lazy.map { BoardHouse(kind, index: $0) }.first { house in
            let rect = coordinateHitRect(house)
            return kind == .row
                ? (rect.minY..<rect.maxY).contains(point.y)
                : (rect.minX..<rect.maxX).contains(point.x)
        }
    }

    func cell(at point: CGPoint) -> Int? {
        guard unit > 0, grid.contains(point), point.x < grid.maxX, point.y < grid.maxY else { return nil }
        func coordinate(_ delta: CGFloat) -> Int? {
            let band = min(2, Int(delta / (3 * unit + gap)))
            let within = delta - CGFloat(band) * (3 * unit + gap)
            return within < 3 * unit ? band * 3 + min(2, Int(within / unit)) : nil
        }
        guard let row = coordinate(point.y - grid.minY), let column = coordinate(point.x - grid.minX) else { return nil }
        return row * 9 + column
    }

    func rect(_ cell: Int, digit: Int = 0) -> CGRect {
        let x = grid.minX + CGFloat(cell % 9) * unit + CGFloat(cell % 9 / 3) * gap
        let y = grid.minY + CGFloat(cell / 9) * unit + CGFloat(cell / 27) * gap
        if digit == 0 { return CGRect(x: x, y: y, width: unit, height: unit) }
        let step = unit / 3
        return CGRect(
            x: x + CGFloat((digit - 1) % 3) * step, y: y + CGFloat((digit - 1) / 3) * step,
            width: step, height: step)
    }

    func digitSlot(at point: CGPoint) -> Int? {
        guard let cell = cell(at: point) else { return nil }
        let origin = rect(cell).origin
        let col = min(2, Int((point.x - origin.x) * 3 / unit))
        let row = min(2, Int((point.y - origin.y) * 3 / unit))
        return row * 3 + col + 1
    }

    func candidateInkBounds(_ cell: Int, digit: Int) -> CGRect {
        let slot = rect(cell, digit: digit)
        return slot.insetBy(dx: slot.width * 0.11, dy: slot.height * 0.11)
    }

    func candidateChainRing(_ atom: Int, scale: CGFloat = 0.94) -> CGRect {
        let slot = rect(atom / 10, digit: atom % 10)
        let inset = slot.width * (1 - scale) / 2
        return slot.insetBy(dx: inset, dy: inset)
    }

    func visibleDigit(at point: CGPoint, board: NativeBoardSnapshot) -> Int? {
        guard let cell = cell(at: point), board.values[cell] == 0, let digit = digitSlot(at: point) else { return nil }
        return board.candidates[cell] & NativeBoardSnapshot.bit(UInt8(digit)) == 0 ? nil : digit
    }
}

struct BoardHouse: Equatable {
    enum Kind: CaseIterable {
        case row, column, box
    }

    let kind: Kind
    let index: Int

    init(_ kind: Kind, index: Int) {
        self.kind = kind
        self.index = index
    }

    init(_ kind: Kind, cell: Int) {
        switch kind {
        case .row: self.init(kind, index: cell / 9)
        case .column: self.init(kind, index: cell % 9)
        case .box: self.init(kind, index: cell / 27 * 3 + cell % 9 / 3)
        }
    }

    var label: String {
        let prefix: String
        switch kind {
        case .row: prefix = "R"
        case .column: prefix = "C"
        case .box: prefix = "B"
        }
        return prefix + String(index + 1)
    }

    func contains(_ cell: Int) -> Bool { BoardHouse(kind, cell: cell) == self }

    func stepped(by offset: Int) -> Self { Self(kind, index: (index + offset % 9 + 9) % 9) }
}

enum BoardTool: Hashable, CaseIterable {
    case play, color, ink, chain, boxes
    var title: String {
        switch self {
        case .play: return "填数"
        case .color: return "标色"
        case .ink: return "涂鸦"
        case .chain: return "自由链"
        case .boxes: return "选框"
        }
    }
}
enum BoardButton { case left, right }
struct BoardModifiers: OptionSet {
    let rawValue: Int
    static let shift = Self(rawValue: 1), control = Self(rawValue: 2)
    static let option = Self(rawValue: 4), command = Self(rawValue: 8)
}

struct BoardPress {
    let at: Int
    let point: CGPoint
    let button: BoardButton
    let modifiers: BoardModifiers
    let cell: Int?
    let digit: Int?

    var erases: Bool { button == .right || modifiers.contains(.control) }
    var startsChainSegment: Bool { button == .left && modifiers == .command }
    func sameTarget(as other: Self) -> Bool {
        if cell == nil && other.cell == nil && button == .right { return true }
        if let digit = digit { return cell == other.cell && digit == other.digit }
        return other.digit == nil && hypot(point.x - other.point.x, point.y - other.point.y) < 4
    }
}

struct BoardDrag {
    var points: [CGPoint]
    let rectangle: Bool
    var radius: CGFloat

    var bounds: CGRect {
        guard let a = points.first, let b = points.last else { return .zero }
        return CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    func hits(_ point: CGPoint) -> Bool {
        if rectangle { return bounds.contains(point) }
        for (a, b) in zip(points, points.dropFirst()) {
            let dx = b.x - a.x
            let dy = b.y - a.y
            let squared = dx * dx + dy * dy
            let t = squared == 0 ? 0 : min(1, max(0, ((point.x - a.x) * dx + (point.y - a.y) * dy) / squared))
            if hypot(point.x - a.x - t * dx, point.y - a.y - t * dy) <= radius { return true }
        }
        return false
    }
}

/// Times and wheel steps follow HintPreviewGesture; the active stage owns its references.
struct BoardHintGesture {
    private let referenceCount: Int
    var available: Bool { referenceCount > 0 }
    private(set) var index = -1
    private var kept = false
    private var paused = false
    private var downAt: Int?
    private var releaseAt: Int?
    private var indexBefore = -1
    private var second = false
    private var continuedHold = false
    private var usedWheel = false
    private var remainder = 0.0
    private var tailUntil = 0
    var isKeyHeld: Bool { downAt != nil }
    var visible: Bool { available && !paused && index >= 0 && (kept || downAt != nil || releaseAt != nil) }
    var deadline: Int? { releaseAt.map { $0 + 301 } }

    init(referenceCount: Int = 0) { self.referenceCount = referenceCount }
    func rebound(to count: Int, keepingKey: Bool) -> Self {
        var next = Self(referenceCount: count)
        next.paused = paused
        if keepingKey && !paused && count > 0, let down = downAt {
            next.downAt = down
            next.index = 0
            next.continuedHold = true
        }
        return next
    }

    mutating func tick(_ now: Int) {
        if let deadline = deadline, now >= deadline {
            kept.toggle()
            releaseAt = nil
        }
    }
    mutating func press(_ now: Int) {
        guard available, !paused, downAt == nil else { return }
        tick(now)
        second = releaseAt.map { now >= $0 && now - $0 <= 300 } ?? false
        if !second { indexBefore = index }
        releaseAt = nil
        downAt = now
        continuedHold = false
        remainder = 0
        usedWheel = false
        tailUntil = 0
        if index < 0 { index = 0 }
    }
    mutating func release(_ now: Int) {
        guard let start = downAt else { return }
        downAt = nil
        if usedWheel { tailUntil = now + 350 }
        guard now - start < 250, !usedWheel, !continuedHold else { return }
        if second {
            index = indexBefore < 0 ? 0 : min(referenceCount - 1, index + 1)
            kept = true
        } else {
            releaseAt = now
        }
    }
    mutating func wheel(_ delta: Double, now: Int) -> Bool {
        guard downAt != nil || now < tailUntil else { return false }
        guard delta.isFinite, delta != 0 else { return true }
        guard downAt != nil else {
            tailUntil = now + 350
            return true
        }
        usedWheel = true
        if delta * remainder < 0 { remainder = 0 }
        remainder += max(-100, min(100, delta))
        let steps = Int(floor(abs(remainder) + 1e-9)) * (remainder < 0 ? -1 : 1)
        index = max(-1, min(referenceCount - 1, index + steps))
        remainder -= Double(steps)
        return true
    }
    mutating func setPaused(_ value: Bool, now: Int) {
        paused = value
        if value {
            if downAt != nil && usedWheel { tailUntil = now + 350 }
            downAt = nil
            releaseAt = nil
        }
    }
}

struct CandidateFilterHighlight {
    var digitCell = false
    var digitMarks: UInt16 = 0
    var count: Int?
    var countMarks: UInt16 = 0
    var inverseCell = false

    var cell: Bool { inverseCell || digitCell || (count != nil && countMarks == 0) }
    var digits: UInt16 { digitMarks | countMarks }
}

struct BoardFrame: Equatable {
    var page: BoardPage
    var selected: Int?
    var reference: Int?
    var selectionCells: [Int] = []
    var visual = NativeBoardAppearance()
    var colorMode = BoardColorMode.screen
    var general = NativeGeneralOptions()
    var hideSelection = false
    var showCandidates = true
    var revealCandidatesInSelection = false
    var solution: [UInt8]?
    var preview: [NativeHintReference] = []
    var showHistoricalRemovals = false
    var digitFilter: UInt16 = 0
    var countFilters: Set<Int> = []
    var inverseFilter = false
    var filterAnyDigit = false
    var onlySmallFilters = false
    var highlightingGivens = false
    var reviewBoard: NativeBoardSnapshot?
    var previewTool: BoardTool?
    var activeTool: BoardTool = .play
    var erasing = false
    var palette = 0
    var chainRelations: [ChainToolNode: Int] = [:]
    var preciseEndpoint: Int?
    var chainSinglePreview = false
    var later: Set<AnnotationObject> = []
    var erasedInk: InkToolState?
    var inkProjection: InkPreviewProjection?
    var inkSources: [InkStroke] = []
    var answerDiagram: BoardAnswerDiagram?
    var housePreview: BoardHouse?

    func displayedMask(at cell: Int, on board: NativeBoardSnapshot) -> UInt16 {
        guard board.values[cell] == 0 else { return 0 }
        return showCandidates || (revealCandidatesInSelection && selected == cell)
            ? board.candidates[cell] : board.userCandidates[cell]
    }

    func filterHighlights(at cell: Int) -> CandidateFilterHighlight {
        guard digitFilter != 0 || !countFilters.isEmpty else { return .init() }
        let board = page.board
        if board.values[cell] != 0 {
            let hit = digitFilter & NativeBoardSnapshot.bit(board.values[cell]) != 0
            return CandidateFilterHighlight(digitCell: !inverseFilter && highlightingGivens && hit,
                                            inverseCell: inverseFilter)
        }
        let mask = showCandidates ? board.candidates[cell] : board.userCandidates[cell]
        let selected = mask & digitFilter
        let valueMatch = digitFilter != 0 && (filterAnyDigit ? selected != 0 : selected == digitFilter)
        let count = mask.nonzeroBitCount
        let countMatch = countFilters.contains(count)
        if inverseFilter { return CandidateFilterHighlight(inverseCell: !valueMatch && !countMatch) }
        return CandidateFilterHighlight(
            digitCell: valueMatch && !onlySmallFilters,
            digitMarks: valueMatch && (onlySmallFilters || countMatch) ? selected : 0,
            count: countMatch ? count : nil,
            countMarks: countMatch && onlySmallFilters ? mask : 0
        )
    }

    var accessibilityValue: String {
        var parts = [
            "工具 \(activeTool.title)", "已填 \(page.board.values.filter { $0 != 0 }.count) 格", "标色 \(page.marks.count) 项",
        ]
        if digitFilter != 0 { parts.append("筛选数字 " + (1...9).filter { digitFilter & NativeBoardSnapshot.bit(UInt8($0)) != 0 }.map(String.init).joined(separator: "、")) }
        if !countFilters.isEmpty { parts.append("候选数个数 " + countFilters.sorted().map(String.init).joined(separator: "、")) }
        if reviewBoard != nil { parts.append("回看上一步") }
        if activeTool != .play { parts.append("色组 " + AnnotationPalette.names[palette]) }
        if !page.ink.strokes.isEmpty { parts.append("涂鸦 \(page.ink.strokes.count) 笔") }
        if !page.boxes.footprint.isEmpty { parts.append("选框 \(page.boxes.footprint.count) 格") }
        if let selected = selected { parts.append("第 \(selected / 9 + 1) 行第 \(selected % 9 + 1) 列") }
        if let housePreview = housePreview { parts.append("区域预览 \(housePreview.label)") }
        if let diagram = answerDiagram {
            parts.append("答案预览")
            let cuts = diagram.candidates.filter { $0.value == .deletion || $0.value == .cannibalistic }.keys.sorted()
            if !cuts.isEmpty {
                let targets = cuts.map { NativeHintReference.cell($0 / 10).label + " 的 " + String($0 % 10) }
                parts.append("待删候选 " + targets.joined(separator: "、"))
            }
            if !diagram.links.isEmpty { parts.append("\(diagram.links.count) 条推理连线") }
        }
        if !preview.isEmpty { parts.append("提示预览 " + preview.map(\.label).joined(separator: "、")) }
        return parts.joined(separator: "，")
    }
}
