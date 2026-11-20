// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import CoreText

/// The box keeps the row visually aligned, while the ink centroid compensates
/// for asymmetric figures such as 4 and 7. Measure the actual configured face.
final class BoardDigitGlyphs {
    private struct Glyph {
        let path: CGPath
        let bounds: CGRect
        let center: CGPoint
    }
    private let digits: [Glyph?]
    private static let cache: NSCache<NSFont, BoardDigitGlyphs> = {
        let cache = NSCache<NSFont, BoardDigitGlyphs>()
        cache.countLimit = 24
        return cache
    }()

    static func forFont(_ font: NSFont) -> BoardDigitGlyphs {
        if let glyphs = cache.object(forKey: font) { return glyphs }
        let glyphs = BoardDigitGlyphs(font)
        cache.setObject(glyphs, forKey: font)
        return glyphs
    }

    private init(_ font: CTFont) {
        digits = (0...9).map { digit in
            var character = UniChar(48 + digit)
            var glyph = CGGlyph()
            guard CTFontGetGlyphsForCharacters(font, &character, &glyph, 1),
                  let path = CTFontCreatePathForGlyph(font, glyph, nil) else { return nil }
            let bounds = path.boundingBoxOfPath
            guard bounds.width > 0, bounds.height > 0 else { return nil }
            let ink = Self.inkCentroid(path, bounds: bounds)
            let center = CGPoint(x: bounds.midX + (ink.x - bounds.midX) * 0.75,
                                 y: bounds.midY + (ink.y - bounds.midY) * 0.3)
            return Glyph(path: path, bounds: bounds, center: center)
        }
    }

    private static func inkCentroid(_ path: CGPath, bounds: CGRect) -> CGPoint {
        let size = 48
        let side = CGFloat(size - 2)
        guard let mask = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                                   bytesPerRow: size, space: CGColorSpaceCreateDeviceGray(),
                                   bitmapInfo: CGImageAlphaInfo.none.rawValue),
              let pixels = mask.data?.assumingMemoryBound(to: UInt8.self) else {
            return CGPoint(x: bounds.midX, y: bounds.midY)
        }
        mask.translateBy(x: 1, y: CGFloat(size - 1))
        mask.scaleBy(x: side / bounds.width, y: -side / bounds.height)
        mask.translateBy(x: -bounds.minX, y: -bounds.minY)
        mask.setFillColor(gray: 1, alpha: 1)
        mask.addPath(path)
        mask.fillPath()
        mask.flush()
        var area = 0, xMoment = 0, yMoment = 0
        for row in 0..<size {
            for column in 0..<size {
                let coverage = Int(pixels[row * size + column])
                area += coverage
                xMoment += coverage * column
                yMoment += coverage * row
            }
        }
        guard area > 0 else { return CGPoint(x: bounds.midX, y: bounds.midY) }
        return CGPoint(x: bounds.minX + bounds.width * (CGFloat(xMoment) / CGFloat(area) - 0.5) / side,
                       y: bounds.minY + bounds.height * (CGFloat(yMoment) / CGFloat(area) - 0.5) / side)
    }

    /// Returns the visible ink bounds, used to keep link strokes out of the numbers.
    @discardableResult
    func draw(_ digit: Int, in slot: CGRect, candidate: Bool, color: CGColor, context: CGContext) -> CGRect? {
        guard digits.indices.contains(digit), let glyph = digits[digit] else { return nil }
        let radiusX = max(glyph.center.x - glyph.bounds.minX, glyph.bounds.maxX - glyph.center.x)
        let radiusY = max(glyph.center.y - glyph.bounds.minY, glyph.bounds.maxY - glyph.center.y)
        let fraction: CGFloat = candidate ? 0.335 : 0.43
        let scale = min(1, slot.width * fraction / radiusX, slot.height * fraction / radiusY)
        let transform = CGAffineTransform(a: scale, b: 0, c: 0, d: -scale,
            tx: slot.midX - glyph.center.x * scale, ty: slot.midY + glyph.center.y * scale)
        context.saveGState()
        context.concatenate(transform)
        context.setFillColor(color)
        context.addPath(glyph.path)
        context.fillPath()
        context.restoreGState()
        return glyph.bounds.applying(transform)
    }
}
