// SPDX-License-Identifier: GPL-3.0-or-later
import CoreGraphics

/// SudokuPanel.currentDoodleSources / drawDoodleSources. Archived ink has
/// geometry and its original ink color, but no editable or executable role.
enum InkProofPreview {
    private struct StrokeKey: Hashable {
        let group: Int
        let kind: InkStroke.Kind
        let width: CGFloat
        let cell: Int?
        let digit: Int?
        let points: [UInt64]

        init(_ s: InkStroke) {
            group = s.group
            kind = s.kind
            width = s.width
            cell = s.cell
            digit = s.digit
            points = s.points.flatMap { [Double($0.x).bitPattern, Double($0.y).bitPattern] }
        }
    }

    static func owns(_ mark: InkStroke, archived: [InkStroke]) -> Bool {
        if let recorded = mark.ownsProof { return recorded }
        // Native v2 originally saved the all-false inputs and adopted circle
        // atoms. Match that recorded origin when reading such an older board.
        return mark.kind == .circle && archived.contains { original in
            original.kind == .cross && original.start && original.group == mark.group &&
                original.cell == mark.cell && original.digit == mark.digit
        }
    }

    static func sources(in ink: InkToolState, tool: BoardTool, inkGroup: Int, optionOrMiddle: Bool,
                        displayingStep: Bool) -> [InkStroke] {
        guard optionOrMiddle, !displayingStep, tool == .ink || tool == .chain,
              let saved = ink.proofs[inkGroup], !saved.isEmpty,
              ink.strokes.contains(where: { $0.group == inkGroup && owns($0, archived: saved) }) else { return [] }
        var drawn = Set<StrokeKey>()
        return saved.compactMap { source in
            guard drawn.insert(StrokeKey(source)).inserted else { return nil }
            var geometry = source
            geometry.ownsProof = nil
            geometry.start = false
            geometry.outlined = false
            geometry.witness = false
            geometry.outlineSources = []
            return geometry
        }
    }

    static func draw(
        _ sources: [InkStroke], in context: CGContext, geometry: BoardGeometry, visual: NativeBoardAppearance,
        candidateFontFactor: CGFloat
    ) {
        guard !sources.isEmpty else { return }
        context.saveGState()
        defer { context.restoreGState() }
        context.setLineCap(.round)
        context.setLineJoin(.round)
        for s in sources {
            context.setLineWidth(s.lineWidth(in: geometry, candidateFontFactor: candidateFontFactor))
            context.setStrokeColor(visual.annotationColor(s.group, light: s.light == true, alpha: 0.42))
            context.beginPath()
            for path in s.paths(geometry) {
                guard let first = path.first else { continue }
                context.move(to: first)
                for point in path.dropFirst() { context.addLine(to: point) }
            }
            context.strokePath()
        }
    }
}
