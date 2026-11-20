// Copyright (C) 2026 HoDoKu contributors. GPL-3.0-or-later.
import CoreGraphics
import CoreText
import Foundation
import ImageIO

enum ReplayExchangePainter {
    // The caller supplies a top-left, y-down canvas, as used by CandidateBoardView.
    static func draw(_ frame: NativeReplayFrame, in rect: CGRect, context g: CGContext) {
        guard rect.width > 0 && rect.height > 0 else { return }
        g.saveGState()
        defer { g.restoreGState() }
        g.clip(to: rect)
        g.setFillColor(CGColor(gray: 1, alpha: 1))
        g.fill(rect)
        if let png = frame.previewPNG,
            let src = CGImageSourceCreateWithData(png as CFData, nil),
            let image = CGImageSourceCreateImageAtIndex(src, 0, nil)
        {
            let fit = min(rect.width / CGFloat(image.width), rect.height / CGFloat(image.height))
            let size = CGSize(width: CGFloat(image.width) * fit, height: CGFloat(image.height) * fit)
            g.translateBy(x: rect.midX - size.width / 2, y: rect.midY + size.height / 2)
            g.scaleBy(x: 1, y: -1)
            g.draw(image, in: CGRect(origin: .zero, size: size))
            return
        }
        guard let json = frame.displayJSON else {
            BoardPainter.draw(
                BoardFrame(page: frame.page, selected: nil, reference: nil), drag: nil, in: g, bounds: rect)
            return
        }
        guard let records = (try? JSONSerialization.jsonObject(with: json)) as? [[String: Any]] else { return }
        let ordered = records.enumerated().sorted {
            let a = $0.element["z"] as? Int ?? 0
            let b = $1.element["z"] as? Int ?? 0
            return a == b ? $0.offset < $1.offset : a < b
        }
        let shapes = ordered.flatMap { primitives($0.element) }
        var extent = CGRect(x: 0, y: 0, width: 900, height: 900)
        for shape in shapes { extent = extent.union(shape.bounds) }
        let margin = min(8, min(rect.width, rect.height) / 20)
        let fit = min((rect.width - 2 * margin) / extent.width, (rect.height - 2 * margin) / extent.height)
        g.translateBy(x: rect.midX - extent.midX * fit, y: rect.midY - extent.midY * fit)
        g.scaleBy(x: fit, y: fit)
        drawBoard(frame.board, in: g)
        for shape in shapes { shape.draw(g) }
    }

    private enum Primitive {
        case fill(CGPath, CGColor)
        case rim(CGPath, CGPath, CGColor)
        case stroke(CGPath, CGColor, CGFloat, Bool)
        case text(CTLine, CGPoint, CGRect, CGColor)
        var bounds: CGRect {
            switch self {
            case .fill(let path, _), .rim(let path, _, _): return path.boundingBoxOfPath
            case .stroke(let path, _, let width, _):
                return path.copy(strokingWithWidth: width, lineCap: .round, lineJoin: .round, miterLimit: 10)
                    .boundingBoxOfPath
            case .text(_, _, let bounds, _): return bounds
            }
        }
        func draw(_ g: CGContext) {
            g.saveGState()
            defer { g.restoreGState() }
            switch self {
            case .fill(let path, let color):
                g.setFillColor(color)
                g.addPath(path)
                g.fillPath(using: .evenOdd)
            case .rim(let outer, let inner, let color):
                g.beginTransparencyLayer(auxiliaryInfo: nil)
                g.setFillColor(color)
                g.addPath(outer)
                g.fillPath()
                g.setBlendMode(.clear)
                g.addPath(inner)
                g.fillPath()
                g.endTransparencyLayer()
            case .stroke(let path, let color, let width, let dash):
                g.setLineCap(.round)
                g.setLineJoin(.round)
                g.setLineWidth(width)
                g.setStrokeColor(color)
                if dash { g.setLineDash(phase: 0, lengths: [width * 5, width * 3]) }
                g.addPath(path)
                g.strokePath()
            case .text(let line, let origin, _, let color):
                g.translateBy(x: origin.x, y: origin.y)
                g.scaleBy(x: 1, y: -1)
                g.textMatrix = .identity
                g.textPosition = .zero
                g.setFillColor(color)
                CTLineDraw(line, g)
            }
        }
    }

    // Geometry is normalized to a 900-unit board. Anchors and role flags
    // describe the historical geometry and do not alter it.
    private static func primitives(_ o: [String: Any]) -> [Primitive] {
        guard let type = o["type"] as? String, ReplayExchange.known.contains(type) else { return [] }
        let unit = 900.0 / 1_000_000
        func length(_ key: String) -> CGFloat { CGFloat(o[key] as? Int ?? 0) * unit }
        func point(_ ns: [Int]) -> CGPoint { CGPoint(x: CGFloat(ns[0]) * unit, y: CGFloat(ns[1]) * unit) }
        func color(_ value: Any?) -> CGColor {
            let argb = UInt32((value as? String ?? "").dropFirst(), radix: 16) ?? 0
            func component(_ shift: UInt32) -> CGFloat { CGFloat((argb >> shift) & 255) / 255 }
            return CGColor(srgbRed: component(16), green: component(8), blue: component(0), alpha: component(24))
        }
        let width = length("width")
        let path = CGMutablePath()
        if let box = o["bounds"] as? [Int], box.count == 4 {
            let p = point(box)
            let rect = CGRect(
                x: p.x, y: p.y, width: CGFloat(box[2] - box[0]) * unit, height: CGFloat(box[3] - box[1]) * unit)
            if o["type"] as? String == "highlight" {
                return [.fill(CGPath(rect: rect, transform: nil), color(o["fill"]))]
            }
            let circle = o["shape"] as? String == "circle"
            if circle {
                path.addEllipse(in: rect)
            } else {
                path.move(to: p)
                path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
                path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
                path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            }
            var shapes: [Primitive] = [.stroke(path, color(o["color"]), width, false)]
            if let outline = o["outline"] as? [String: Any] {
                let gap = CGFloat(outline["gap"] as? Int ?? 0) * unit
                let rim = CGFloat(outline["width"] as? Int ?? 0) * unit
                func expanded(_ n: CGFloat) -> CGPath {
                    circle
                        ? CGPath(ellipseIn: rect.insetBy(dx: -n, dy: -n), transform: nil)
                        : path.copy(strokingWithWidth: width + 2 * n, lineCap: .round, lineJoin: .round, miterLimit: 10)
                }
                shapes.append(.rim(expanded(gap + rim), expanded(gap), color(outline["color"])))
            }
            return shapes
        }
        if let coords = o["points"] as? [[Int]], !coords.isEmpty, coords.allSatisfy({ $0.count == 2 }) {
            let points = coords.map(point)
            path.move(to: points[0])
            for p in points.dropFirst() { path.addLine(to: p) }
            if o["type"] as? String == "region" {
                path.closeSubpath()
                return [.fill(path, color(o["fill"])), .stroke(path, color(o["stroke"]), width, false)]
            }
            let stroke = color(o["color"])
            var shapes: [Primitive] = [.stroke(path, stroke, width, o["dash"] as? String == "dashed")]
            func arrow(_ tip: CGPoint, _ near: CGPoint) -> Primitive {
                let len = hypot(tip.x - near.x, tip.y - near.y)
                let dx = (tip.x - near.x) / len
                let dy = (tip.y - near.y) / len
                let base = CGPoint(x: tip.x - 8 * width * dx, y: tip.y - 8 * width * dy)
                let triangle = CGMutablePath()
                triangle.move(to: tip)
                triangle.addLine(to: CGPoint(x: base.x - 2 * width * dy, y: base.y + 2 * width * dx))
                triangle.addLine(to: CGPoint(x: base.x + 2 * width * dy, y: base.y - 2 * width * dx))
                triangle.closeSubpath()
                return .fill(triangle, stroke)
            }
            let arrows = o["arrow"] as? String
            if arrows == "both" || arrows == "start", let near = points.first(where: { $0 != points[0] }) {
                shapes.append(arrow(points[0], near))
            }
            if arrows == "both" || arrows == "end", let tip = points.last, let near = points.last(where: { $0 != tip })
            {
                shapes.append(arrow(tip, near))
            }
            return shapes
        }
        if let at = o["at"] as? [Int], at.count == 2, let text = o["text"] as? String, !text.isEmpty {
            let font = CTFontCreateWithName("Helvetica" as CFString, length("fontSize"), nil)
            let line = CTLineCreateWithAttributedString(
                NSAttributedString(
                    string: text,
                    attributes: [
                        NSAttributedString.Key(kCTFontAttributeName as String): font,
                        NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
                    ]))
            var origin = point(at)
            let align = o["align"] as? String
            let advance = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
            origin.x -= align == "right" ? advance : (align == "center" ? advance / 2 : 0)
            let local = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
            let bounds = CGRect(
                x: origin.x + local.minX, y: origin.y - local.maxY, width: local.width, height: local.height)
            return [.text(line, origin, bounds, color(o["color"]))]
        }
        return []
    }
    private static func drawBoard(_ board: NativeBoardSnapshot, in g: CGContext) {
        let black = CGColor(gray: 0, alpha: 1)
        g.setFillColor(black)
        g.setStrokeColor(black)
        let regular = CTFontCreateWithName("Helvetica" as CFString, 64, nil)
        let bold = CTFontCreateWithName("Helvetica-Bold" as CFString, 64, nil)
        let small = CTFontCreateWithName("Helvetica" as CFString, 24, nil)
        func digit(_ d: Int, _ x: CGFloat, _ y: CGFloat, _ font: CTFont) {
            var char = UniChar(48 + d)
            var glyph = CGGlyph()
            guard CTFontGetGlyphsForCharacters(font, &char, &glyph, 1) else { return }
            let bounds = CTFontGetBoundingRectsForGlyphs(font, .horizontal, &glyph, nil, 1)
            g.saveGState()
            g.translateBy(x: x, y: y)
            g.scaleBy(x: 1, y: -1)
            g.textMatrix = .identity
            var position = CGPoint(x: -bounds.midX, y: -bounds.midY)
            CTFontDrawGlyphs(font, &glyph, &position, 1, g)
            g.restoreGState()
        }
        for cell in 0..<81 {
            let x = CGFloat(cell % 9) * 100
            let y = CGFloat(cell / 9) * 100
            if board.values[cell] > 0 {
                digit(Int(board.values[cell]), x + 50, y + 50, board.fixed[cell] ? bold : regular)
            } else {
                for d in 0..<9 where board.candidates[cell] & (1 << d) != 0 {
                    digit(d + 1, x + (CGFloat(d % 3) + 0.5) * 100 / 3, y + (CGFloat(d / 3) + 0.5) * 100 / 3, small)
                }
            }
        }
        for i in 0...9 {
            let p = CGFloat(100 * i)
            g.setLineWidth(i % 3 == 0 ? 3 : 1)
            g.move(to: CGPoint(x: p, y: 0))
            g.addLine(to: CGPoint(x: p, y: 900))
            g.move(to: CGPoint(x: 0, y: p))
            g.addLine(to: CGPoint(x: 900, y: p))
            g.strokePath()
        }
    }
}
