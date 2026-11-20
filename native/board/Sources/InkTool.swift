import CoreGraphics
import Foundation

enum AnnotationPalette {
    static let dark = [0xC66400, 0x7651D1, 0xC43F7B, 0x008A90, 0x3F8F42, 0x3F63CE]
    static let light = [0xFFC48A, 0xCDBEFF, 0xF5B1D0, 0x9FE2E0, 0xB8E4A9, 0xB6C7FF]
    static let names = ["橙色", "紫色", "玫红", "青色", "绿色", "蓝色"]
    static func color(_ group: Int, light pale: Bool = false, alpha: CGFloat = 1) -> CGColor {
        let v = (pale ? light : dark)[group]
        return CGColor(
            srgbRed: CGFloat(v >> 16) / 255, green: CGFloat((v >> 8) & 255) / 255,
            blue: CGFloat(v & 255) / 255, alpha: alpha)
    }
}

extension BoardGeometry {
    func normalized(_ p: CGPoint) -> CGPoint {
        CGPoint(x: (p.x - grid.minX) / grid.width, y: (p.y - grid.minY) / grid.height)
    }
    func project(_ p: CGPoint) -> CGPoint {
        CGPoint(x: grid.minX + p.x * grid.width, y: grid.minY + p.y * grid.height)
    }
}

struct InkStroke: Codable, Equatable {
    enum Kind: String, Codable { case line, ellipse, circle, cross }
    var kind: Kind
    var group: Int
    var width: CGFloat
    var points: [CGPoint] = []  // board fractions for unanchored ink
    var cell: Int?
    var digit: Int?
    var witness = false
    var outlined = false
    var start = false
    // nil is an older native record without an explicit archive owner marker.
    var ownsProof: Bool?
    var outlineSources: Set<Int> = []
    var light: Bool?

    func paths(_ g: BoardGeometry) -> [[CGPoint]] {
        if kind == .line { return [points.map(g.project)] }
        let bounds: CGRect
        if let cell = cell, let digit = digit {
            bounds = g.candidateInkBounds(cell, digit: digit)
        } else if points.count == 2 {
            let a = g.project(points[0])
            let b = g.project(points[1])
            bounds = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
        } else {
            return []
        }
        if kind == .cross {
            let inset = min(bounds.width, bounds.height) * 0.16
            let box = bounds.insetBy(dx: inset, dy: inset)
            return [
                [CGPoint(x: box.minX, y: box.minY), CGPoint(x: box.maxX, y: box.maxY)],
                [CGPoint(x: box.minX, y: box.maxY), CGPoint(x: box.maxX, y: box.minY)],
            ]
        }
        let segments = max(24, min(512, Int(ceil(max(bounds.width, bounds.height) * .pi / 3))))
        return [
            (0...segments).map { i in
                let angle = CGFloat(i) * 2 * .pi / CGFloat(segments)
                return CGPoint(
                    x: bounds.midX + cos(angle) * bounds.width / 2, y: bounds.midY + sin(angle) * bounds.height / 2)
            }
        ]
    }

    func lineWidth(in geometry: BoardGeometry, candidateFontFactor: CGFloat) -> CGFloat {
        let requested = width * geometry.grid.width
        guard cell != nil else { return max(1, requested) }
        let slot = geometry.unit / 3
        let scale = min(1.16, max(0.60, sqrt(candidateFontFactor / 0.25)))
        let minimum = min(0.68, slot * 0.055)
        let maximum = slot * (kind == .cross ? 0.087 : 0.103)
        let baseline = min(0.35, slot * 0.02)
        return min(maximum, max(minimum, baseline + requested * (kind == .cross ? 0.30 : 0.34))) * scale
    }
}

struct InkToolState: Equatable, Codable {
    var strokes: [InkStroke] = []
    var consumedGroups: Set<Int> = []
    var proofs: [Int: [InkStroke]] = [:]
    @discardableResult
    mutating func resizeCandidateMarks(to width: CGFloat) -> Bool {
        var changed = false
        for i in strokes.indices where strokes[i].cell != nil && strokes[i].width != width {
            strokes[i].width = width
            changed = true
        }
        return changed
    }

    func validate() throws {
        guard consumedGroups.isSubset(of: Set(0..<6)) else { throw BoardFileError.invalid }
        guard Set(proofs.keys).isSubset(of: Set(0..<6)) else { throw BoardFileError.invalid }
        for s in strokes + proofs.values.flatMap({ $0 }) {
            guard s.outlineSources.isSubset(of: Set(0..<6)), (0..<6).contains(s.group), s.width.isFinite,
                (0...0.2).contains(s.width),
                s.points.allSatisfy({ $0.x.isFinite && $0.y.isFinite && abs($0.x) < 1024 && abs($0.y) < 1024 })
            else { throw BoardFileError.invalid }
            switch s.kind {
            case .line, .ellipse:
                guard s.cell == nil, s.digit == nil, s.points.count >= 2,
                    s.kind != .ellipse || s.points.count == 2
                else { throw BoardFileError.invalid }
            case .circle, .cross:
                guard let c = s.cell, let d = s.digit, (0..<81).contains(c), (1...9).contains(d), s.points.isEmpty
                else { throw BoardFileError.invalid }
            }
        }
    }
    mutating func trace(_ drag: BoardDrag, ellipse: Bool, group: Int, width: CGFloat, geometry: BoardGeometry, light: Bool? = nil) {
        guard let a = drag.points.first, let b = drag.points.last, drag.points.count >= 2, geometry.unit > 0 else {
            return
        }
        let points = (ellipse ? [a, b] : drag.points).map(geometry.normalized)
        strokes.append(InkStroke(kind: ellipse ? .ellipse : .line, group: group, width: width, points: points, light: light))
    }
    func erased(
        _ drag: BoardDrag, group: Int?, whole: Bool, geometry: BoardGeometry, candidateFontFactor: CGFloat = 0.25
    ) -> (kept: Self, removed: Self) {
        var kept = Self()
        var removed = Self()
        kept.consumedGroups = consumedGroups
        kept.proofs = proofs
        let eraser = InkEraser(drag)
        for stroke in strokes {
            if let group = group, group != stroke.group {
                kept.strokes.append(stroke)
                continue
            }
            let padding = (stroke.cell == nil ? stroke.width * geometry.grid.width
                : stroke.lineWidth(in: geometry, candidateFontFactor: candidateFontFactor)) / 2
            let paths = stroke.paths(geometry)
            if whole || stroke.cell != nil {
                let hit = paths.contains { path in
                    zip(path, path.dropFirst()).contains { a, b in
                        !eraser.hitIntervals(a, b, padding: padding).isEmpty
                    }
                }
                if hit { removed.strokes.append(stroke) } else { kept.strokes.append(stroke) }
                continue
            }
            var outside: [[CGPoint]] = []
            var inside: [[CGPoint]] = []
            for path in paths {
                for (a, b) in zip(path, path.dropFirst()) {
                    let intervals = eraser.hitIntervals(a, b, padding: padding)
                    func at(_ t: CGFloat) -> CGPoint {
                        if t == 0 { return a }
                        if t == 1 { return b }
                        return CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
                    }
                    var last: CGFloat = 0
                    func append(_ t: CGFloat, _ u: CGFloat, to result: inout [[CGPoint]]) {
                        guard u - t > 1e-10 else { return }
                        let p = at(t)
                        let q = at(u)
                        if result.last?.last == p { result[result.count - 1].append(q) } else { result.append([p, q]) }
                    }
                    for cut in intervals {
                        append(last, cut.0, to: &outside)
                        append(cut.0, cut.1, to: &inside)
                        last = cut.1
                    }
                    append(last, 1, to: &outside)
                }
            }
            if inside.isEmpty {
                kept.strokes.append(stroke)
                continue
            }
            func fragments(_ paths: [[CGPoint]]) -> [InkStroke] {
                paths.map {
                    InkStroke(
                        kind: .line, group: stroke.group, width: stroke.width, points: $0.map(geometry.normalized), light: stroke.light)
                }
            }
            kept.strokes += fragments(outside)
            removed.strokes += fragments(inside)
        }
        return (kept, removed)
    }
    func draw(
        in ctx: CGContext, geometry g: BoardGeometry, alpha: CGFloat = 1, ghosts: InkToolState? = nil,
        group: Int? = nil, board: NativeBoardSnapshot? = nil, visual: NativeBoardAppearance = .init(),
        candidateFontFactor: CGFloat = 0.25, include: (InkStroke.Kind) -> Bool = { _ in true },
        visible: (InkStroke) -> Bool = { _ in true }
    ) {
        AnnotationOverlay.ink(
            self, ghosts: ghosts, in: ctx, geometry: g, group: group, board: board, alpha: alpha, visual: visual,
            candidateFontFactor: candidateFontFactor, include: include, visible: visible)
    }
}

private struct InkEraser {
    private struct Strip {
        let start: CGPoint
        let length: CGFloat
        let ux: CGFloat
        let uy: CGFloat

        init?(_ a: CGPoint, _ b: CGPoint) {
            let length = hypot(b.x - a.x, b.y - a.y)
            guard length > 0 else { return nil }
            start = a
            self.length = length
            ux = (b.x - a.x) / length
            uy = (b.y - a.y) / length
        }
    }

    private struct Batch {
        let points: ArraySlice<CGPoint>
        let bounds: CGRect
        let strips: [Strip]

        init(_ points: ArraySlice<CGPoint>) {
            self.points = points
            var left = points.first!.x, right = left
            var top = points.first!.y, bottom = top
            for p in points {
                left = min(left, p.x)
                right = max(right, p.x)
                top = min(top, p.y)
                bottom = max(bottom, p.y)
            }
            bounds = CGRect(x: left, y: top, width: right - left, height: bottom - top)
            strips = zip(points, points.dropFirst()).compactMap { Strip($0, $1) }
        }
    }

    private let rectangle: CGRect?
    private let radius: CGFloat
    private let batches: [Batch]

    init(_ drag: BoardDrag) {
        rectangle = drag.rectangle ? drag.bounds : nil
        radius = drag.radius
        if drag.rectangle || drag.points.isEmpty {
            batches = []
        } else {
            // Neighboring batches share an endpoint, so no connecting strip is lost.
            batches = stride(from: 0, to: max(1, drag.points.count - 1), by: 16).map { i in
                Batch(drag.points[i...min(i + 16, drag.points.count - 1)])
            }
        }
    }

    // Intersect a segment with the union of the swept brush capsules. Rectangle
    // slabs and quadratic end caps retain the cut point even on very long lines.
    func hitIntervals(_ a: CGPoint, _ b: CGPoint, padding: CGFloat) -> [(CGFloat, CGFloat)] {
        let dx = b.x - a.x
        let dy = b.y - a.y
        var cuts: [(CGFloat, CGFloat)] = []
        func slab(_ origin: CGFloat, _ delta: CGFloat, _ lo: CGFloat, _ hi: CGFloat, _ t: inout (CGFloat, CGFloat))
            -> Bool
        {
            if abs(delta) < 1e-12 { return origin >= lo && origin <= hi }
            let x = (lo - origin) / delta
            let y = (hi - origin) / delta
            t = (max(t.0, min(x, y)), min(t.1, max(x, y)))
            return t.0 < t.1
        }
        func box(_ x: CGFloat, _ y: CGFloat, _ vx: CGFloat, _ vy: CGFloat, _ rect: CGRect) {
            var t: (CGFloat, CGFloat) = (0, 1)
            if slab(x, vx, rect.minX, rect.maxX, &t) && slab(y, vy, rect.minY, rect.maxY, &t) { cuts.append(t) }
        }
        func circle(_ p: CGPoint, _ r: CGFloat) {
            let x = a.x - p.x
            let y = a.y - p.y
            let aa = dx * dx + dy * dy
            let bb = x * dx + y * dy
            guard aa > 0 else { return }
            let disc = bb * bb - aa * (x * x + y * y - r * r)
            guard disc > 0 else { return }
            let t = max(0, (-bb - sqrt(disc)) / aa)
            let u = min(1, (-bb + sqrt(disc)) / aa)
            if t < u { cuts.append((t, u)) }
        }
        if let r = rectangle {
            guard overlaps(r, padding: padding) else { return [] }
            box(a.x, a.y, dx, dy, r.insetBy(dx: -padding, dy: 0))
            box(a.x, a.y, dx, dy, r.insetBy(dx: 0, dy: -padding))
            for x in [r.minX, r.maxX] { for y in [r.minY, r.maxY] { circle(CGPoint(x: x, y: y), padding) } }
        } else {
            let r = radius + padding
            for batch in batches where overlaps(batch.bounds, padding: r) {
                for p in batch.points { circle(p, r) }
                for strip in batch.strips {
                    let ux = strip.ux, uy = strip.uy
                    let x = a.x - strip.start.x
                    let y = a.y - strip.start.y
                    box(
                        x * ux + y * uy, -x * uy + y * ux, dx * ux + dy * uy, -dx * uy + dy * ux,
                        CGRect(x: 0, y: -r, width: strip.length, height: 2 * r))
                }
            }
        }
        func overlaps(_ bounds: CGRect, padding: CGFloat) -> Bool {
            min(a.x, b.x) <= bounds.maxX + padding && max(a.x, b.x) >= bounds.minX - padding &&
                min(a.y, b.y) <= bounds.maxY + padding && max(a.y, b.y) >= bounds.minY - padding
        }
        var merged: [(CGFloat, CGFloat)] = []
        for cut in cuts.sorted(by: { $0.0 < $1.0 }) {
            if let last = merged.last, cut.0 <= last.1 {
                merged[merged.count - 1] = (last.0, max(last.1, cut.1))
            } else {
                merged.append(cut)
            }
        }
        return merged
    }
}
