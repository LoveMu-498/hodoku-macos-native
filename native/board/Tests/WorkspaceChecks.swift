// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import Foundation

#if !COMBINED_BOARD_CHECKS
@main
#endif
enum WorkspaceChecks {
    private struct Failure: Error, CustomStringConvertible { let description: String }
    private static func check(_ match: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try match() else { throw Failure(description: message) }
    }
    private static func launch(_ workspace: NativeDesktopWorkspace, file: URL? = nil) throws -> Bool {
        var response: Bool?
        workspace.start(explicit: file) { response = $0 }
        let deadline = Date().addingTimeInterval(15)
        while response == nil && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        guard let result = response else { throw Failure(description: "Opening timed out") }
        return result
    }
    static func main() throws {
        let fm = FileManager.default
        guard let profile = ProcessInfo.processInfo.environment["HODOKU_NATIVE_DATA_DIR"] else { throw BoardFileError.unsafeLocation }
        let root = URL(fileURLWithPath: profile).appendingPathComponent("workspace-" + UUID().uuidString)
        let legacy = root.appendingPathComponent("Java 旧档")
        let supply = URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent("native/app/Resources/puzzles.tsv")
        print("Temporary workspace checks: \(root.path); remove after tests")
        try fm.createDirectory(at: legacy, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let xml = legacy.appendingPathComponent("last-session.xml")
        let backup = xml.appendingPathExtension("bak")
        let valid = Data("""
        <java class="java.beans.XMLDecoder"><object class="sudoku.SessionSnapshot">
        <void property="guiState"><object class="sudoku.GuiState"><void property="name"><string>旧现场</string></void>
        <void property="sudoku"><object class="sudoku.Sudoku2"/></void></object></void>
        </object></java>
        """.utf8)
        let damaged = Data("broken Java main".utf8)
        try damaged.write(to: xml)
        try valid.write(to: backup)
        let dir = root.appendingPathComponent("独立进度")
        let auto = NativeDesktopWorkspace(directory: dir, legacyRoot: legacy, supply: supply)
        try check(try launch(auto), "Java backup import: " + (auto.message ?? ""))
        try check(auto.board.progress.extra?.sourceSessionXML == valid && auto.board.progress.extra?.name == "旧现场", "Java source provenance")
        auto.board.select(0)
        auto.board.edit(3)
        try check(auto.beginQuit(), "quit imported game")
        let restart = NativeDesktopWorkspace(directory: dir, legacyRoot: legacy, supply: supply)
        try check(try launch(restart) && restart.board.progress.current.board.values[0] == 3 && restart.board.selected == 0, "native restart precedence")
        let explicit = root.appendingPathComponent("指定题面.txt")
        let clues = "530070000600195000098000060800060003400803001700020006060000280000419005000080079"
        try Data(clues.utf8).write(to: explicit)
        let selected = NativeDesktopWorkspace(directory: dir, legacyRoot: legacy, supply: supply)
        try check(try launch(selected, file: explicit) && NativeDesktopWorkspace.clues(selected.board.progress.current.board) == clues, "explicit precedence")
        let rated = try NativeLogicalEngine.rate(selected.board.progress.current.board, fromClues: true, cancelled: { false })
        try check(rated.solved && rated.score == selected.board.progress.extra?.score, "file rating used clue queues")
        let retiredSettings = root.appendingPathComponent("旧设置")
        try fm.createDirectory(at: retiredSettings, withIntermediateDirectories: false)
        for file in ["hodoku.hcfg", "hodoku.hcfg.bak"] {
            let path = retiredSettings.appendingPathComponent(file)
            try valid.write(to: path)
            do { _ = try NativeDesktopWorkspace.decode(path); throw Failure(description: "Java settings are still dispatched") }
            catch is WorkspaceProblem {}
        }
        let first = NativeDesktopWorkspace(directory: root.appendingPathComponent("首次启动"), legacyRoot: retiredSettings, supply: supply)
        var firstResult: Bool?
        first.start { firstResult = $0 }
        try check(first.message == nil && first.generating && !first.board.writable && !fm.fileExists(atPath: first.board.store.file.path),
                  "opening with no save starts generation without exposing or saving the built-in sample")
        let firstDeadline = Date(timeIntervalSinceNow: 15)
        while firstResult == nil && Date() < firstDeadline { RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01)) }
        try check(firstResult == true && first.board.writable && first.board.store.hasSavedProgress &&
                  first.board.progress.extra?.requestedDifficulty != nil, "first launch installed a generated game")
        let brokenDirectory = root.appendingPathComponent("无法恢复")
        try fm.createDirectory(at: brokenDirectory, withIntermediateDirectories: false)
        let broken = NativeDesktopWorkspace(directory: brokenDirectory, supply: supply)
        try damaged.write(to: broken.board.store.file)
        try check(try !launch(broken) && !broken.generating && !broken.board.writable &&
                  Data(contentsOf: broken.board.store.file) == damaged, "unreadable progress stays available for recovery")
        print("PASS first launch generates a durable puzzle, damaged progress is kept")
        // A control writes through the workspace on selection, before navigating away or quitting.
        let preferencesFile = dir.appendingPathComponent("settings-v1.json")
        let preferencesBefore = selected.preferences
        var changed = preferencesBefore
        changed.mouse?.showCandidates.toggle()
        changed.general?.showColorKu.toggle()
        var patterns = NativePatternSettings()
        var mask = NativeCluePattern(name: "即时")
        mask.cells = Array(repeating: true, count: 81)
        mask.cells[8] = false
        try NativeLiveGenerator.checkPattern(mask, seed: 4, cancelled: { false })
        mask.valid = true
        patterns.patterns = [mask]
        patterns.selection = 0
        changed.generatorPatterns = patterns
        try selected.updatePreferences(changed)
        try check(selected.board.mouseOptions.showCandidates == changed.mouse?.showCandidates &&
                  selected.board.generalOptions.showColorKu == changed.general?.showColorKu, "live board settings")
        let written = try Data(contentsOf: preferencesFile)
        try check(try JSONDecoder().decode(NativeWorkspacePreferences.self, from: written) == selected.preferences,
                  "immediate settings were not committed before navigation")
        let reopened = NativeDesktopWorkspace(directory: dir, legacyRoot: legacy, supply: supply)
        try check(try launch(reopened) && reopened.board.mouseOptions == selected.board.mouseOptions &&
                  reopened.preferences.generatorPatterns == patterns, "relaunch did not restore immediately committed settings")
        // A failed preference edit must leave the active board and the previous on-disk value intact.
        let held = dir.appendingPathComponent("settings-previous.json")
        try fm.moveItem(at: preferencesFile, to: held)
        try fm.createDirectory(at: preferencesFile, withIntermediateDirectories: false)
        do { try selected.updatePreferences(preferencesBefore); throw Failure(description: "unwritable settings accepted") }
        catch let e as Failure { throw e } catch {}
        try check(selected.preferences == changed && (try Data(contentsOf: held)) == written, "failed change escaped into live settings")
        try fm.removeItem(at: preferencesFile)
        try fm.moveItem(at: held, to: preferencesFile)
        try selected.updatePreferences(preferencesBefore)
        print("PASS immediate settings update, independent restart before quit, and write failure with retry")
        let dialog = NativeDesktopWorkspace(directory: root.appendingPathComponent("对话框"), supply: supply)
        try check(try launch(dialog, file: explicit), "dialog isolation")
        dialog.commandDialogOpen = true
        let source = dialog.board.progress.current
        let sourceID = dialog.board.recorder.document.id
        var importError: Error?
        var imported: Bool?
        func waitForImport() {
            let deadline = Date().addingTimeInterval(5)
            while imported == nil && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        }
        dialog.pastePuzzle("invalid grid", feedback: false, onError: { importError = $0 }) { imported = $0 }
        waitForImport()
        try check(imported == false && importError != nil && dialog.message == nil &&
                  source == dialog.board.progress.current && sourceID == dialog.board.recorder.document.id,
                  "invalid import reports inside the dialog and retains the active attempt")
        imported = nil
        dialog.pastePuzzle(clues, feedback: false, finished: { imported = $0 })
        dialog.cancelOpening()
        waitForImport()
        try check(imported == false && !dialog.opening && sourceID == dialog.board.recorder.document.id,
                  "cancelled import cannot install its late result")
        imported = nil
        dialog.pastePuzzle(clues, feedback: false, onError: { importError = $0 }) { imported = $0 }
        waitForImport()
        try check(imported == true && sourceID != dialog.board.recorder.document.id, "confirmed import started a new attempt")

        let pointFile = dialog.board.store.file
        let heldPointFile = pointFile.appendingPathExtension("test")
        try fm.moveItem(at: pointFile, to: heldPointFile)
        try fm.createDirectory(at: pointFile, withIntermediateDirectories: false)
        do { try dialog.board.addGameSavePoint("  复验  "); throw Failure(description: "unwritable save point accepted") }
        catch let e as Failure { throw e } catch {}
        try check(dialog.board.progress.extra?.savePoints?.isEmpty != false, "failed save point leaked into progress")
        try fm.removeItem(at: pointFile)
        try fm.moveItem(at: heldPointFile, to: pointFile)
        try dialog.board.addGameSavePoint("  复验  ")
        let points = dialog.board.progress.extra?.savePoints ?? []
        try check(points.map(\.name) == ["复验"], "retry committed one trimmed save point")
        dialog.board.select(2)
        dialog.board.edit(4)
        try check(dialog.board.progress.current.board.values[2] == 4, "savepoint restoration fixture")
        try dialog.board.restoreGameSavePoint(points[0].progress)
        try check(dialog.board.progress.current == source && dialog.board.progress.extra?.savePoints?.count == 1,
                  "savepoint restoration retains the directory of named points")
        print("PASS isolated dialog operations: invalid input, cancellation before install, import, save-point failure and retry, restoration")
        let priorState = try Data(contentsOf: selected.board.store.file)
        try selected.newGame(level: 4, mode:"PLAYING")
        selected.cancelNewGame()
        try check(!selected.generating && (try Data(contentsOf: selected.board.store.file)) == priorState,
                  "canceled new game replaced the existing independent progress")
        var patched = NativeWorkspacePreferences()
        patched.legacyXML = Data("""
        <java class="java.beans.XMLDecoder"><object class="sudoku.Options">
        <void property="difficultyLevels"><void index="1"><void property="maxScore"><int>200</int></void></void></void>
        <void property="orgSolverSteps"><void index="2"><void property="baseScore"><int>38</int></void></void></void>
        <void property="allowDualsAndSiamese"><boolean>true</boolean></void>
        </object></java>
        """.utf8)
        let policy = try NativeSolverConfig.read(patched)
        try check(policy.requestedLevel(1, mode:"PRACTISING", training:["X_WING","NAKED_SINGLE"]) == 3
                  && policy.requestedLevel(1, mode:"PLAYING", training:["X_WING"]) == 1,
                  "mode menu raised the effective training difficulty")
        let rerated = try NativeLogicalEngine.rate(selected.board.progress.current.board, config:policy,fromClues:true,cancelled:{false})
        let expected = rated.score + 34 * rated.steps.filter { $0.kind == "FULL_HOUSE" }.count
        try check(policy.thresholds[1] == 200 && policy.searchOptions["allowDualsAndSiamese"] == "true"
                  && rerated.solved && rerated.score == expected && rerated.difficulty > 1,
                  "imported Java thresholds, score and family options")

        let invalid = NativeDesktopWorkspace(directory: dir, legacyRoot: legacy, supply: supply)
        try check(!(try launch(invalid, file: root.appendingPathComponent("missing.txt"))) && !invalid.board.writable, "explicit failure fell through")
        try check(try Data(contentsOf: selected.board.store.file) == priorState, "invalid explicit mutated prior game")
        try check(try Data(contentsOf: xml) == damaged && Data(contentsOf: backup) == valid && Data(contentsOf: explicit) == Data(clues.utf8), "originals changed")

        let replayRoot = root.appendingPathComponent("viewer")
        let replayURL = root.appendingPathComponent("原回放.hrep")
        let frameFile = URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent("docs/replay-protocol/fixtures/m2/all-content.hrep.b64")
        let originalReplay = try Data(contentsOf: frameFile)
        guard let replayBytes = Data(base64Encoded: originalReplay, options: .ignoreUnknownCharacters) else { throw BoardFileError.invalid }
        try replayBytes.write(to: replayURL)
        let viewer = NativeDesktopWorkspace(directory: replayRoot, legacyRoot: legacy, supply: supply)
        try check(try launch(viewer, file: replayURL) && viewer.board.reviewing && !viewer.board.writable, "cold explicit replay " + (viewer.message ?? ""))
        try check(viewer.beginQuit() && !fm.fileExists(atPath: viewer.board.store.file.path), "temporary viewer created active board")
        viewer.cancelQuit()
        viewer.board.endReview()
        viewer.reviewingChanged(false)
        try check(viewer.board.writable && viewer.board.progress.extra?.sourceSessionXML == valid, "return from viewer restores actual underlying game")
        try check(try Data(contentsOf: replayURL) == replayBytes, "source replay bytes changed")

        let completedDir = root.appendingPathComponent("completed")
        let completedFile = root.appendingPathComponent("完成的旧局.xml")
        let completedXML = Data(String(decoding: valid, as: UTF8.self).replacingOccurrences(of: "<void property=\"guiState\">",
            with: "<void property=\"completed\"><boolean>true</boolean></void><void property=\"completedLevel\"><int>4</int></void><void property=\"guiState\">").utf8)
        try completedXML.write(to: completedFile)
        let completed = NativeDesktopWorkspace(directory: completedDir, legacyRoot: legacy, supply: supply)
        try check(try launch(completed, file: completedFile) && completed.board.progress.extra?.legacy?.completed == true, "explicit completed session was replaced")
        let automatic = NativeDesktopWorkspace(directory: root.appendingPathComponent("completed-auto"), supply: supply)
        try automatic.apply(NativeDesktopWorkspace.decode(completedFile), automatic: true)
        let generationDeadline = Date().addingTimeInterval(65)
        while automatic.generating && Date() < generationDeadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        try check(automatic.board.progress.extra?.requestedDifficulty == 4 && automatic.board.progress.extra?.legacy == nil, "new game difficulty after completed Java restore")
        try check(try Data(contentsOf: completedFile) == completedXML, "changed completed Java file")

        for name in ["active-replay.json","board-v3.json","settings-v1.json"] {
            let dest = root.appendingPathComponent(name + "-profile")
            let machine = NativeDesktopWorkspace(directory: dest, legacyRoot: legacy, supply: supply)
            try check(try launch(machine, file: explicit) && machine.beginQuit(), "initialize failure test")
            machine.cancelQuit()
            let file = dest.appendingPathComponent(name)
            let held = dest.appendingPathComponent("held")
            try fm.moveItem(at: file, to: held)
            try fm.createDirectory(at: file, withIntermediateDirectories: false)
            try check(!machine.beginQuit() && machine.quitFailure != nil, "failed quit not reported for " + name)
            let receipt = dest.appendingPathComponent("quit-checkpoint.json")
            let checkpoint = try JSONDecoder().decode(WorkspaceCheckpoint.self, from: Data(contentsOf: receipt))
            try check(!checkpoint.clean, "marked failed group clean")
            machine.cancelQuit()
            machine.board.select(2)
            machine.board.edit(4)
            try check(machine.board.progress.current.board.values[2] == 4, "cancel did not resume editing")
            try check(!machine.beginQuit(), "unrepaired target accepted")
            try fm.removeItem(at: file)
            try fm.moveItem(at: held, to: file)
            try check(machine.retryQuit(), "retry failed for " + name + ": " + (machine.quitFailure ?? ""))
            let clean = try JSONDecoder().decode(WorkspaceCheckpoint.self, from: Data(contentsOf: receipt))
            let again = NativeDesktopWorkspace(directory: dest, legacyRoot: legacy, supply: supply)
            try check(clean.clean && (try launch(again)) && again.board.progress.current.board.values[2] == 4, "repaired restart")
        }
        let pool = try NativeNewGameSupply(url: supply)
        for level in 1...5 {
            let game = try pool.next(level: level, mode: "PLAYING", training: [], recent: [])
            try check(game.extra?.difficulty == level && (game.extra?.score ?? 0) > 0, "graded supply")
        }
        for mode in ["LEARNING","PRACTISING"] {
            let game = try pool.next(level: 4, mode: mode, training: ["NAKED_SINGLE"], recent: [])
            try check(game.extra?.mode == mode && (mode == "LEARNING" || game.extra?.difficulty == 4), "training selection")
        }
        let named = root.appendingPathComponent("named.txt")
        let a = Data("a".utf8), b = Data("b".utf8)
        try a.write(to: named)
        try WorkspaceNamedExport.replace(named, expected: a, with: b)
        do { try WorkspaceNamedExport.replace(named, expected: a, with: a); throw Failure(description: "named overwrite") }
        catch BoardFileError.concurrentChange { }
        try check(try Data(contentsOf: named) == b, "named conflict")
        let page = WorkspacePrintView(board: restart.board.frame)
        try check(page.dataWithPDF(inside: page.bounds).starts(with: Data("%PDF".utf8)), "print drawing")
        print("PASS Java backup → native save → restart, explicit precedence and invalid input, original hashes, three independent failures/cancel/edit/retry, catalog grades and modes, named export CAS and printable PDF")
    }
}

// Frozen phase-four reference reader for its Java catalog regression.
private struct NativeNewGameSupply {
    let rows: [String]
    init(url: URL?) throws {
        guard let url = url else { throw WorkspaceProblem("找不到题库文件。请重新打开完整的应用。") }
        rows = try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map(String.init)
    }

    /// Rows are frozen output of the Java generator/solver. Learning starts at the first enabled training step.
    func next(level: Int, mode: String, training: Set<String>, recent: [String]) throws -> BoardProgress {
        var best: (rank: Int, progress: BoardProgress)?
        for row in rows.shuffled() {
            let fields = row.components(separatedBy: "\t")
            guard fields.count >= 4, fields[0].count == 81, let grade = Int(fields[1]), let score = Int(fields[2]) else {
                throw WorkspaceProblem("题库记录不完整。")
            }
            guard grade == level || mode == "LEARNING" else { continue }
            let stages = fields.dropFirst(3).map { $0.components(separatedBy: ":") }
            guard stages.allSatisfy({ $0.count == 4 }) else { throw WorkspaceProblem("缺少题库步骤。") }
            let target = stages.first(where: { training.contains($0[0]) })
            guard mode == "PLAYING" || target != nil else { continue }
            let rank = recent.firstIndex(of: fields[0]) ?? Int.max
            if let best = best, best.rank >= rank { continue }
            var progress = try NativePuzzleFiles.readText(fields[0])
            if let target = (mode == "LEARNING" ? target : stages.first) {
                let digits = Array(target[1].utf8)
                guard digits.count == 81, digits.allSatisfy({ (48...57).contains($0) }) else { throw BoardFileError.invalid }
                func masks(_ encoded: String) throws -> [UInt16] {
                    guard let bytes = Data(base64Encoded: encoded), bytes.count == 162 else { throw BoardFileError.invalid }
                    return stride(from: 0, to: 162, by: 2).map { UInt16(bytes[$0]) << 8 | UInt16(bytes[$0 + 1]) }
                }
                progress.current.board.values = digits.map { $0 - 48 }
                progress.current.board.candidates = try masks(target[2])
                progress.current.board.userCandidates = try masks(target[3])
            }
            var context = progress.extra ?? NativeGameContext()
            context.difficulty = grade
            context.mode = mode
            context.score = score
            progress.extra = context
            try progress.validate()
            best = (rank, progress)
            if rank == Int.max { break }
        }
        guard let choice = best else { throw WorkspaceProblem("题库中没有符合当前难度和训练技巧的题目。请调整设置或打开题目文件。") }
        return choice.progress
    }
}
