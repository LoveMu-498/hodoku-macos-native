// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit

struct NativePaintFont: Codable, Equatable {
    var name: String
    var style: Int
    var size: Int

    func resolve(size override: CGFloat? = nil) -> NSFont {
        let points = override ?? CGFloat(size)
        let manager = NSFontManager.shared
        let logical = ["SansSerif": "Helvetica", "Dialog": "Helvetica", "Serif": "Times",
                       "Monospaced": "Menlo", "DialogInput": "Menlo"]
        var traits = NSFontTraitMask()
        if style & 1 != 0 { traits.insert(.boldFontMask) }
        if style & 2 != 0 { traits.insert(.italicFontMask) }
        let family = logical[name] ?? name
        return manager.font(withFamily: family, traits: traits, weight: 5, size: points)
            ?? manager.convert(NSFont(name: family, size: points) ?? NSFont.systemFont(ofSize: points), toHaveTrait: traits)
    }
}

struct NativeDifficultyAppearance: Codable, Equatable {
    var maxScore: Int32
    var foreground: UInt32
    var background: UInt32
}

struct NativeBoardAppearance: Codable, Equatable {
    // ARGB preserves the alpha byte used by java.awt.Color and XMLEncoder.
    private static let rgbDefaults: [String: [UInt32]] = [
        "gridColor": [0x394452], "innerGridColor": [0xc6cdd6], "cellFixedValueColor": [0x17202a],
        "cellValueColor": [0x175cd3], "candidateColor": [0x5f6b7a], "wrongValueColor": [0xb4233b],
        "deviationColor": [0xc24155], "defaultCellColor": [0xfbfcfe], "alternateCellColor": [0xf4f6f9],
        "aktCellColor": [0xb98b00], "invalidCellColor": [0xffe1e5], "possibleCellColor": [0xddf5ec],
        "possibleFixedCellColor": [0xbfe8da], "hintCandidateColor": [0x176b3a], "hintCandidateBackColor": [0xcfefda],
        "hintCandidateDeleteColor": [0xa61b33], "hintCandidateDeleteBackColor": [0xffd9df],
        "hintCandidateFinColor": [0x1c5f9e], "hintCandidateFinBackColor": [0xd7ecff],
        "hintCandidateEndoFinColor": [0x64409a], "hintCandidateEndoFinBackColor": [0xe7ddf8],
        "hintCandidateCannibalisticColor": [0x8f1428], "hintCandidateCannibalisticBackColor": [0xf7b5c0],
        "arrowColor": [0xb4233b],
        "hintCandidateAlsColors": [0x366522, 0x8b2b3c, 0x17666c, 0x7e530b],
        "hintCandidateAlsBackColors": [0xe3f2d4, 0xf7dde2, 0xd9eef0, 0xf8e7c9],
        "coloringColors": [0xc66400, 0xffc48a, 0x7651d1, 0xcdbeff, 0xc43f7b, 0xf5b1d0,
                            0x008a90, 0x9fe2e0, 0x3f8f42, 0xb8e4a9, 0x3f63ce, 0xb6c7ff],
        "colorKuColors": [0xfc1410, 0xfb9900, 0xffda1b, 0x00c029, 0x002dff, 0xdd54b1, 0x9ffc33,
                          0x90f6f9, 0xffaffc, 0x000000, 0x808080]
    ]
    static let colorDefaults = rgbDefaults.mapValues { $0.map { $0 | 0xff000000 } }
    static let fontDefaults = [
        "defaultValueFont": NativePaintFont(name: "Tahoma", style: 0, size: 10),
        "defaultCandidateFont": NativePaintFont(name: "Tahoma", style: 0, size: 10),
        "bigFont": NativePaintFont(name: "Arial", style: 1, size: 16),
        "smallFont": NativePaintFont(name: "Arial", style: 0, size: 10)]
    static let factorDefaults = ["valueFontFactor": 0.6, "candidateFontFactor": 0.25, "hintBackFactor": 1.6, "boxLineFactor": 1.5]
    static let levelNames = ["未完成", "容易", "中等", "困难", "艰难", "极难"]
    static let levelDefaults: [NativeDifficultyAppearance] = [
        (0, 0x000000), (800, 0xffffff), (1000, 0x64ff64), (1600, 0xffff64), (1800, 0xff9650), (Int32.max, 0xff6464)
    ].enumerated().map { index, item in
        .init(maxScore: item.0, foreground: index == 0 ? 0xffffffff : 0xff000000, background: UInt32(item.1) | 0xff000000)
    }

    var colors = Self.colorDefaults
    // Some older Java palettes have five pairs. Only a newly edited sixth pair needs an expanded array on export.
    var legacyColorLengths: [String: Int]?
    var fonts = Self.fontDefaults
    var factors = Self.factorDefaults
    var levels = Self.levelDefaults

    static func cgColor(_ value: UInt32, alpha: CGFloat = 1) -> CGColor {
        CGColor(srgbRed: CGFloat(value >> 16 & 255) / 255, green: CGFloat(value >> 8 & 255) / 255,
                blue: CGFloat(value & 255) / 255, alpha: CGFloat(value >> 24) / 255 * alpha)
    }
    func color(_ key: String, index: Int = 0, alpha: CGFloat = 1) -> CGColor {
        Self.cgColor(colors[key]![index], alpha: alpha)
    }
    func annotationColor(_ group: Int, light: Bool = false, alpha: CGFloat = 1) -> CGColor {
        color("coloringColors", index: group * 2 + (light ? 1 : 0), alpha: alpha)
    }

    func validate() throws {
        guard levels.count == Self.levelDefaults.count,
              Set(fonts.keys) == Set(Self.fontDefaults.keys), Set(factors.keys) == Set(Self.factorDefaults.keys),
              colors.mapValues(\.count) == Self.colorDefaults.mapValues(\.count),
              factors.values.allSatisfy({ $0.isFinite && $0 > 0 }),
              fonts.values.allSatisfy({ !$0.name.isEmpty && $0.size > 0 && (0...3).contains($0.style) })
        else { throw WorkspaceProblem("请检查字体、尺寸与颜色设置。") }
    }
    init() {}
}
