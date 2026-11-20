// SPDX-License-Identifier: GPL-3.0-or-later
import Combine
import Foundation

enum WorkspaceInput {
    case game(BoardProgress, Int64, NativeReplayDocument?, String?)
    case replay(NativeReplayDocument, String)
    case settings(NativeWorkspacePreferences)
}

struct WorkspaceCheckpoint: Codable, Equatable {
    let clean: Bool
    let attempt: String
    let frames: Int
    let elapsed: Int64
    var progress: BoardProgress? = nil
    var baseSessionSHA256: String? = nil
}

final class NativeDesktopWorkspace: ObservableObject {
    let board: NativeBoardModel
    @Published private(set) var preferences = NativeWorkspacePreferences()
    @Published private(set) var message: String?
    @Published private(set) var opening = false
    @Published private(set) var quitFailure: String?
    @Published var commandDialogOpen = false
    private let legacyRoot: URL?
    private let namesURL: URL?
    @Published private(set) var generating = false
    private var generator: BlockOperation?
    private var generationFinished: [(Bool)->Void] = []
    private let generatorQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInitiated
        return queue
    }()
    private lazy var trainingNames: [String: String] = {
        guard let url = namesURL,
              let data = try? Data(contentsOf: url),
              let names = try? JSONDecoder().decode([String:String].self, from: data) else { return [:] }
        return names
    }()
    var trainingChoices: [String] { Set(board.solverConfig.rules.filter(\.enabled).map(\.kind).filter { !["GIVE_UP","INCOMPLETE"].contains($0) }).union(preferences.training).sorted() }
    func techniqueName(_ type: String) -> String { board.generalOptions.localized(trainingNames[type] ?? type) }
    private let settingsFile, replayFile, checkpointFile: WorkspaceFile
    var saveWindowLayout: (() throws -> Void)?
    private var preferencesUnavailable = false
    private var startupHandled = false
    private var retryURL: URL?
    private var retryAutomatic = false
    private var coldReplay = false
    var canRetryOpen: Bool { retryURL != nil || retryAutomatic }
    private var generation = UUID()
    private var pendingQuit = false

    init(directory: URL? = nil, legacyRoot: URL? = nil, supply: URL? = nil) {
        let model = NativeBoardModel(directory: directory, loadSaved: false, legacyRoot: legacyRoot)
        board = model
        let environment = ProcessInfo.processInfo.environment
        let isolated = directory != nil || environment["HODOKU_NATIVE_DATA_DIR"] != nil
        self.legacyRoot = legacyRoot ?? environment["HODOKU_LEGACY_DATA_DIR"].map { URL(fileURLWithPath: $0) }
            ?? (isolated ? nil : FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("HoDoKu"))
        namesURL = supply?.deletingLastPathComponent().appendingPathComponent("training-names.json") ?? Bundle.main.url(forResource: "training-names", withExtension: "json")
        settingsFile = WorkspaceFile("settings-v1.json", store: model.store)
        replayFile = WorkspaceFile("active-replay.json", store: model.store)
        checkpointFile = WorkspaceFile("quit-checkpoint.json", store: model.store)
    }

    func notice(_ text: String?) { message = text }

    func reportFailure(_ error: Error) {
        let message = board.generalOptions.localized(error.localizedDescription)
        notice(message)
        board.showOperationFeedback(message, sound: .failure)
    }

    private func loadPreferences() throws {
        if let raw = try settingsFile.read() {
            let loaded = try JSONDecoder().decode(NativeWorkspacePreferences.self, from: raw)
            try loaded.validate()
            preferences = loaded
        }
        preferences.visual = try preferences.resolvedVisual()
        preferences.generatorPatterns = try preferences.resolvedPatterns()
        board.visual = try preferences.resolvedVisual()
        board.mouseOptions = try preferences.resolvedMouseOptions()
        preferences.mouse = board.mouseOptions
        board.generalOptions = try preferences.resolvedGeneralOptions()
        preferences.general = board.generalOptions
        board.solverConfig = try NativeSolverConfig.read(preferences)
        preferences.difficulty = board.solverConfig.requestedLevel(preferences.difficulty, mode: preferences.mode, training: preferences.training)
        preferencesUnavailable = false
    }

    static func decode(_ url: URL, config: NativeSolverConfig = .standard) throws -> WorkspaceInput {
        switch url.pathExtension.lowercased() {
        case "hrep", "hdkreplay": return .replay(try NativeReplayLibrary.read(url), url.lastPathComponent)
        case "hcfg":
            throw WorkspaceProblem("请选择 .hodoku-settings 设置文件。")
        case "bak" where url.deletingPathExtension().pathExtension.lowercased() == "hcfg":
            throw WorkspaceProblem("请选择 .hodoku-settings 设置文件。")
        case "hodoku-settings":
            let prefs = try JSONDecoder().decode(NativeWorkspacePreferences.self, from: Data(contentsOf: url))
            try prefs.validate()
            return .settings(prefs)
        case "xml", "bak":
            let incoming = try LegacySessionReader.read(url)
            var game = incoming.progress
            var context = game.extra ?? NativeGameContext()
            context.legacy = incoming.context
            context.activeCell = incoming.context.activeCell
            context.sourceName = incoming.sourceURL.lastPathComponent
            context.sourceSessionXML = incoming.sourceBytes
            context.name = incoming.context.name
            context.requestedDifficulty = incoming.context.levelOrdinal
            context.mode = incoming.context.gameMode
            game.extra = context
            var origin: NativeReplayDocument?
            let id = incoming.context.replayId
            var info = incoming.recoveredBackup ? "已从 Java 会话备份恢复。" : nil
            if !id.isEmpty, ReplayJavaCodec.validID(id) {
                let path = incoming.sourceURL.deletingLastPathComponent().appendingPathComponent("replays").appendingPathComponent(id + ".hrep")
                if let known = try? NativeReplayLibrary.read(path), known.id == id,
                   known.frames.count == incoming.context.replayFrameCount,
                   known.frames.last?.board == game.current.board { origin = known }
                else { info = [info, "会话关联的原回放缺失或与当前盘面不一致，已保留来源编号。"].compactMap { $0 }.joined() }
            }
            return .game(game, incoming.context.replayElapsedMillis, origin, info)
        default:
            var fromClues = false
            let game = try NativePuzzleFiles.read(url, fromClues: &fromClues)
            return try puzzleInput(game, fromClues: fromClues, config: config, source: url)
        }
    }

    private static func puzzleInput(_ original: BoardProgress, fromClues: Bool, config: NativeSolverConfig, source: URL?) throws -> WorkspaceInput {
        var game = original
        var context = game.extra ?? NativeGameContext()
        let board = game.current.board
        if let source = source {
            context.sourceName = source.lastPathComponent
            if context.name == nil { context.name = source.deletingPathExtension().lastPathComponent }
        }
        if context.puzzleArchive == nil {
            context.historyAllowsStart = NativePuzzleHSOL.validation(board.values, board.candidates).0 == "VALID"
            if context.historyAllowsStart == true {
                let path = try NativeLogicalEngine.rate(board, config: config, fromClues: fromClues, cancelled: { false })
                if path.solved { context.difficulty = path.difficulty; context.score = path.score }
            }
        }
        game.extra = context
        return .game(game, 0, nil, nil)
    }

    func start(explicit: URL? = nil, rejectedBatch: Bool = false, finished: @escaping (Bool) -> Void = { _ in }) {
        guard !startupHandled else {
            if let explicit = explicit { open(explicit, finished: finished) } else { finished(true) }
            return
        }
        startupHandled = true
        do { try loadPreferences() }
        catch { preferencesUnavailable = true; message = "设置未能读取。"+error.localizedDescription }
        _ = try? replayFile.read()
        _ = try? checkpointFile.read()
        if rejectedBatch { message = "请一次打开一个文件。"; finished(false); return }
        if let explicit = explicit { open(explicit, finished: finished); return }
        let restored = restoreAutomatically()
        if generating { generationFinished.append(finished) } else { finished(restored) }
    }

    @discardableResult private func restoreAutomatically() -> Bool {
        do { try restoreLast(); retryAutomatic = false; return true }
        catch { retryAutomatic = true; message = error.localizedDescription; return false }
    }

    func retryOpening() {
        if let url = retryURL { open(url) }
        else if retryAutomatic { message = nil; _ = restoreAutomatically() }
    }

    func reviewingChanged(_ reviewing: Bool) {
        if !reviewing && coldReplay {
            coldReplay = false
            if !board.writable { _ = restoreAutomatically() }
        }
    }

    func restoreLast() throws {
        let fm = FileManager.default
        let nativeExists = [board.store.file, board.store.backupFile,
                            board.store.directory.appendingPathComponent("board-v2.json"),
                            board.store.directory.appendingPathComponent("board-v1.json")].contains { fm.fileExists(atPath: $0.path) }
        if !nativeExists, let source = legacyRoot?.appendingPathComponent("last-session.xml"),
           fm.fileExists(atPath: source.path) || fm.fileExists(atPath: source.appendingPathExtension("bak").path) {
            try apply(Self.decode(source), automatic: true)
            return
        }
        board.load(allowExample: false)
        if !board.writable {
            if let problem = board.problem { throw WorkspaceProblem(problem) }
            try newGame()
            return
        }
        if board.store.restoredFromBackup { message = "原生主存档无法读取，已从备份恢复。" }
        if try board.recoverInterruptedQuit(checkpoint: try? checkpointFile.read(), replay: try? replayFile.read()) {
            message = "已恢复上次退出前的进度。"
        }
        if board.recorder.document.completed {
            let old = board.progress.extra
            try newGame(level: old?.requestedDifficulty ?? old?.difficulty, mode: old?.mode)
        }
    }

    func open(_ url: URL, finished: @escaping (Bool) -> Void = { _ in }) {
        let policy = board.solverConfig
        readInput(retry: url, finished: finished) { try Self.decode(url, config: policy) }
    }

    func pastePuzzle(_ text: String, feedback: Bool = true, onError: ((Error) -> Void)? = nil,
                     finished: @escaping (Bool) -> Void = { _ in }) {
        let policy = board.solverConfig
        readInput(retry: nil, onError: onError, finished: { [weak self] ok in
            if ok && feedback { self?.board.playOperationSound(.paste) }
            finished(ok)
        }) {
            var fromClues = false
            let puzzle = try NativePuzzleFiles.readText(text, fromClues: &fromClues)
            return try Self.puzzleInput(puzzle, fromClues: fromClues, config: policy, source: nil)
        }
    }

    func cancelOpening() {
        guard opening else { return }
        generation = UUID()
        opening = false
    }

    private func readInput(retry url: URL?, onError: ((Error) -> Void)? = nil,
                           finished: @escaping (Bool) -> Void, decode: @escaping () throws -> WorkspaceInput) {
        let request = UUID()
        cancelNewGame()
        generation = request
        if board.writable { board.finishPointer() }
        opening = true
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try decode() }
            DispatchQueue.main.async {
                guard self.generation == request else { finished(false); return }
                self.opening = false
                do {
                    let item = try result.get()
                    self.message = nil
                    // A history write failure occurs after the new progress is durable.
                    // Keep the imported game and report the history issue separately.
                    try self.apply(item, automatic: false, onHistoryError: onError == nil ? nil : self.reportFailure)
                    self.retryURL = nil
                    self.retryAutomatic = false
                    if self.generating { self.generationFinished.append(finished) } else { finished(true) }
                } catch {
                    self.retryURL = url
                    if let onError { onError(error) } else { self.reportFailure(error) }
                    finished(false)
                }
            }
        }
    }

    func apply(_ input: WorkspaceInput, automatic: Bool, onHistoryError: ((Error) -> Void)? = nil) throws {
        switch input {
        case let .replay(doc, name):
            if !board.writable { coldReplay = true }
            try board.presentReplay(doc, name: name)
        case let .settings(settings):
            try updatePreferences(settings)
            if !board.writable { try restoreLast() }
        case let .game(progress, elapsed, source, info):
            try board.installGame(progress, elapsed: elapsed, origin: source)
            if let info = info { message = info }
            do { try recordHistory() } catch {
                if let onHistoryError { onHistoryError(error) } else { throw error }
            }
            if automatic && (progress.extra?.legacy?.completed == true || board.recorder.document.completed) {
                try newGame(level: progress.extra?.requestedDifficulty ?? progress.extra?.difficulty, mode: progress.extra?.mode)
            }
        }
    }

    func newGame(level: Int? = nil, mode: String? = nil) throws {
        let requested = mode ?? preferences.mode
        let training = preferences.training
        let actual = requested != "PLAYING" && training.isEmpty ? "PLAYING" : requested
        let config = board.solverConfig
        let target = config.requestedLevel(level ?? preferences.difficulty, mode: actual, training: training)
        let pattern = try preferences.resolvedPatterns().activeCells
        let recent = [Self.clues(board.progress.current.board)] + preferences.history.map(\.clues)
        cancelNewGame()
        if board.writable { board.finishPointer() }
        let original = board.progress
        let op = BlockOperation()
        generator = op
        generating = true
        op.addExecutionBlock { [weak self,weak op] in
            guard let op = op else { return }
            let result = Result {
                try NativeLiveGenerator.next(level:target,mode:actual,training:training,recent:recent,
                                             config:config,pattern:pattern,cancelled:{ op.isCancelled })
            }
            DispatchQueue.main.async { [weak self,weak op] in
                guard let self = self, let op = op, self.generator === op else { return }
                self.generator = nil
                self.generating = false
                guard self.board.progress == original, self.board.solverConfig == config else {
                    self.finishGeneration(false)
                    return
                }
                var installed = false
                do {
                    let game = try result.get()
                    try self.board.installGame(game)
                    installed = true
                    try self.recordHistory()
                    self.notice(requested == actual ? nil : "未选择训练技巧，已按普通模式开新题。")
                } catch { self.reportFailure(error) }
                self.finishGeneration(installed)
            }
        }
        generatorQueue.addOperation(op)
    }

    private func finishGeneration(_ installed: Bool) {
        let callbacks = generationFinished
        generationFinished.removeAll()
        for finished in callbacks { finished(installed) }
    }

    func cancelNewGame() {
        guard let op = generator else { return }
        generator = nil
        op.cancel()
        generating = false
        finishGeneration(false)
    }

    static func clues(_ board: NativeBoardSnapshot) -> String {
        zip(board.values, board.fixed).map { $1 ? String($0) : "0" }.joined()
    }

    func didEditBoard() {
        do { try recordHistory(started: false) } catch { notice(error.localizedDescription) }
    }

    func recordHistory(started: Bool = true) throws {
        guard let context = board.progress.extra, context.puzzleArchive == nil, !preferencesUnavailable else { return }
        let legacy = context.legacy
        let snapshot = board.progress.current.board
        let completeAtOpen = board.recorder.document.frames.first?.board.completeAndCorrect ?? false
        var state = context.historyTransition ?? NativeHistoryTransition(started: legacy != nil,
            recorded: legacy?.completed == true || (legacy?.completionRecorded ?? completeAtOpen),
            previouslySolved: legacy?.previouslySolved ?? completeAtOpen)
        let eligible = legacy?.historyEligible ?? (context.historyAllowsStart ?? true)
        let rated = context.difficulty != nil && context.score != nil
        if started {
            guard !state.started, context.historyAllowsStart ?? rated else { return }
            state.started = true
        } else {
            // Installing an existing board also refreshes the canvas through didEdit.
            if context.historyTransition == nil, board.recorder.document.frames.count == 1 { return }
            let solved = snapshot.completeAndCorrect
            let previouslySolved = state.previouslySolved
            let first = eligible && rated && !state.recorded && !state.previouslySolved && solved
            state.previouslySolved = solved
            if !first {
                if solved != previouslySolved {
                    try board.saveHistoryTransition(state)
                }
                return
            }
            state.recorded = true
        }
        var next = preferences
        // Options.addSudokuToHistory assigns INCOMPLETE (0) and the Sudoku2 default score to an unrated start.
        try NativePuzzleHistory.record(snapshot, level: context.difficulty ?? 0, score: context.score ?? 0,
            at: Int64(Date().timeIntervalSince1970 * 1000), completed: !started, limit: next.historyLimit, in: &next.history)
        // Keep dirty history available to the normal settings retry/quit path after a failed immediate write.
        preferences = next
        try board.saveHistoryTransition(state)
        try settingsFile.write(next)
    }

    func preferencesData() throws -> Data { try JSONEncoder().encode(preferences) }

    func updatePreferences(_ value: NativeWorkspacePreferences) throws {
        var next = value
        next.visual = try next.resolvedVisual()
        next.generatorPatterns = try next.resolvedPatterns()
        try next.validate()
        let changesSolver = next.legacyXML != preferences.legacyXML || next.solverEdits != preferences.solverEdits
            || next.visual?.levels.map(\.maxScore) != preferences.visual?.levels.map(\.maxScore)
        let policy = changesSolver ? try NativeSolverConfig.read(next) : board.solverConfig
        next.difficulty = policy.requestedLevel(next.difficulty, mode: next.mode, training: next.training)
        let mouse = try next.resolvedMouseOptions()
        next.mouse = mouse
        next.general = try next.resolvedGeneralOptions()
        try settingsFile.write(next)
        board.visual = next.visual ?? NativeBoardAppearance()
        board.mouseOptions = mouse
        board.generalOptions = next.general ?? NativeGeneralOptions()
        if generator != nil, next != preferences { cancelNewGame() }
        board.solverConfig = policy
        preferences = next
        preferencesUnavailable = false
    }

    func beginQuit() -> Bool {
        if pendingQuit || opening { return false }
        cancelNewGame()
        pendingQuit = true
        board.setReplayPause("quit", true)
        return saveForQuit()
    }

    func retryQuit() -> Bool { pendingQuit && saveForQuit() }

    func cancelQuit() {
        pendingQuit = false
        quitFailure = nil
        board.setReplayPause("quit", false)
    }

    private func saveForQuit() -> Bool {
        var errors: [String] = []
        func attempt(_ name: String, _ save: () throws -> Void) {
            do { try save() } catch { errors.append(name + "　" + error.localizedDescription) }
        }
        if board.writable {
            attempt("结算当前操作") { try board.settleForQuit() }
            let doc = board.recorder.document
            let pending = WorkspaceCheckpoint(clean: false, attempt: doc.id, frames: doc.frames.count, elapsed: doc.elapsedMillis,
                                              progress: board.progress, baseSessionSHA256: board.store.sessionDigest)
            attempt("恢复检查点") { try checkpointFile.write(pending) }
            attempt("回放") { try replayFile.write(doc) }
            attempt("会话") { try board.prepareToQuit() }
        }
        if board.generalOptions.saveWindowLayout, let save = saveWindowLayout { attempt("窗口布局", save) }
        attempt("设置") {
            if preferencesUnavailable { try loadPreferences() }
            try settingsFile.write(preferences)
        }
        if errors.isEmpty, board.writable {
            let doc = board.recorder.document
            attempt("退出检查点") {
                try checkpointFile.write(WorkspaceCheckpoint(clean: true, attempt: doc.id, frames: doc.frames.count, elapsed: doc.elapsedMillis))
            }
        }
        quitFailure = errors.isEmpty ? nil : errors.joined(separator: "\n")
        return errors.isEmpty
    }
}
