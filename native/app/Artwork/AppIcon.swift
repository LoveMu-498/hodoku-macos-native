// SPDX-License-Identifier: GPL-3.0-or-later
import CoreGraphics
import Foundation
import ImageIO

private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

private func color(_ hex: Int, alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(hex >> 16 & 255) / 255,
            green: CGFloat(hex >> 8 & 255) / 255,
            blue: CGFloat(hex & 255) / 255, alpha: alpha)
}

private func drawIcon(size: Int) throws -> CGImage {
    guard let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: colorSpace,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { throw CocoaError(.fileWriteUnknown) }
    context.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)

    func outline(_ rect: CGRect, radius: CGFloat) -> CGPath {
        CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    }
    func gradient(_ path: CGPath, from top: Int, to bottom: Int) {
        context.saveGState()
        context.addPath(path)
        context.clip()
        let bounds = path.boundingBoxOfPath
        let gradient = CGGradient(colorsSpace: colorSpace, colors: [color(top), color(bottom)] as CFArray, locations: nil)!
        context.drawLinearGradient(gradient, start: CGPoint(x: bounds.minX, y: bounds.maxY),
                                   end: CGPoint(x: bounds.maxX, y: bounds.minY), options: [])
        context.restoreGState()
    }
    func stroke(_ path: CGPath, _ width: CGFloat, _ ink: CGColor) {
        context.addPath(path)
        context.setLineWidth(width)
        context.setStrokeColor(ink)
        context.strokePath()
    }

    let plate = outline(CGRect(x: 94, y: 104, width: 836, height: 836), radius: 188)
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -20), blur: size < 64 ? 0 : 35,
                      color: color(0x06121F, alpha: 0.48))
    context.addPath(plate)
    context.setFillColor(color(0x101E34))
    context.fillPath()
    context.restoreGState()
    gradient(plate, from: 0x254F69, to: 0x0C1529)
    stroke(plate, 9, color(0xA6DCF6, alpha: 0.24))

    let well = outline(CGRect(x: 198, y: 208, width: 628, height: 628), radius: 92)
    gradient(well, from: 0x101C2E, to: 0x192C43)
    stroke(well, 6, color(0x9DCEE6, alpha: 0.22))

    for row in 0..<3 {
        for column in 0..<3 {
            let rect = CGRect(x: 237 + 190 * column, y: 627 - 190 * row, width: 170, height: 170)
            let tile = outline(rect, radius: 36)
            let center = row == 1 && column == 1
            let cue = (row == 0 && column == 2) || (row == 2 && column == 0)
            if center {
                gradient(tile, from: 0xB6FFF2, to: 0x38D4B2)
                stroke(tile, 5, color(0xDCFFF6, alpha: 0.67))
            } else {
                gradient(tile, from: cue ? 0x5585A1 : 0x385674, to: cue ? 0x31546E : 0x243952)
                stroke(tile, 4, color(0xA6D1EC, alpha: 0.20))
            }
        }
    }
    let check = CGMutablePath()
    check.move(to: CGPoint(x: 468, y: 521))
    check.addLine(to: CGPoint(x: 500, y: 490))
    check.addLine(to: CGPoint(x: 555, y: 550))
    context.setLineCap(.round)
    context.setLineJoin(.round)
    stroke(check, 24, color(0x103B45))

    guard let image = context.makeImage() else { throw CocoaError(.fileWriteUnknown) }
    return image
}

@main private enum AppIcon {
    static func main() throws {
        let iconset = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
        for base in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let suffix = scale == 2 ? "@2x" : ""
                let png = iconset.appendingPathComponent("icon_\(base)x\(base)\(suffix).png")
                guard let output = CGImageDestinationCreateWithURL(png as CFURL, "public.png" as CFString, 1, nil)
                else { throw CocoaError(.fileWriteUnknown) }
                CGImageDestinationAddImage(output, try drawIcon(size: base * scale), nil)
                guard CGImageDestinationFinalize(output) else { throw CocoaError(.fileWriteUnknown) }
            }
        }
    }
}
