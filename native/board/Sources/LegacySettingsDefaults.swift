// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import HodokuEngine

/// XMLEncoder writes many values as references to getters on a freshly constructed Options.
/// Unsorted positions and these property defaults come from LegacySettingsOracle schema (frozen Java).
enum LegacySettingsDefaults {
    static let rows: [[String]] = {
        var length = 0
        let pointer = hodoku_logic_default_rules_v1(&length)!
        let text = String(decoding: UnsafeBufferPointer(start:pointer, count:length), as:UTF8.self)
        return text.split(separator:"\n").map { $0.split(separator:" ").map(String.init) }
    }()
    static let properties = Set("""
        actLevel adminScore aktCellColor allStepsAllowAlsInTablingChains allStepsAllowAlsOverlap
        allStepsAlsChainForwardOnly allStepsAlsChainLength allStepsCheckTemplates allStepsEnabled allStepsFishCandidates
        allStepsKrakenFishCandidates allStepsKrakenMaxFishSize allStepsKrakenMaxFishType allStepsKrakenMinFishSize
        allStepsMaxEndoFins allStepsMaxFins allStepsMaxFishSize allStepsMaxFishType allStepsMaxKrakenEndoFins
        allStepsMaxKrakenFins allStepsMinFishSize allStepsOnlyOneAlsPerStep allStepsSearchFish allStepsSortMode
        allowAlsInTablingChains allowAlsOverlap allowDualsAndSiamese allowErsWithOnlyTwoCandidates
        allowUniquenessMissingCandidates alternateCellColor annotationPalettePreferences
        annotationPalettePreferencesInitialized anzTableLookAhead appearanceMode arrowColor autoHighlighting
        backgroundColor baseScore bdsSearchCandidatesAnz bdsSearchForCandidates bdsSearchForCells bigFont boxLineFactor
        boxSelectionGroup candidateColor candidateColoring candidateFontFactor category cellColoring cellFixedValueColor
        cellValueColor checkTemplates colorCells colorKuColors colorValues coloringColors coloringVisible
        cursorFrameSize customFontSize defaultCandidateFont defaultCellColor defaultFileDir defaultImageDir
        defaultValueFont deleteCursorDisplay deleteCursorDisplayLength deviationColor difficultyLevels doodle drawMode
        editModeAutoAdvance enabled enabledProgress enabledTraining fishDisplayMode foregroundColor freeChainGroup
        gameMode generatorPatternIndex generatorPatterns gridColor highlightingGivens hintBackFactor
        hintCandidateAlsBackColors hintCandidateAlsColors hintCandidateBackColor hintCandidateCannibalisticBackColor
        hintCandidateCannibalisticColor hintCandidateColor hintCandidateDeleteBackColor hintCandidateDeleteColor
        hintCandidateEndoFinBackColor hintCandidateEndoFinColor hintCandidateFinBackColor hintCandidateFinColor
        historyOfCreatedPuzzles historyPreview historySize index indexProgress initialDisplayMode initialExtendedState
        initialHeight initialHorzDividerLoc initialScreenDeviceId initialVertDividerLoc initialWidth initialXPos
        initialYPos innerGridColor invalidCellColor invalidCells krakenMaxFishSize krakenMaxFishType laf language
        learningPuzzles level markInvalidLinks maxEndoFins maxFins maxKrakenEndoFins maxKrakenFins maxScore
        maxTableEntryLength name normalPuzzles onlyOneAlsPerStep onlyOneChainPerStep onlyOneFishPerStep onlySmallCursors
        onlySmallFilters operationSoundsEnabled ordinal orgSolverSteps paletteGroup pattern possibleCellColor
        possibleFixedCellColor practisingPuzzles practisingPuzzlesLevel primaryCustom primarySlot restrictChainLength
        restrictChainSize restrictNiceLoopLength saveWindowLayout secondaryCustom secondarySlot showCandidateHighlight
        showCandidates showColorKu showColorKuAct showDeviations showHintButtonsInToolbar showHintPanel showSudokuSolved
        showToolBar showWrongValues singleClickMode smallFont swapped type useDefaultFontSize useOrInsteadOfAndForFilter
        useShiftForRegionSelect useZeroInsteadOfDot valid valueFontFactor wrongValueColor
        """.split(whereSeparator: { $0.isWhitespace }).map(String.init))
    private static let stepKeys = ["type","index","indexProgress","level","baseScore","adminScore",
                                   "enabled","allStepsEnabled","enabledProgress","enabledTraining","category"]

    static func stepArray(_ name: String) -> LegacyBean {
        var rows = Self.rows
        if name != "orgSolverSteps" {
            let position = name == "solverStepsProgress" ? 2 : 1
            rows.sort { Int($0[position])! < Int($1[position])! }
        }
        let array = LegacyBean("sudoku.StepConfig[]")
        array.length = rows.count
        for (index, row) in rows.enumerated() {
            let step = LegacyBean("sudoku.StepConfig")
            for (column, key) in stepKeys.enumerated() {
                switch column {
                case 0: step.fields[key] = LegacyBean("sudoku.SolutionType", row[column])
                case 10: step.fields[key] = LegacyBean("sudoku.SolutionCategory", row[column])
                case 6...9: step.fields[key] = LegacyBean("boolean", row[column] == "1" ? "true" : "false")
                default: step.fields[key] = LegacyBean("int", row[column])
                }
            }
            array.indexed[index] = step
        }
        return array
    }
}
