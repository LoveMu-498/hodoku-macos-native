// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit

enum BoardColorMode {
    case light, dark, print
    static var screen: Self {
        NSApp?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .dark : .light
    }
}

extension NativeBoardAppearance {
    // SudokuAppearancePalette maps only factory swatches. User-selected ARGB values survive
    // both appearance changes and Java re-export. Print uses the configured palette unchanged.
    private static let lightScreen: [String: [UInt32]] = [
        "candidateColor": [0x435064], "aktCellColor": [0xf59e0b], "arrowColor": [0xff0000],
        "hintCandidateBackColor": [0x3fda65], "hintCandidateDeleteBackColor": [0xff7684],
        "hintCandidateCannibalisticBackColor": [0xeb0000], "hintCandidateFinBackColor": [0x7fbbff],
        "hintCandidateEndoFinBackColor": [0xd8b2ff], "hintCandidateAlsBackColors": [0xc5e88c, 0xffcbcb, 0xb2dfdf, 0xfcdca5],
        "hintCandidateColor": [0], "hintCandidateDeleteColor": [0], "hintCandidateCannibalisticColor": [0],
        "hintCandidateFinColor": [0], "hintCandidateEndoFinColor": [0], "hintCandidateAlsColors": [0,0,0,0]
    ]
    private static let darkScreen: [String: [UInt32]] = [
        "defaultCellColor": [0x22272e], "alternateCellColor": [0x272d35], "cellFixedValueColor": [0xf2f0ea],
        "cellValueColor": [0x77b7ff], "candidateColor": [0xb6bdc8], "innerGridColor": [0x525b68], "gridColor": [0x9aa5b4],
        "aktCellColor": [0xffe066], "possibleCellColor": [0x24473b], "possibleFixedCellColor": [0x315447],
        "invalidCellColor": [0x5a2530], "wrongValueColor": [0xff9cad], "deviationColor": [0xffb0bc],
        "hintCandidateBackColor": [0x23523a], "hintCandidateDeleteBackColor": [0x5b2933],
        "hintCandidateCannibalisticBackColor": [0x6b2d39], "hintCandidateFinBackColor": [0x253f5a],
        "hintCandidateEndoFinBackColor": [0x3f3158], "hintCandidateColor": [0x91e2af], "hintCandidateDeleteColor": [0xff9cac],
        "hintCandidateCannibalisticColor": [0xffb1bd], "hintCandidateFinColor": [0x8bc7ff], "hintCandidateEndoFinColor": [0xc7afff],
        "hintCandidateAlsBackColors": [0x31452b, 0x4a3037, 0x294347, 0x4a3c24],
        "hintCandidateAlsColors": [0xb8e4a9, 0xffb1bd, 0x9fe2e0, 0xffc48a], "arrowColor": [0xff7183]
    ]

    func rendered(_ mode: BoardColorMode) -> Self {
        guard mode != .print else { return self }
        var result = self
        for (key, mapped) in mode == .dark ? Self.darkScreen : Self.lightScreen {
            for index in mapped.indices where colors[key]![index] == Self.colorDefaults[key]![index] {
                result.colors[key]![index] = mapped[index] | 0xff000000
            }
        }
        return result
    }

    func levelColors(_ index: Int, dark: Bool) -> NativeDifficultyAppearance {
        var level = levels[index]
        if dark {
            let defaults = Self.levelDefaults[index]
            let backgrounds: [UInt32] = [0xff2b2e33, 0xff2a2e32, 0xff294335, 0xff4a4628, 0xff5a3b28, 0xff5b3035]
            if level.background == defaults.background { level.background = backgrounds[index] }
            if level.foreground == defaults.foreground { level.foreground = 0xfff2f0e9 }
        }
        return level
    }
}

enum CandidateFilterColors {
    static func accent(forCount count: Int? = nil, mode: BoardColorMode) -> CGColor {
        let hex: UInt32
        switch count {
        case 2: hex = mode == .dark ? 0xb2cee7 : 0x526980
        case 3: hex = mode == .dark ? 0xe2b0bf : 0x914c40
        default: hex = mode == .dark ? 0x9cd0b6 : 0x2c694f
        }
        return NativeBoardAppearance.cgColor(0xff000000 | hex)
    }

    static func fill(forCount count: Int, mode: BoardColorMode) -> CGColor {
        let hex: UInt32
        if count == 2 {
            hex = mode == .dark ? 0x344759 : 0xdce6f1
        } else {
            hex = mode == .dark ? 0x533b46 : 0xf1dcd4
        }
        return NativeBoardAppearance.cgColor(0xff000000 | hex)
    }
}
