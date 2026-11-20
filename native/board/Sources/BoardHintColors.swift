// SPDX-License-Identifier: GPL-3.0-or-later
import CoreGraphics

/// Resolves the colors of the proof candidates actually visible in the current preview.
struct BoardHintColors {
    struct Pair {
        let ink: CGColor
        let fill: CGColor
    }
    let visual: NativeBoardAppearance

    func pair(for role: BoardAnswerDiagram.Role) -> Pair {
        let key: String
        switch role {
        case .premise: key = "hintCandidate"
        case .fin: key = "hintCandidateFin"
        case .endoFin: key = "hintCandidateEndoFin"
        case .deletion: key = "hintCandidateDelete"
        case .cannibalistic: key = "hintCandidateCannibalistic"
        case let .als(i):
            return Pair(ink: visual.color("hintCandidateAlsColors", index: i),
                        fill: visual.color("hintCandidateAlsBackColors", index: i))
        case let .coloring(i):
            return Pair(ink: visual.color("candidateColor"), fill: visual.color("coloringColors", index: i))
        }
        return Pair(ink: visual.color(key + "Color"), fill: visual.color(key + "BackColor"))
    }
}
