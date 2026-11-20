// SPDX-License-Identifier: GPL-3.0-or-later
import CoreGraphics

/// The complete step on its original grid. A candidate is identified by cell * 10 + digit.
struct BoardAnswerDiagram: Equatable {
    enum Role: Equatable {
        case premise, fin, endoFin, deletion, cannibalistic, als(Int), coloring(Int)
    }
    struct Link: Equatable {
        let from, to: Int
        let strong: Bool
    }

    private(set) var candidates = [Int: Role]()
    private(set) var links = [Link]()
    var isBoxProof = false
    let isAuthored: Bool
    let usesPencilNotes: Bool

    init(step: NativeHintStep, board: NativeBoardSnapshot) {
        isAuthored = step.technique == .userChain || step.technique == .userInk
        usesPencilNotes = step.inkConclusions != nil
        func mark(_ cell: Int, _ digit: Int, _ role: Role) {
            guard board.values.indices.contains(cell), (1...9).contains(digit), board.values[cell] == 0,
                  (board.candidates[cell] | (usesPencilNotes ? board.userCandidates[cell] : 0)) & NativeBoardSnapshot.bit(UInt8(digit)) != 0 else { return }
            candidates[cell * 10 + digit] = role
        }
        func markMask(_ cell: Int, _ digits: UInt16, _ role: Role) {
            for digit in 1...9 where digits & NativeBoardSnapshot.bit(UInt8(digit)) != 0 {
                mark(cell, digit, role)
            }
        }
        if let proof = step.logical {
            if proof.deletes.isEmpty {
                if proof.kind == "TEMPLATE_SET", let digit = proof.values.first, proof.values.count == 1 {
                    for cell in proof.indices { mark(cell, Int(digit), .premise) }
                } else {
                    for (cell, digit) in zip(proof.indices, proof.values) { mark(cell, Int(digit), .premise) }
                }
            } else {
                for cell in proof.indices { for digit in proof.values { mark(cell, Int(digit), .premise) } }
            }
            if !proof.kind.hasPrefix("KRAKEN") {
                for (i, cells) in proof.alsCells.enumerated() {
                    // getAlsIndex() returns the first ALS containing the cell.
                    for cell in cells where !proof.alsCells[..<i].contains(where: { $0.contains(cell) }) {
                        markMask(cell, board.candidates[cell], .als(i % 4))
                    }
                }
                for chain in proof.chains {
                    // Negative entries encode branches. MIN terminates a branch without adding a node.
                    var previous: Int32?
                    var branchRoot: Int?
                    for entry in chain {
                        defer { previous = entry }
                        guard entry != .min else { continue }
                        let raw = abs(Int(entry)), digit = raw & 15, cell = raw >> 5 & 127
                        guard (1...9).contains(digit), cell < 81 else { continue }
                        let anchor = cell * 10 + digit, type = raw >> 26 & 3, strong = raw & 16 != 0
                        if type < 2 {
                            mark(cell, digit, strong ? .premise : .fin)
                            if type == 1 {
                                mark(raw >> 12 & 127, digit, strong ? .premise : .fin)
                                mark(raw >> 19 & 127, digit, strong ? .premise : .fin)
                            }
                        }
                        guard let prev = previous else { continue }
                        let prevRaw = abs(Int(prev)), prevDigit = prevRaw & 15, prevCell = prevRaw >> 5 & 127
                        var from = (1...9).contains(prevDigit) && prevCell < 81 ? prevCell * 10 + prevDigit : nil
                        if prev > 0 && entry < 0 { branchRoot = from }
                        if prev == .min || (prev < 0 && entry > 0) { from = branchRoot }
                        if let from = from, from / 10 != cell { links.append(Link(from: from, to: anchor, strong: strong)) }
                    }
                }
            }
            for c in proof.fins { mark(c.cell, Int(c.digit), .fin) }
            for c in proof.endoFins { mark(c.cell, Int(c.digit), .endoFin) }
            for (cell, index) in proof.colors where (0..<12).contains(index) {
                for digit in proof.values { mark(cell, Int(digit), .coloring(index)) }
            }
            for c in proof.deletes { mark(c.cell, Int(c.digit), .deletion) }
            for c in proof.cannibalistic { mark(c.cell, Int(c.digit), .cannibalistic) }
        } else if let ink = step.inkConclusions {
            for atom in ink.truths { mark(atom / 10, atom % 10, .premise) }
            for atom in ink.falses { mark(atom / 10, atom % 10, .deletion) }
        } else if step.technique != .userChain && step.technique != .userInk {
            for cell in step.premises { markMask(cell, step.digits, .premise) }
        }
        if let cell = step.placementCell { mark(cell, Int(step.placementDigit), .premise) }
        if step.logical == nil {
            for (cell, mask) in step.deletions.enumerated() where mask != 0 { markMask(cell, mask, .deletion) }
        }
    }

    func drawLinks(geometry: BoardGeometry, visual: NativeBoardAppearance, markerRadius: CGFloat, in context: CGContext) {
        context.saveGState()
        defer { context.restoreGState() }
        let color = visual.color("arrowColor"), head = geometry.unit / 6
        let width = max(0.8, geometry.unit * 0.014)
        context.setStrokeColor(color)
        context.setFillColor(color)
        context.setLineWidth(width)
        let obstacles = Set(candidates.keys).union(links.flatMap { [$0.from, $0.to] }).map { atom -> CGPoint in
            let slot = geometry.rect(atom / 10, digit: atom % 10)
            return CGPoint(x: slot.midX, y: slot.midY)
        }
        for link in links {
            let a = geometry.rect(link.from / 10, digit: link.from % 10)
            let b = geometry.rect(link.to / 10, digit: link.to % 10)
            let dx = b.midX - a.midX, dy = b.midY - a.midY, length = hypot(dx, dy)
            let inset = markerRadius + width * 2
            guard length > inset * 2 else { continue }
            let angle = atan2(dy, dx)
            let obstructed = length < 4 * markerRadius || obstacles.contains { p in
                let x = p.x - a.midX, y = p.y - a.midY
                let along = (x * dx + y * dy) / length
                return along > inset && along < length - inset && abs(x * dy - y * dx) / length < markerRadius * 0.5
            }
            let turn: CGFloat = obstructed ? .pi / 4 : 0
            let start = CGPoint(x: a.midX + inset * cos(angle - turn), y: a.midY + inset * sin(angle - turn))
            let end = CGPoint(x: b.midX - inset * cos(angle + turn), y: b.midY - inset * sin(angle + turn))
            let control = min(length / 4, geometry.unit * 0.22)
            let route = ChainToolRoute(start: start, end: end, controls: obstructed ? (
                CGPoint(x: start.x + control * cos(angle - turn), y: start.y + control * sin(angle - turn)),
                CGPoint(x: end.x - control * cos(angle + turn), y: end.y - control * sin(angle + turn))
            ) : nil)
            context.setLineDash(phase: 0, lengths: link.strong ? [] : [5 * width, 4 * width])
            context.addPath(route.path)
            context.strokePath()
            if length > 2 * (head + markerRadius) {
                context.addPath(route.arrow(size: head))
                context.fillPath()
            }
        }
    }
}
