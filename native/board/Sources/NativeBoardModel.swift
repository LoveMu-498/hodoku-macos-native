import AppKit
import Combine

enum NativeOperationMessageTone: Equatable {
    case neutral, warning, failure
}

final class NativeBoardModel: ObservableObject {
    @Published var visual = NativeBoardAppearance()
    private(set) var progress = BoardProgress()
    private(set) var selected: Int?
    // Java resolves tool and view by their last change. Selection and both filters are one view.
    private var viewChangedSinceTool = false
    private(set) var selectionCells: [Int] = [] {
        didSet {
            if selectionCells != oldValue { viewChangedSinceTool = true }
            restartSelectionTimer()
        }
    }
    var generalOptions = NativeGeneralOptions() {
        didSet {
            guard oldValue != generalOptions else { return }
            restartSelectionTimer()
            objectWillChange.send()
        }
    }
    private var selectionTimer: Timer?
    private var hideSelection = false
    private func restartSelectionTimer() {
        selectionTimer?.invalidate()
        selectionTimer = nil
        hideSelection = false
        guard generalOptions.deleteCursorDisplay, selectionCells.count == 1 else { return }
        let delay = Double(generalOptions.deleteCursorDisplayLength) / 1000
        selectionTimer = Timer.scheduledTimer(withTimeInterval: max(0.001, delay), repeats: false) { [weak self] _ in
            self?.objectWillChange.send()
            self?.hideSelection = true
        }
    }
    var mouseOptions = NativeMouseOptions() {
        didSet {
            if oldValue != mouseOptions {
                if oldValue.operationSoundsEnabled != mouseOptions.operationSoundsEnabled {
                    if mouseOptions.operationSoundsEnabled {
                        if didPlayOperationSound == nil { operationSounds.prepare() }
                    } else {
                        operationSounds.stop()
                    }
                }
                playMouse = NativePlayMouse()
                objectWillChange.send()
            }
        }
    }
    private var playMouse = NativePlayMouse()
    private let playInterval: Int
    private(set) var tool = BoardTool.play {
        didSet { if tool != oldValue { viewChangedSinceTool = false } }
    }
    private(set) var color = 0
    private(set) var drag: BoardDrag?
    private(set) var frozen: BoardFrame? {
        didSet { if (oldValue == nil) != (frozen == nil) { scheduleHintPreparation() } }
    }
    private(set) var hint = BoardHintGesture()
    private var transcription: (reading: UUID, paths: [ChainToolPath])?
    private(set) var transcriptionProblem: String?
    private(set) var reading: NativeHintReading?
    private(set) var interruptedReading: NativeHintReading?
    var visibleReading: NativeHintReading? { reading ?? interruptedReading }
    private(set) var hintDrawerCollapsed = false
    var isHintDrawerAvailable: Bool { frozen == nil && visibleReading != nil }

    func setHintDrawerCollapsed(_ collapsed: Bool) {
        guard isHintDrawerAvailable, collapsed != hintDrawerCollapsed else { return }
        objectWillChange.send()
        hintDrawerCollapsed = collapsed
        if collapsed { hintHover(nil) }
    }
    private let namedCatalogue: NativeTechniqueCatalogue
    private(set) var knownTechnique: NativeHintTechnique?
    private(set) var knownTechniqueInstance: String?
    private(set) var techniqueSelection: NativeTechniqueInstance?
    private var techniqueReadingID: UUID?
    var choosingTechnique: Bool {
        (namedCatalogue.source != nil && techniqueReadingID == nil) || showingSolutionPath
    }
    var canReturnToTechniqueChooser: Bool {
        guard canEdit, frozen == nil, let techniqueReadingID, let reading else { return false }
        return techniqueReadingID == reading.id && progress.current.board == namedCatalogue.source && !choosingTechnique
    }
    var techniqueTab: NativeTechniqueTab {
        showingSolutionPath ? .path : currentReasoning == nil ? .techniques : .reasoning
    }
    @Published private var showingSolutionPath = false
    @Published var showingBoardSummary = false
    var techniqueInstances: [NativeHintTechnique: [NativeHintStep]] { namedCatalogue.instances }
    var techniqueCatalogueID: UUID { namedCatalogue.sourceID }
    var currentReasoning: NativeHintMatchInput? { namedCatalogue.scope }
    var staleReasoning: Bool {
        guard let context = namedCatalogue.context else { return false }
        if let scope = currentReasoning {
            return context.board != progress.current.board || scope != matchInput
        }
        return context.board != progress.current.board
    }
    private var reasoningInput: CurrentReasoningInput {
        let page = progress.current
        return CurrentReasoningInput(board: page.board, boxes: page.boxes.footprint, chains: page.chains,
            marks: page.marks, selection: Set(selectionCells), digits: hintDigits)
    }
    var techniqueLookupPending: Bool { namedCatalogue.pending || reasoningSearchScope != nil }
    var availableTechniqueLookupPending: Bool { namedCatalogue.pending }
    var techniqueLookupError: String? { namedCatalogue.error }

    var solverConfig = NativeSolverConfig.standard {
        didSet {
            if oldValue != solverConfig {
                preparedHints.invalidate()
                namedCatalogue.discardCachedBoard()
                closeHint()
                if techniqueTab != .path { closeTechniqueChooser() }
                scheduleHintPreparation()
            }
        }
    }
    private let hintRequests: NativeHintRequests
    private let reasoningRequests: NativeHintRequests
    let preparedHints: NativePreparedHints
    private let preparationQueue = DispatchQueue(label: "org.hodoku.nativecandidate.hint-preparation", qos: .utility)
    private var scheduledPreparation: DispatchWorkItem?
    private var pendingPreparation: BlockOperation?
    private var preparationPauses = Set<String>()
    private var reasoningSearchScope: NativeHintMatchInput?
    private var hintHasFocus = true
    private var readingOrigin: NativeHintRequests.Source?
    private var tabGroup: Int?
    var focusOnBoardReturn = false
    private var navigationAnchor = 40
    private(set) var countFilters: Set<Int> = [] {
        didSet { if countFilters != oldValue { viewChangedSinceTool = true } }
    }
    private(set) var inverseFilter = false {
        didSet {
            cancelPendingBoxHintIfFilterChanged()
            invalidateReasoningSearch()
            if inverseFilter != oldValue { scheduleHintPreparation() }
        }
    }
    private(set) var reviewKeyHeld = false
    private var reviewHoverHeld = false
    var hasPreviousBoard: Bool { lastBoardBefore != nil }
    private var lastBoardBefore: NativeBoardSnapshot?
    private var revealAllCandidates = false
    private var revealActiveCandidates = false
    var showingBoardCandidates: Bool { frozen?.showCandidates ?? (mouseOptions.showCandidates || revealAllCandidates) }
    var showingSelectedCandidates: Bool {
        if let frozen { return frozen.showCandidates || frozen.revealCandidatesInSelection }
        return mouseOptions.showCandidates || revealAllCandidates || revealActiveCandidates
    }
    private var keyboardHouse: String?
    private var keyboardHouseNumber: UInt8?
    private var acceptedDigits: UInt16 = 0
    private(set) var hintDigits: UInt16 = 0 {
        didSet {
            if hintDigits != oldValue {
                viewChangedSinceTool = true
                cancelPendingBoxHintIfFilterChanged()
                invalidateReasoningSearch()
                scheduleHintPreparation()
            }
        }
    }
    var hintRequestPending: Bool { hintRequests.source != nil }
    var hintSearchMessage: String? {
        (hintRequestPending || reasoningSearchScope != nil) ? generalOptions.localized("正在查找步骤…") : nil
    }
    private var sourceIsCurrent: (() -> Bool)?
    private var hoveredReference: Int?
    private var wholeHint = false
    private(set) var problem: String?
    private(set) var writable = true
    var canEdit: Bool { writable && !reviewing }
    private(set) var reviewing = false {
        didSet { if reviewing != oldValue { scheduleHintPreparation() } }
    }
    @Published var showingReplayLibrary = false
    private(set) var openedReplay: (name: String, document: NativeReplayDocument)?
    private(set) var reviewIdentity = UUID()
    private var externalRequest = UUID()
    private(set) var recorder: NativeReplayRecorder!
    lazy var replayLibrary = NativeReplayLibrary(store: store)
    private var proofFrames: [NativeReplayFrame] = []
    private var appliedPreview: (image: Data, text: String)?
    private var actionLabel: String?
    private static var nanos: UInt64 { DispatchTime.now().uptimeNanoseconds }
    private static var wall: Int64 { Int64(Date().timeIntervalSince1970 * 1000) }
    var chainSession = ChainToolSession()
    private var beforeChainSession = ChainToolSession()
    private var timeline = AnnotationTimeline()
    private var beforeClickTimeline = AnnotationTimeline()
    private var preciseOnFirst = false
    private var chainDeferred = false
    private var groupOnPress: Int?
    private var commandDown = false
    private var heldGroup: Int?
    private var palettes: [BoardTool: Int] = [:]
    private var lightPrimaryTools = Set<BoardTool>()
    private var paletteOwner: BoardTool { tool == .play ? .color : tool }
    var techniqueBoxGroup: Int { palettes[.boxes] ?? 0 }
    var lightPrimary: Bool { lightPrimaryTools.contains(paletteOwner) }
    private var authoredLight: Bool? { lightPrimary ? true : nil }
    func swapPalette() {
        guard canEdit, frozen == nil, [.play,.color,.ink].contains(tool) else { return }
        finishPointer()
        objectWillChange.send()
        if !lightPrimaryTools.insert(paletteOwner).inserted { lightPrimaryTools.remove(paletteOwner) }
        showOperationMessage(lightPrimary ? "已切换为浅色主色" : "已切换为深色主色")
    }

    func paletteShortcut(_ group: Int, shift: Bool) {
        guard canEdit, frozen == nil else { return }
        if tool == .ink && shift && group < 4 {
            chooseColor(group)
            objectWillChange.send()
            lightPrimaryTools.insert(.ink)
            return
        }
        guard tool == .play || tool == .color, !selectionCells.isEmpty else { return }
        objectWillChange.send()
        finishPointer()
        let before = progress.current
        var marks = before.marks
        for cell in selectionCells where generalOptions.colorValues || before.board.values[cell] == 0 {
            let mark = BoardMark(cell: cell, digit: 0, color: group, light: shift ? true : nil)
            if let i = marks.firstIndex(where: { $0.cell == cell && $0.digit == 0 }) {
                let previous = marks.remove(at: i)
                if previous != mark { marks.append(mark) }
            } else { marks.append(mark) }
        }
        if replaceMarks(marks) { commitAnnotation(before) }
    }
    private var previewKeys: Set<String> = []
    private var wheelTime: Int?
    private var wheelAmount = 0.0
    private var wheelConsumed = false
    private(set) var inkWidth = 1
    private var candidateInkFontFactor: CGFloat {
        generalOptions.showColorKu ? 0.25 : visual.factors["candidateFontFactor"]!
    }
    private(set) var wholeStroke = false
    private var radius: CGFloat = 0.025
    private var lastGeometry: BoardGeometry?
    private var inkLeadIn: [CGPoint] = []
    private var toolKeyState: (key: BoardTool, previous: BoardTool, at: Int, used: Bool)?
    private var lastToolTap: (key: BoardTool, at: Int, origin: BoardTool, board: NativeBoardSnapshot)?
    private var settledOrigins: [BoardTool: BoardTool] = [:]
    private var doubleToolOrigin: BoardTool?
    private var endingBorrow: BoardTool?
    private(set) var enteringStart = false
    private var gPress: (at: Int, wasOn: Bool, used: Bool)?
    private var gLastTap: Int?
    private var gOnPress = false
    private static let widths: [CGFloat] = [0.0035, 0.005, 0.007, 0.0095]
    private var dirty = false
    let store: NativeBoardStore
    private let automaticTimers: Bool
    private let interval: Int
    private var timer: Timer?
    private var active: BoardPress?
    private var pending: (press: BoardPress, before: BoardProgress)?
    private enum Pair { case none, same, cross }
    private var pair = Pair.none
    private var moved = false
    private let operationSounds = NativeOperationSounds()
    var didPlayOperationSound: ((NativeOperationSound) -> Void)?
    var didFinishPointerGesture: ((BoardPointerFeedback) -> Void)?
    var didCommitBoardDigits: ((NativeBoardSnapshot, [UInt16]) -> Void)?
    var trackingInkPointer: Bool { tool == .ink && active != nil }
    var pointerDragFeedback: BoardPointerFeedback? {
        if let press = active, moved, drag != nil {
            return BoardPointerFeedback(button: press.button,
                                        isDouble: pair != .none, isDrag: true)
        }
        if let press = playMouse.press, playMouse.moved {
            return BoardPointerFeedback(button: press.button,
                                        isDouble: playMouse.secondPress, isDrag: true)
        }
        return nil
    }
    private(set) var operationMessage: String?
    private(set) var operationMessageID = "native-board-operation-message"
    private(set) var operationMessageTone: NativeOperationMessageTone = .neutral
    private var operationMessageTimer: Timer?

    func clearOperationMessage(identifier: String) {
        guard operationMessageID == identifier, operationMessage != nil else { return }
        operationMessageTimer?.invalidate()
        operationMessageTimer = nil
        objectWillChange.send()
        operationMessage = nil
    }

    func showOperationMessage(_ message: String, identifier: String = "native-board-operation-message",
                              tone: NativeOperationMessageTone = .neutral) {
        operationMessageTimer?.invalidate()
        objectWillChange.send()
        operationMessageID = identifier
        operationMessage = message
        operationMessageTone = tone
        guard automaticTimers else { return }
        operationMessageTimer = Timer.scheduledTimer(withTimeInterval: 2.8, repeats: false) { [weak self] _ in
            self?.objectWillChange.send()
            self?.operationMessage = nil
            self?.operationMessageTimer = nil
        }
    }

    func showOperationFeedback(_ message: String, sound: NativeOperationSound,
                               identifier: String = "native-board-operation-message") {
        let tone: NativeOperationMessageTone
        switch sound {
        case .failure: tone = .failure
        case .noResults, .unavailable: tone = .warning
        default: tone = .neutral
        }
        showOperationMessage(message, identifier: identifier, tone: tone)
        playOperationSound(sound)
    }

    private func showAnalysisMessage(_ message: String, sound: NativeOperationSound = .noResults) {
        showOperationFeedback(generalOptions.localized(message), sound: sound)
    }

    var didEdit: ((NativeBoardSnapshot) -> Void)?
    static var now: Int { Int(ProcessInfo.processInfo.systemUptime * 1000) }

    init(
        directory: URL? = nil, automaticTimers: Bool = true, doubleClickMillis: Int? = nil,
        hintQueue: DispatchQueue = .global(qos: .userInitiated), loadSaved: Bool = true, legacyRoot: URL? = nil
    ) {
        let prepared = NativePreparedHints()
        preparedHints = prepared
        namedCatalogue = NativeTechniqueCatalogue(queue: hintQueue, prepared: prepared)
        hintRequests = NativeHintRequests(queue: hintQueue)
        reasoningRequests = NativeHintRequests(queue: hintQueue)
        store = NativeBoardStore(directory: directory, legacyRoot: legacyRoot)
        self.automaticTimers = automaticTimers
        playInterval = max(1, doubleClickMillis ?? Int(NSEvent.doubleClickInterval * 1000))
        interval = min(200, playInterval)
        if loadSaved { load() }
        else {
            writable = false
            recorder = NativeReplayRecorder(initial: progress.current, nowNanos: Self.nanos, wallMillis: Self.wall)
        }
    }

    func load(allowExample: Bool = true) {
        do {
            let saved = try store.load()
            if !allowExample && !store.hasSavedProgress {
                writable = false
                problem = nil
                return
            }
            let resumed = store.restoredRecording.map { NativeReplayRecorder(document: $0, nowNanos: Self.nanos) }
                ?? NativeReplayRecorder(initial: saved.current, nowNanos: Self.nanos, wallMillis: Self.wall)
            showGame(saved, recorder: resumed)
        } catch {
            writable = false
            problem = error.localizedDescription
        }
    }

    @discardableResult
    func recoverInterruptedQuit(checkpoint: Data?, replay: Data?) throws -> Bool {
        guard writable, let (game, document) = WorkspaceCrashRecovery.pending(
            checkpoint: checkpoint, replay: replay, current: progress,
            recorded: store.restoredRecording, sessionDigest: store.sessionDigest
        ) else { return false }
        try store.save(game, recording: document)
        showGame(game, recorder: NativeReplayRecorder(document: document, nowNanos: Self.nanos))
        return true
    }

    private let inkUniqueness = InkUniqueness()
    private func inkUnique(_ page: BoardPage) -> Bool {
        inkUniqueness.evidence(for: page.board, ink: page.ink) { [weak self] in self?.receivedSolution() }
    }

    private func receivedSolution() {
        guard canEdit else { return }
        objectWillChange.send()
        guard inkUnique(progress.current) else { return }
        let before = progress.current.ink
        InkReasoning.cancelSupersededOutlines(&progress.current.ink, board: progress.current.board, unique: true)
        if before != progress.current.ink {
            invalidateHintSourceIfNeeded()
            dirty = true
            if pending == nil && active == nil { autosave() }
        }
    }

    var frame: BoardFrame {
        if let frozen = frozen { return frozen }
        let refs = reading?.current.references ?? []
        let index = hoveredReference ?? (hint.visible ? hint.index : nil)
        var preview =
            index.flatMap { refs.indices.contains($0) ? [refs[$0]] : nil }
            ?? (wholeHint ? reading?.wholeReferences ?? [] : [])
        if choosingTechnique {
            // A hidden or invalid catalogue preview must also hide any older reading's overlay.
            preview = []
            if let cells = namedCatalogue.previewCells, namedCatalogue.source == progress.current.board, !staleReasoning {
                preview = cells.map { .cell($0) }
            }
        }
        if let house = keyboardHouse, let digit = keyboardHouseNumber {
            let n = Int(digit) - 1
            let cells = (0..<81).filter { cell in
                switch house {
                case "r": return cell / 9 == n
                case "c": return cell % 9 == n
                default: return (cell / 27) * 3 + cell % 9 / 3 == n
                }
            }
            preview += cells.map { .cell($0, digits: 0) }
        }
        var page = progress.current
        var erasedInk: InkToolState?
        if trackingInkPointer, let press = active, let drag = drag, let geometry = lastGeometry {
            if press.erases {
                let edit = erasedInkPreview(drag, geometry: geometry)
                page.ink = edit.kept
                erasedInk = edit.removed
            } else {
                traceInk(drag, into: &page.ink, geometry: geometry)
            }
        }
        let sources = InkProofPreview.sources(
            in: page.ink, tool: tool, inkGroup: palettes[.ink] ?? 0,
            optionOrMiddle: !previewKeys.isDisjoint(with: ["option", "middle"]),
            displayingStep: reading?.isFinal == true)
        let projection =
            tool == .ink && !previewKeys.isEmpty
            ? InkReasoning.previewProjection(state: page.ink, group: color, board: page.board, unique: inkUnique(page))
            : nil
        if tool == .ink {
            page.ink = InkReasoning.display(page.ink, group: color, board: page.board, unique: inkUnique(page))
        }
        let targets =
            previewKeys.isEmpty || tool != .chain
            ? [:] : page.chains.previewRelations(board: page.board, boxes: page.boxes, ink: page.ink)
        var answer = reading.flatMap { current in
            !choosingTechnique && current.isFinal && current.source == page.board && sourceIsCurrent?() == true
                ? current.answerDiagram : nil
        }
        answer?.isBoxProof = readingOrigin == .boxes
        return BoardFrame(
            page: page, selected: selected, reference: index, selectionCells: selectionCells, visual: visual, general: generalOptions, hideSelection: hideSelection,
            showCandidates: mouseOptions.showCandidates || revealAllCandidates, revealCandidatesInSelection: revealActiveCandidates, solution: mouseOptions.showDeviations ? inkUniqueness.solution : nil,
            preview: preview, digitFilter: hintDigits, countFilters: countFilters, inverseFilter: inverseFilter,
            filterAnyDigit: mouseOptions.useOrInsteadOfAndForFilter, onlySmallFilters: mouseOptions.onlySmallFilters,
            highlightingGivens: mouseOptions.highlightingGivens, reviewBoard: reviewKeyHeld || reviewHoverHeld ? lastBoardBefore : nil,
            previewTool: previewKeys.isEmpty ? nil : tool, activeTool: tool, erasing: active?.erases == true,
            palette: color,
            chainRelations: targets, preciseEndpoint: chainSession.endpoint, chainSinglePreview: commandDown,
            later: timeline.later, erasedInk: erasedInk, inkProjection: projection, inkSources: sources, answerDiagram: answer)
    }
    private func historyAvailable(redo: Bool) -> Bool {
        guard canEdit, frozen == nil else { return false }
        switch tool {
        case .play: return !(redo ? progress.boardRedo : progress.boardUndo).isEmpty
        case .color: return !(redo ? progress.markRedo : progress.markUndo).isEmpty
        case .ink: return !(redo ? progress.inkHistory.redo : progress.inkHistory.undo).isEmpty
        case .chain: return !(redo ? progress.chainHistory.redo : progress.chainHistory.undo).isEmpty
        case .boxes: return !(redo ? progress.boxHistory.redo : progress.boxHistory.undo).isEmpty
        }
    }
    var canUndo: Bool { historyAvailable(redo: false) }
    var canRedo: Bool { historyAvailable(redo: true) }

    // MARK: - Independent native progress

    private func save() throws {
        guard dirty else { return }
        try recordChanges()
        recorder.checkpoint(nowNanos: Self.nanos)
        try store.save(progress, recording: recorder.document)
        dirty = false
        problem = nil
    }

    private func recordChanges() throws {
        defer { actionLabel = nil }
        guard let last = recorder.document.frames.last else { throw BoardFileError.invalid }
        let before = last.branchPage ?? last.page
        let after = progress.current
        guard before.board != after.board || !proofFrames.isEmpty else { return }
        if recorder.document.completed {
            // The completed attempt is sealed. An undo starts an independent continuation.
            let archived = try replayLibrary.put(recorder.document, named: "已完成的作答")
            let source = recorder.document
            recorder = NativeReplayRecorder(initial: after, nowNanos: Self.nanos, wallMillis: Self.wall)
            recorder.document.sourceReplayID = source.id
            recorder.document.sourceArchiveSHA256 = archived.id
            recorder.document.sourceFrameIndex = source.frames.count - 1
            proofFrames.removeAll()
            appliedPreview = nil
            return
        }
        let label: String
        if let action = actionLabel { label = action }
        else if before.board != after.board { label = "编辑盘面" }
        else if before.marks != after.marks { label = "标色" }
        else if before.ink != after.ink { label = "涂鸦" }
        else if before.chains != after.chains { label = "自由链" }
        else { label = "选框" }
        var end = NativeReplayFrame(operationID: 0, wallTimeMillis: 0, elapsedMillis: 0,
                                    kind: proofFrames.isEmpty ? "manual" : "apply", label: label, page: after)
        if proofFrames.last?.kind == "authored-result" { end.kind = "authored-apply" }
        if let input = proofFrames.last?.kind, input == "doodle-conclusion-input" || input == "doodle-or-input" {
            end.kind = input == "doodle-or-input" ? "doodle-or-result" : "doodle-conclusion-result"
            end.phase = "result"
        } else { end.phase = "applied" }
        end.previewPNG = appliedPreview?.image
        end.text = appliedPreview?.text ?? ""
        end.branchPage = after
        guard recorder.capture(proofFrames + [end], nowNanos: Self.nanos, wallMillis: Self.wall) else {
            throw BoardFileError.invalid
        }
        proofFrames.removeAll()
        appliedPreview = nil
    }

    func setReplayPause(_ reason: String, _ paused: Bool) {
        if ["inactive", "sleep", "quit"].contains(reason) {
            if paused { preparationPauses.insert(reason) } else { preparationPauses.remove(reason) }
            scheduleHintPreparation()
        }
        recorder?.setPaused(reason, paused, nowNanos: Self.nanos)
    }

    var elapsedPlaySeconds: Int64 {
        guard var clock = recorder else { return 0 }
        clock.checkpoint(nowNanos: Self.nanos)
        return clock.document.elapsedMillis / 1_000
    }

    func beginReview() throws {
        guard writable else { throw BoardFileError.invalid }
        if reviewing { return }
        finishPointer()
        try save()
        objectWillChange.send()
        closeHint()
        closeTechniqueChooser()
        resetKeys()
        setReplayPause("viewer", true)
        reviewing = true
    }

    func openReplayFile(_ url: URL, completion: @escaping (Error?) -> Void) {
        let request = UUID()
        externalRequest = request
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try NativeReplayLibrary.read(url) }
            DispatchQueue.main.async {
                guard self.externalRequest == request else { completion(nil); return }
                do {
                    let opened = try result.get()
                    try self.presentReplay(opened, name: url.lastPathComponent)
                    completion(nil)
                } catch { completion(error) }
            }
        }
    }

    func editReplayMetadata(_ edit: (inout NativeReplayDocument) -> Void) throws {
        var updated = recorder.document
        edit(&updated)
        try store.save(progress, recording: updated)
        objectWillChange.send()
        recorder.document = updated
    }

    func endReview() {
        showingReplayLibrary = false
        objectWillChange.send()
        reviewing = false
        openedReplay = nil
        externalRequest = UUID()
        setReplayPause("viewer", false)
    }

    func branch(from document: NativeReplayDocument, at index: Int, archived: ReplayLibraryEntry? = nil) throws {
        guard reviewing, document.frames.indices.contains(index) else { throw BoardFileError.invalid }
        let historical = document.frames[index]
        var page = historical.branchPage ?? BoardPage(board: historical.board)
        if document.format == .native {
            page.ink.proofs.removeAll()
            page.ink.consumedGroups.removeAll()
            page.ink.strokes.removeAll { $0.ownsProof == true }
            for i in page.ink.strokes.indices {
                page.ink.strokes[i].outlined = false
                page.ink.strokes[i].outlineSources.removeAll()
                page.ink.strokes[i].ownsProof = false
            }
            page.chains.finish()
        }
        let next = BoardProgress(current: page)
        try next.validate()
        let start = Self.nanos
        var fresh = NativeReplayRecorder(initial: page, nowNanos: start, wallMillis: Self.wall)
        fresh.setPaused("viewer", true, nowNanos: start)
        fresh.document.sourceReplayID = document.id
        fresh.document.sourceFrameIndex = index
        let outgoing = try previousAttempt()
        try replayLibrary.archiveBranch(source: document, archived: archived, outgoing: outgoing) { key in
            fresh.document.sourceArchiveSHA256 = key
            try store.save(next, recording: fresh.document)
        }
        fresh.setPaused("viewer", false, nowNanos: Self.nanos)
        showGame(next, recorder: fresh)
    }

    /// Decode and validate all external input before atomically replacing the active attempt.
    func installGame(_ game: BoardProgress, elapsed: Int64 = 0, origin: NativeReplayDocument? = nil) throws {
        try game.validate()
        if writable {
            finishPointer()
            try save()
        }
        let outgoing = try previousAttempt()
        var fresh = NativeReplayRecorder(initial: game.current, nowNanos: Self.nanos, wallMillis: Self.wall)
        fresh.document.elapsedMillis = max(0, elapsed)
        if let origin = origin, origin.originalBytes != nil {
            fresh.document.sourceReplayID = origin.id
            fresh.document.sourceFrameIndex = origin.frames.count - 1
            try replayLibrary.archiveBranch(source: origin, archived: nil, outgoing: outgoing) { key in
                fresh.document.sourceArchiveSHA256 = key
                try store.save(game, recording: fresh.document)
            }
        } else if let outgoing = outgoing {
            try replayLibrary.archiveBranch(source: outgoing, archived: nil, outgoing: outgoing) { _ in
                try store.save(game, recording: fresh.document)
            }
        } else { try store.save(game, recording: fresh.document) }
        showGame(game, recorder: NativeReplayRecorder(document: fresh.document, nowNanos: Self.nanos))
    }

    private func previousAttempt() throws -> NativeReplayDocument? {
        guard let previous = try store.prepareExplicitReplacement() else { return nil }
        if writable { return recorder.document }
        return store.restoredRecording ?? NativeReplayRecorder(initial: previous.current, nowNanos: Self.nanos, wallMillis: Self.wall).document
    }

    /// Installing a different durable position invalidates timers, double-click rollback,
    /// wheel accumulation and transient editor sessions that refer to its predecessor.
    private func showGame(_ game: BoardProgress, recorder next: NativeReplayRecorder) {
        preparedHints.invalidate()
        namedCatalogue.discardCachedBoard()
        objectWillChange.send()
        progress = game
        recorder = next
        writable = true
        dirty = false
        problem = nil
        reviewing = false
        openedReplay = nil
        externalRequest = UUID()
        frozen = nil
        proofFrames = []
        appliedPreview = nil
        actionLabel = nil
        tool = .play
        color = 0
        palettes = [:]
        lightPrimaryTools.removeAll()
        settledOrigins = [:]
        lastBoardBefore = nil
        navigationAnchor = game.extra?.activeCell ?? 40
        countFilters.removeAll(); inverseFilter = false
        selected = game.extra?.activeCell
        selectionCells = selected.map { [$0] } ?? []
        inkUniqueness.request(for: game.current.board) { [weak self] in self?.receivedSolution() }
        playMouse = NativePlayMouse()
        hintDigits = 0
        timer?.invalidate()
        timer = nil
        active = nil
        pending = nil
        moved = false
        pair = .none
        drag = nil
        preciseOnFirst = false
        chainDeferred = false
        groupOnPress = nil
        doubleToolOrigin = nil
        wheelTime = nil
        wheelAmount = 0
        wheelConsumed = false
        beforeChainSession = ChainToolSession()
        beforeClickTimeline = AnnotationTimeline()
        lastGeometry = nil
        chainSession.reset()
        timeline = AnnotationTimeline()
        resetKeys()
        closeHint()
        closeTechniqueChooser()
        showingBoardSummary = false
        didEdit?(game.current.board)
        scheduleHintPreparation()
    }

    func saveCurrent() throws {
        finishPointer()
        if dirty { try save() }
        else if writable { try store.verifyCurrent() }
    }

    func addGameSavePoint(_ name: String) throws {
        guard canEdit else { throw BoardFileError.invalid }
        finishPointer()
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw BoardFileError.invalid }
        let previous = progress.extra
        let wasDirty = dirty
        var context = previous ?? NativeGameContext()
        var snapshot = progress
        snapshot.extra = nil
        var points = context.savePoints ?? []
        points.append(NativeGameSavePoint(name: name, date: Date(), progress: snapshot))
        context.savePoints = points
        progress.extra = context
        dirty = true
        do { try save() } catch {
            progress.extra = previous
            dirty = wasDirty
            throw error
        }
        objectWillChange.send()
    }

    func restoreGameSavePoint(_ saved: BoardProgress) throws {
        guard canEdit else { throw BoardFileError.invalid }
        try saved.validate()
        let source = progress.current.board
        let board = saved.current.board
        guard board.fixed == source.fixed,
              board.fixed.indices.allSatisfy({ !board.fixed[$0] || board.values[$0] == source.values[$0] })
        else { throw BoardFileError.invalid }
        finishPointer()
        try save()
        var target = saved
        target.extra = progress.extra
        target.extra?.activeCell = selected
        let previous = recorder.document
        var resumed = recorder!
        if previous.completed, previous.frames.last?.board != board {
            resumed = NativeReplayRecorder(initial: target.current, nowNanos: Self.nanos, wallMillis: Self.wall)
            resumed.document.sourceReplayID = previous.id
            resumed.document.sourceFrameIndex = previous.frames.count - 1
            try replayLibrary.archiveBranch(source: previous, archived: nil, outgoing: previous) { key in
                resumed.document.sourceArchiveSHA256 = key
                try store.save(target, recording: resumed.document)
            }
        } else {
            if previous.frames.last?.board != board {
                var frame = NativeReplayFrame(operationID: 0, wallTimeMillis: 0, elapsedMillis: 0,
                                              kind: "manual", label: "恢复保存点", page: target.current)
                frame.phase = "applied"
                frame.branchPage = target.current
                guard resumed.capture([frame], nowNanos: Self.nanos, wallMillis: Self.wall) else { throw BoardFileError.invalid }
            }
            resumed.checkpoint(nowNanos: Self.nanos)
            try store.save(target, recording: resumed.document)
        }
        showGame(target, recorder: resumed)
    }

    func presentReplay(_ document: NativeReplayDocument, name: String) throws {
        if writable { try beginReview() }
        objectWillChange.send()
        reviewing = true
        openedReplay = (name, document)
        reviewIdentity = UUID()
    }

    private func autosave() {
        do { try save() } catch { problem = error.localizedDescription }
    }

    func retry() {
        objectWillChange.send()
        if canEdit {
            finishPointer()
            autosave()
        } else {
            load()
        }
    }

    func settleForQuit() throws {
        objectWillChange.send()
        finishPointer()
        if writable {
            if progress.extra?.activeCell != selected {
                var context = progress.extra ?? NativeGameContext()
                context.activeCell = selected
                progress.extra = context
                dirty = true
            }
            recorder.checkpoint(nowNanos: Self.nanos)
            if (store.restoredRecording?.elapsedMillis ?? 0) != recorder.document.elapsedMillis { dirty = true }
        }
        if writable && dirty { try recordChanges() }
    }

    func prepareToQuit() throws {
        try settleForQuit()
        if dirty { try save() }
        else if writable { try store.verifyCurrent() }
        hintRequests.cancel()
        cancelHintPreparation()
        preparedHints.invalidate()
        namedCatalogue.discardCachedBoard()
    }

    func playOperationSound(_ sound: NativeOperationSound) {
        guard mouseOptions.operationSoundsEnabled else { return }
        if let handler = didPlayOperationSound { handler(sound) }
        else { operationSounds.play(sound) }
    }

    private func playAnnotationSound(_ press: BoardPress, rectangle: Bool = false) {
        guard press.erases else { return }
        if tool == .ink {
            playOperationSound(rectangle ? .eraseInkBatch : .eraseInk)
        } else {
            playOperationSound(.clear)
        }
    }

    private func finalizeSingle() {
        if chainDeferred, let first = pending?.press {
            chainDeferred = false
            performClick(first, twice: false)
        }
        if let pending = pending {
            if !(tool == .chain && pending.press.cell == nil && pending.press.button == .left &&
                 pending.before.current.chains.nextStrong != progress.current.chains.nextStrong) {
                showPointerResult(pending.before.current, press: pending.press, dragged: false)
            }
        }
        if let pending = pending, pending.before != progress {
            if pending.before.current != progress.current {
                playAnnotationSound(pending.press)
            }
            if tool == .chain && pending.press.cell == nil && pending.press.button == .left &&
                pending.press.modifiers.isEmpty && pending.before.current.chains.nextStrong != progress.current.chains.nextStrong {
                showNextChainRelation()
            }
            dirty = true
            invalidateHintSourceIfNeeded()
            autosave()
        }
        pending = nil
    }

    private func restoreSingle() {
        if let pending = pending {
            progress = pending.before
            chainSession = beforeChainSession
            timeline = beforeClickTimeline
        }
        chainDeferred = false
        pending = nil
    }

    /// A lone first release is a real edit. Between the two presses of a
    /// same-target double, focus loss discards the uncommitted replacement.
    func finishPointer() {
        playMouse = NativePlayMouse()
        if pair == .same && active != nil { restoreSingle() } else { finalizeSingle() }
        active = nil
        moved = false
        pair = .none
        drag = nil
        schedule()
    }

    func focus(_ gained: Bool, now: Int) {
        objectWillChange.send()
        let changed = hintHasFocus != gained
        hintHasFocus = gained
        hintRequests.deferInput(.focus(gained: gained, time: now))
        hint.setPaused(!gained, now: now)
        if !gained {
            hoveredReference = nil
            wholeHint = false
            finishPointer()
            if let prior = endingBorrow ?? toolKeyState?.previous { chooseTool(prior) }
            resetKeys()
            chainSession.reset()
            autosave()
        }
        if changed { scheduleHintPreparation() }
        schedule()
    }

    func escape() {
        objectWillChange.send()
        if frozen != nil {
            frozen = nil
            return
        }
        if enteringStart {
            finishPointer()
            enteringStart = false
            gPress = nil
            gLastTap = nil
            return
        }
        if active != nil || pending != nil {
            restoreSingle()
            finishPointer()
            return
        }
        if !previewKeys.isEmpty {
            previewKeys.removeAll()
            return
        }
        if transcription != nil { cancelChainTranscription(); return }
        if reasoningSearchScope != nil { cancelReasoningSearch(); return }
        if visibleReading != nil || hintRequestPending {
            closeHint()
            return
        }
        if chainSession.endpoint != nil || !chainSession.choices.isEmpty {
            chainSession.reset()
            return
        }
        if tool == .chain, progress.current.chains.active != nil {
            let before = progress.current
            progress.current.chains.cancelActive()
            commitAnnotation(before)
            return
        }
        let hasView = !selectionCells.isEmpty || hintDigits != 0 || !countFilters.isEmpty
        if tool != .play && !(hasView && viewChangedSinceTool) {
            chooseTool(.play)
            return
        }
        hintDigits = 0
        countFilters.removeAll()
        navigationAnchor = selected ?? navigationAnchor
        select(nil)
    }

    func tick(_ now: Int) {
        objectWillChange.send()
        hint.tick(now)
        if active == nil, let first = pending, now > first.press.at + interval {
            finalizeSingle()
            autosave()
        }
        schedule()
    }

    private func schedule() {
        timer?.invalidate()
        timer = nil
        guard automaticTimers else { return }
        let click = active == nil ? pending.map { $0.press.at + interval + 1 } : nil
        guard let deadline = [click, hint.deadline].compactMap({ $0 }).min() else { return }
        let next = Timer(timeInterval: Double(max(1, deadline - Self.now)) / 1000, repeats: false) { [weak self] _ in
            self?.tick(Self.now)
        }
        RunLoop.main.add(next, forMode: .common)
        timer = next
    }

    func chooseTool(_ next: BoardTool) {
        objectWillChange.send()
        finishPointer()
        autosave()
        if tool != next {
            if reading?.step.technique == .userInk { closeHint() }
            if next != .ink { cancelChainTranscription() }
            if hintRequests.source == .tabBoxes || hintRequests.source == .tabDigits || hintRequests.source == .tabChain { closeHint() }
            chainSession.reset()
            resetKeys()
        }
        let changed = tool != next
        tool = next
        color = palettes[next] ?? 0
        invalidateReasoningSearch()
        if changed { scheduleHintPreparation() }
    }

    func chooseColor(_ next: Int) {
        guard (0..<6).contains(next) else { return }
        objectWillChange.send()
        finishPointer()
        autosave()
        let changed = color != next
        if changed {
            if reading?.step.technique == .userInk { closeHint() }
            transcriptionProblem = nil
            if hintRequests.source == .tabBoxes { closeHint() }
            enteringStart = false
            gPress = nil
            gLastTap = nil
        }
        color = next
        palettes[tool] = next
        invalidateReasoningSearch()
        if changed && tool == .boxes { scheduleHintPreparation() }
        if changed { showOperationMessage("已切换到\(AnnotationPalette.names[next])色组") }
    }

    func saveHistoryTransition(_ state: NativeHistoryTransition) throws {
        guard progress.extra != nil, progress.extra?.historyTransition != state else { return }
        progress.extra?.historyTransition = state
        dirty = true
        try save()
    }

    func select(_ index: Int?) {
        guard frozen == nil else { return }
        objectWillChange.send()
        selected = index.flatMap { (0..<81).contains($0) ? $0 : nil }
        selectionCells = selected.map { [$0] } ?? []
    }

    func selectCells(_ cells: [Int]) {
        guard frozen == nil else { return }
        var seen = Set<Int>()
        objectWillChange.send()
        selectionCells = cells.filter { (0..<81).contains($0) && seen.insert($0).inserted }
        if let anchor = selectionCells.last ?? selected { navigationAnchor = anchor }
        selected = selectionCells.last
    }

    func edit(_ digit: UInt8) {
        guard canEdit, frozen == nil, tool == .play, let cell = selected else { return }
        objectWillChange.send()
        finishPointer()
        let previous = progress.current.board
        guard !previous.fixed[cell] else {
            if digit != previous.values[cell] { unavailableOperation("给定数不能修改。") }
            return
        }
        progress.current.board.setValue(digit, at: cell)
        guard progress.current.board != previous else { return }
        progress.boardUndo.append(previous)
        progress.boardRedo.removeAll()
        boardDidChange()
        playDigitEntrySound(digit, cells: [cell])
    }

    private func playDigitEntrySound(_ digit: UInt8, cells: [Int]) {
        let board = progress.current.board
        let conflict = digit != 0 && generalOptions.showWrongValues && cells.contains {
            !board.fixed[$0] && board.values[$0] == digit && board.legalMask(at: $0) & NativeBoardSnapshot.bit(digit) == 0
        }
        playOperationSound(conflict ? .unavailable : (digit == 0 ? .clear : .edit))
    }

    private func unavailableOperation(_ message: String) {
        showOperationFeedback(generalOptions.localized(message), sound: .unavailable)
    }

    private func pruneAnnotations() {
        let board = progress.current.board
        InkReasoning.pruneStale(in: &progress.current.ink, board: board)
        progress.current.marks.removeAll { mark in
            mark.digit > 0
                && (board.values[mark.cell] != 0
                    || (board.candidates[mark.cell] | board.userCandidates[mark.cell])
                        & NativeBoardSnapshot.bit(UInt8(mark.digit)) == 0)
        }
        progress.current.chains.prune(board: board)
    }
    private func boardDidChange(previous: NativeBoardSnapshot? = nil, explicitRemovals: [UInt16] = []) {
        preparedHints.invalidate()
        namedCatalogue.discardCachedBoard()
        scheduleHintPreparation()
        lastBoardBefore = previous ?? progress.boardUndo.last
        pruneAnnotations()
        let priorReading = interruptedReading ?? ((readingOrigin == .ordinary || knownTechnique != nil) && sourceIsCurrent?() == true ? reading : nil)
        closeHint()
        if let prior = priorReading, prior.remainingProof(on:progress.current.board) != nil {
            interruptedReading = prior
        }
        dirty = true
        autosave()
        didEdit?(progress.current.board)
        let board = progress.current.board
        if let before = lastBoardBefore { didCommitBoardDigits?(before, explicitRemovals) }
        if generalOptions.showSudokuSolved, lastBoardBefore?.values.contains(0) == true,
           progress.extra?.editingClues != true, !board.values.contains(0),
           (0..<81).allSatisfy({ board.legalMask(at: $0) & NativeBoardSnapshot.bit(board.values[$0]) != 0 }) {
            showOperationMessage(generalOptions.localized("数独已解出"), identifier: "native-sudoku-solved")
        }
    }

    func history(redo: Bool) {
        guard frozen == nil, canEdit else { return }
        objectWillChange.send()
        finishPointer()
        guard historyAvailable(redo: redo) else { return }
        actionLabel = redo ? "重做" : "撤销"
        if tool == .play {
            let previous = progress.current.board
            if redo, let next = progress.boardRedo.popLast() {
                progress.boardUndo.append(progress.current.board)
                progress.current.board = next
            } else if !redo, let next = progress.boardUndo.popLast() {
                progress.boardRedo.append(progress.current.board)
                progress.current.board = next
            } else {
                return
            }
            boardDidChange(previous: previous)
        } else {
            switch tool {
            case .color:
                if redo, let next = progress.markRedo.popLast() {
                    progress.markUndo.append(progress.current.marks)
                    progress.current.marks = next
                } else if !redo, let next = progress.markUndo.popLast() {
                    progress.markRedo.append(progress.current.marks)
                    progress.current.marks = next
                } else {
                    return
                }
            case .ink:
                var value = progress.current.ink
                progress.inkHistory.restore(&value, redo: redo)
                progress.current.ink = value
            case .chain:
                chainSession.reset()
                var value = progress.current.chains
                progress.chainHistory.restore(&value, redo: redo)
                progress.current.chains = value
            case .boxes:
                var value = progress.current.boxes
                progress.boxHistory.restore(&value, redo: redo)
                progress.current.boxes = value
            case .play: return
            }
            pruneAnnotations()
            timeline.observe(progress.current, proof: reading?.id)
            invalidateHintSourceIfNeeded()
            if tool == .chain || tool == .boxes { scheduleHintPreparation() }
            dirty = true
            autosave()
        }
        if !(redo && tool == .play && operationMessageID == "native-sudoku-solved" && !progress.current.board.values.contains(0)) {
            showOperationMessage((redo ? "已重做" : "已撤销") + tool.title + "操作")
        }
    }

    private func register(_ previous: BoardPage) {
        if previous.boxes != progress.current.boxes || previous.chains != progress.current.chains {
            scheduleHintPreparation()
        }
        if previous.ink != progress.current.ink { InkReasoning.reconcile(&progress.current.ink) }
        if previous.ink != progress.current.ink { progress.inkHistory.record(previous.ink) }
        if previous.chains != progress.current.chains { progress.chainHistory.record(previous.chains) }
        if previous.boxes != progress.current.boxes { progress.boxHistory.record(previous.boxes) }
        timeline.observe(progress.current, proof: reading?.id)
    }
    private func resetKeys() {
        revealAllCandidates = false
        revealActiveCandidates = false
        keyboardHouse = nil
        keyboardHouseNumber = nil
        reviewKeyHeld = false
        reviewHoverHeld = false
        commandDown = false
        heldGroup = nil
        previewKeys.removeAll()
        enteringStart = false
        gPress = nil
        gLastTap = nil
        lastToolTap = nil
        toolKeyState = nil
        endingBorrow = nil
    }
    func holdPalette(_ group: Int, down: Bool) {
        if down {
            guard frozen == nil, tool != .play else { return }
            chooseColor(group)
            heldGroup = group
        } else if heldGroup == group {
            heldGroup = nil
        }
    }
    func setPreview(_ source: String, down: Bool) {
        guard frozen == nil, tool != .play, source != "space" || tool == .ink else { return }
        objectWillChange.send()
        if down {
            if previewKeys.insert(source).inserted {
                finishPointer()
                autosave()
            }
        } else {
            previewKeys.remove(source)
            if previewKeys.isEmpty { chainSession.cancelPreviewChoice() }
        }
    }
    // MARK: - Pointer arbitration and per-tool transactions

    func press(
        _ point: CGPoint, button: BoardButton, modifiers: BoardModifiers,
        at now: Int, geometry: BoardGeometry, pressedButtons: Int = 0
    ) {
        guard frozen == nil, canEdit else { return }
        if let held = active, held.button != button, pressedButtons & (held.button == .left ? 1 : 2) != 0 { return }
        cancelHintPreparation()
        let cell = geometry.cell(at: point)
        guard tool != .play else {
            if let previous = playMouse.press {
                if previous.button != button && pressedButtons & (previous.button == .left ? 1 : 2) != 0 { return }
                playMouse = NativePlayMouse()
            }
            objectWillChange.send()
            playMouse.press = BoardPress(at: now, point: point, button: button, modifiers: modifiers,
                                        cell: cell, digit: geometry.digitSlot(at: point))
            playMouse.deselectOnRelease = false
            playMouse.moved = false
            if let previous = playMouse.previous {
                playMouse.secondPress = previous.cell == cell && previous.digit == playMouse.press?.digit &&
                    (0...playInterval).contains(now - previous.at)
            } else { playMouse.secondPress = false }
            guard let cell = cell else {
                if let selected = selected { select(selected) }
                return
            }
            toolKeyState?.used = true
            if button == .right {
                if !selectionCells.contains(cell) { select(cell) }
            } else if modifiers.contains(.command) {
                if selectionCells.contains(cell) {
                    if selectionCells.count > 1 { selectCells(selectionCells.filter { $0 != cell }) }
                } else { selectCells(selectionCells + [cell]) }
            } else if modifiers.isEmpty && !mouseOptions.singleClickMode && selectionCells == [cell] {
                playMouse.deselectOnRelease = true
            } else {
                let value = progress.current.board.values[cell]
                if mouseOptions.autoHighlighting && value != 0 { hintDigits = NativeBoardSnapshot.bit(value) }
                select(cell)
            }
            return
        }
        guard previewKeys.isEmpty || tool == .chain else { return }
        objectWillChange.send()
        if active != nil { finishPointer() }
        let next = BoardPress(
            at: now, point: point, button: button, modifiers: modifiers, cell: cell,
            digit: geometry.visibleDigit(at: point, board: progress.current.board))
        pair = .none
        if tool != .boxes, let first = pending?.press, first.button == button, first.modifiers == modifiers,
            geometry.bounds.contains(first.point), geometry.bounds.contains(point), (0...interval).contains(now - first.at)
        {
            if tool == .chain && modifiers.isEmpty && chainSession.endpoint == nil {
                pair = .same
                preciseOnFirst = preciseOnFirst && first.cell == next.cell && first.digit == next.digit
            } else if first.sameTarget(as: next) {
                pair = .same
            } else if modifiers.isEmpty && (button == .right && tool == .color || tool == .ink) {
                pair = .cross
            }
        }
        if pair == .none {
            finalizeSingle()
            autosave()
            beforeChainSession = chainSession
            beforeClickTimeline = timeline
            preciseOnFirst =
                next.cell.flatMap { cell in next.digit.map { progress.current.chains.hasConnected(cell * 10 + $0) } }
                ?? false
        }
        active = next
        moved = false
        inkLeadIn.removeAll(keepingCapacity: true)
        lastGeometry = geometry
        groupOnPress = heldGroup
        gOnPress = enteringStart
        gPress?.used = true
        toolKeyState?.used = true
        schedule()
    }

    func move(_ point: CGPoint, geometry: BoardGeometry) {
        if tool == .play {
            guard let press = playMouse.press else { return }
            if hypot(point.x - press.point.x, point.y - press.point.y) >= 4 {
                playMouse.moved = true
            }
            guard playMouse.moved, press.button == .left, press.modifiers.contains(.command) else { return }
            drag = BoardDrag(points: [press.point, point], rectangle: true, radius: 0)
            selectCells(NativePlayMouse.marquee(from: press.cell, to: point, geometry: geometry))
            return
        }
        guard let press = active else { return }
        if !moved && hypot(point.x - press.point.x, point.y - press.point.y) < 4 {
            if tool == .ink && point != (inkLeadIn.last ?? press.point) { inkLeadIn.append(point) }
            return
        }
        if tool != .ink { objectWillChange.send() }
        let firstDrag = !moved
        if firstDrag {
            if pair != .none {
                restoreSingle()
                pair = .same
            }
            moved = true
        }
        guard tool != .color || press.erases else { return }
        let rectangle =
            tool == .chain || tool == .boxes || pair == .same || press.modifiers.contains(.shift)
            || (press.erases && press.button != .right)
        let brush = (geometry.grid.width + 20) * radius
        if rectangle || drag == nil {
            var points = [press.point]
            if tool == .ink && !rectangle { points.append(contentsOf: inkLeadIn) }
            points.append(point)
            drag = BoardDrag(points: points, rectangle: rectangle, radius: brush)
            inkLeadIn.removeAll(keepingCapacity: true)
        } else {
            if drag?.points.last != point { drag?.points.append(point) }
            drag?.radius = brush
        }
        if tool == .ink { lastGeometry = geometry }
        if firstDrag { showDragGuidance(press, rectangle: rectangle) }
    }

    private func erasedInkPreview(_ drag: BoardDrag, geometry: BoardGeometry) -> (kept: InkToolState, removed: InkToolState) {
        progress.current.ink.erased(
            drag, group: groupOnPress, whole: wholeStroke, geometry: geometry, candidateFontFactor: candidateInkFontFactor)
    }

    private func traceInk(_ drag: BoardDrag, into ink: inout InkToolState, geometry: BoardGeometry) {
        ink.trace(drag, ellipse: drag.rectangle, group: color, width: Self.widths[inkWidth], geometry: geometry, light: authoredLight)
    }

    func release(_ point: CGPoint, button: BoardButton, at now: Int, geometry: BoardGeometry, modifiers: BoardModifiers? = nil) {
        defer { scheduleHintPreparation() }
        if tool == .play {
            releasePlay(point, button: button, at: now, geometry: geometry, modifiers: modifiers)
            return
        }
        guard let press = active, press.button == button else { return }
        objectWillChange.send()
        if pair == .cross && !moved {
            finalizeSingle()
            beforeChainSession = chainSession
            beforeClickTimeline = timeline
        }
        let wasDrag = moved
        let wasDouble = pair == .same
        if moved {
            move(point, geometry: geometry)
            let previous = progress.current
            if let d = drag {
                switch tool {
                case .color:
                    _ = replaceMarks(
                        previous.marks.filter { mark in
                            let rect = geometry.rect(mark.cell, digit: mark.digit)
                            return groupOnPress != nil && groupOnPress != mark.color
                                || !d.hits(CGPoint(x: rect.midX, y: rect.midY))
                        })
                case .ink:
                    if press.erases {
                        progress.current.ink = erasedInkPreview(d, geometry: geometry).kept
                    } else {
                        var ink = progress.current.ink
                        traceInk(d, into: &ink, geometry: geometry)
                        progress.current.ink = ink
                    }
                case .chain:
                    progress.current.chains.edit(
                        rect: d.bounds, erase: press.erases, deleteGroup: groupOnPress, geometry: geometry,
                        board: previous.board)
                case .boxes:
                    progress.current.boxes.edit(
                        start: press.point, end: point, dragged: true, erase: press.erases, group: color,
                        deleteGroup: groupOnPress, geometry: geometry)
                case .play: break
                }
            }
            register(previous)
            if progress.current != previous {
                playAnnotationSound(press, rectangle: drag?.rectangle == true)
                dirty = true
                invalidateHintSourceIfNeeded()
            }
            showPointerResult(previous, press: press, dragged: true)
        } else if pair == .same {
            restoreSingle()
            let previous = progress.current
            if tool == .color, press.cell == nil, press.button == .right { _ = colorClick(press, twice: false) }
            performClick(press, twice: true)
            showPointerResult(previous, press: press, dragged: false, double: true)
            if previous != progress.current {
                playAnnotationSound(press)
                dirty = true
                invalidateHintSourceIfNeeded()
            }
        } else {
            let previous = progress
            let precise = tool == .chain && chainSession.endpoint != nil &&
                !(press.startsChainSegment && previewKeys.isEmpty)
            let reversible = hasAnnotationDouble(press, geometry: geometry)
            chainDeferred = reversible && tool == .chain && progress.current.chains.shouldDelay(press)
            if !chainDeferred { performClick(press, twice: false) }
            if reversible {
                pending = (press, previous)
            } else {
                showPointerResult(previous.current, press: press, dragged: false, precise: precise)
                if previous != progress {
                    if previous.current != progress.current { playAnnotationSound(press) }
                    dirty = true
                    invalidateHintSourceIfNeeded()
                }
            }
        }
        invalidateHintSourceIfNeeded()
        didFinishPointerGesture?(BoardPointerFeedback(button: button,
                                                       isDouble: wasDouble, isDrag: wasDrag))
        active = nil
        moved = false
        pair = .none
        drag = nil
        if let first = pending, now > first.press.at + interval { finalizeSingle() }
        if pending == nil { autosave() }
        if let prior = endingBorrow { chooseTool(prior) }
        schedule()
    }

    /// All value and candidate changes use the same undo, hint invalidation, replay
    /// and independent save path as a keyboard edit.
    private func changePlayBoard(_ change: (inout NativeBoardSnapshot) -> Void) {
        guard canEdit, frozen == nil, tool == .play else { return }
        let before = progress.current.board
        change(&progress.current.board)
        guard before != progress.current.board else { return }
        objectWillChange.send()
        progress.boardUndo.append(before)
        progress.boardRedo.removeAll()
        boardDidChange()
    }

    func hasPlayPress(button: BoardButton) -> Bool {
        canEdit && frozen == nil && tool == .play && playMouse.press?.button == button
    }

    func applyPlayMenuNumber(_ number: Int) {
        guard (-9...9).contains(number) else { return }
        if number < 0 { excludePlayCandidates(NativeBoardSnapshot.bit(UInt8(-number))); return }
        let cells = selectionCells
        changePlayBoard { board in
            for cell in cells where number == 0 || board.values[cell] == 0 { board.setValue(UInt8(number), at: cell) }
        }
    }

    func excludePlayCandidates(_ digits: UInt16) {
        let cells = selectionCells
        let ordinary = mouseOptions.showCandidates
        changePlayBoard { board in
            for cell in cells where board.values[cell] == 0 {
                if ordinary { board.candidates[cell] &= ~digits } else { board.userCandidates[cell] &= ~digits }
            }
        }
    }

    func resetOrdinaryCandidates() {
        guard canEdit, frozen == nil else { return }
        chooseTool(.play)
        finishPointer()
        let previous = progress.current.board
        changePlayBoard { board in
            for cell in board.values.indices where board.values[cell] == 0 {
                board.candidates[cell] = board.legalMask(at: cell)
            }
        }
        let changed = progress.current.board != previous
        showOperationFeedback(generalOptions.localized(changed ? "已重置普通候选数" : "普通候选数已经是初始状态"),
                              sound: changed ? .edit : .noResults)
    }

    func applyUniqueSolution(_ values: [UInt8]) {
        guard canEdit, frozen == nil, values.count == 81 else { return }
        let previous = progress.current.board
        guard previous.values.contains(0) else { return }
        chooseTool(.play)
        actionLabel = "求解当前题"
        changePlayBoard { board in
            for cell in board.values.indices where board.values[cell] == 0 {
                board.setValue(values[cell], at: cell)
            }
        }
        playOperationSound(.edit)
    }

    func togglePlayMenuColor(_ group: Int) {
        guard let cell = selected, canEdit, frozen == nil, tool == .play, (0..<6).contains(group) else { return }
        togglePlayMark(cell: cell, digit: 0, group: group)
    }

    private func togglePlayMark(cell: Int, digit: Int, group: Int) {
        let mark = BoardMark(cell: cell, digit: digit, color: group, light: authoredLight)
        guard generalOptions.colorValues || progress.current.board.values[cell] == 0 else { return }
        let previous = progress.current
        var marks = previous.marks
        if let i = marks.firstIndex(where: { $0.cell == cell && $0.digit == digit }) {
            let old = marks.remove(at: i)
            if old != mark { marks.append(mark) }
        } else { marks.append(mark) }
        if replaceMarks(marks) {
            objectWillChange.send()
            register(previous)
            dirty = true
            autosave()
        }
    }

    func togglePlayCandidate(_ digit: UInt8, at cell: Int) {
        togglePlayCandidate(digit, in: [cell])
    }

    func togglePlayCandidate(_ digit: UInt8, in cells: [Int], individually: Bool = false) {
        guard (1...9).contains(digit) else { return }
        let bit = NativeBoardSnapshot.bit(digit)
        let options = mouseOptions
        changePlayBoard { board in
            let empty = cells.filter { (0..<81).contains($0) && board.values[$0] == 0 }
            let remove = empty.contains { options.displayedMask(board, at: $0) & bit != 0 }
            for cell in empty {
                let present = individually ? options.displayedMask(board, at: cell) & bit != 0 : remove
                if options.showCandidates {
                    if present { board.candidates[cell] &= ~bit } else { board.candidates[cell] |= bit }
                } else {
                    if present { board.userCandidates[cell] &= ~bit } else { board.userCandidates[cell] |= bit }
                }
            }
        }
    }

    func playSingle(at cell: Int) -> UInt8? {
        let board = progress.current.board
        guard (0..<81).contains(cell), board.values[cell] == 0 else { return nil }
        let visible = mouseOptions.displayedMask(board, at: cell)
        if visible.nonzeroBitCount == 1 { return UInt8(visible.trailingZeroBitCount + 1) }
        guard hintDigits.nonzeroBitCount == 1, board.candidates[cell] & hintDigits != 0 else { return nil }
        let digit = UInt8(hintDigits.trailingZeroBitCount + 1)
        let other = board.values.indices.filter { $0 != cell && board.candidates[$0] & hintDigits != 0 }
        if !other.contains(where: { $0 / 9 == cell / 9 }) || !other.contains(where: { $0 % 9 == cell % 9 }) ||
            !other.contains(where: { $0 / 27 == cell / 27 && $0 % 9 / 3 == cell % 9 / 3 }) {
            return digit
        }
        return nil
    }

    private func releasePlay(_ point: CGPoint, button: BoardButton, at now: Int, geometry: BoardGeometry,
                             modifiers: BoardModifiers?) {
        guard canEdit, frozen == nil, let down = playMouse.press, down.button == button else { return }
        playMouse.press = nil
        defer {
            if drag != nil { objectWillChange.send(); drag = nil }
            if let prior = endingBorrow { chooseTool(prior) }
        }
        if playMouse.moved {
            if button == .left && down.modifiers.contains(.command) {
                selectCells(NativePlayMouse.marquee(from: down.cell, to: point, geometry: geometry))
            }
            playMouse.previous = nil
            let count = selectionCells.count
            if button == .left && down.modifiers.contains(.command) {
                showOperationMessage(count > 0 ? "已选 \(count) 格" : "框内没有选中的格")
            } else {
                showOperationMessage(button == .left ? "按住 ⌘ 拖动可框选多格" : "选区保持不变")
            }
            didFinishPointerGesture?(BoardPointerFeedback(button: button, isDouble: playMouse.secondPress, isDrag: true))
            return
        }
        guard let cell = geometry.cell(at: point), let slot = geometry.digitSlot(at: point) else {
            showOperationMessage("点棋盘内的格子可选中")
            return
        }
        let digit = UInt8(slot)
        let flags = modifiers ?? down.modifiers
        let twice = playMouse.released(cell: cell, digit: slot, at: now, interval: playInterval)
        let before = progress.current
        let didDrag = playMouse.moved
        let dragBeganWithSecondPress = playMouse.secondPress
        var unavailable: String?
        defer {
            didFinishPointerGesture?(BoardPointerFeedback(button: button,
                isDouble: didDrag ? dragBeganWithSecondPress : twice, isDrag: didDrag))
            let after = progress.current
            if let unavailable {
                unavailableOperation(unavailable)
            } else if after.board.values[cell] != before.board.values[cell] {
                let digit = after.board.values[cell]
                showOperationMessage(digit == 0 ? "已清除填数" : "已填入 \(digit)")
            } else if after.board != before.board {
                showOperationMessage("已更新候选数")
            } else if after.marks != before.marks {
                showOperationMessage("已更新标色")
            } else if !selectionCells.isEmpty {
                showOperationMessage("已选 \(selectionCells.count) 格")
            } else {
                showOperationMessage("已取消选区")
            }
            if after.board != before.board {
                if after.board.values[cell] != before.board.values[cell] {
                    playDigitEntrySound(after.board.values[cell], cells: [cell])
                } else {
                    playOperationSound(.edit)
                }
            }
        }
        if playMouse.deselectOnRelease && !twice && flags.isEmpty && down.cell == cell && button == .left {
            select(nil)
            return
        }
        if button == .right {
            if mouseOptions.singleClickMode { togglePlayCandidate(digit, in: selectionCells) }
            return
        }
        let board = progress.current.board
        let bit = NativeBoardSnapshot.bit(digit)
        let visible = mouseOptions.displayedMask(board, at: cell) & bit != 0
        if flags == .option && down.cell == cell && down.digit == slot && visible && board.values[cell] == 0 {
            togglePlayMark(cell: cell, digit: slot, group: palettes[.color] ?? 0)
            return
        }
        if flags.contains(.command) {
            if twice { togglePlayCandidate(digit, at: cell); select(selected) }
            return
        }
        if !twice && flags.contains(.shift) {
            if !mouseOptions.useShiftForRegionSelect { togglePlayCandidate(digit, at: cell) }
            return
        }
        if !twice && !mouseOptions.singleClickMode { return }
        if !twice {
            // Java's single-click mode first replaces the selection with the clicked cell.
            select(cell)
            if board.values[cell] == 0 && visible { changePlayBoard { $0.setValue(digit, at: cell) } }
            return
        }
        let value: UInt8
        if board.values[cell] != 0 {
            guard !board.fixed[cell] else { unavailable = "给定数不能修改。"; return }
            value = 0
        } else if !visible && mouseOptions.showCandidates && mouseOptions.showDeviations && inkUniqueness.solution?[cell] == digit {
            value = digit
        } else if let single = playSingle(at: cell) {
            value = single
        } else if visible {
            value = digit
        } else {
            unavailable = "这里没有可填入的候选数。"
            return
        }
        changePlayBoard { $0.setValue(value, at: cell) }
        if mouseOptions.autoHighlighting { hintDigits = value == 0 ? 0 : NativeBoardSnapshot.bit(value) }
    }

    private func hasAnnotationDouble(_ press: BoardPress, geometry: BoardGeometry) -> Bool {
        if press.modifiers.contains(.command) {
            guard tool == .ink, press.modifiers == .command, press.button == .left,
                  let cell = press.cell, let digit = press.digit else { return false }
            let marks = progress.current.ink.strokes.filter { $0.cell == cell && $0.digit == digit && $0.group == color }
            return marks.contains(where: { $0.kind == .circle }) && marks.contains(where: { $0.kind == .cross })
        }
        if chainSession.endpoint != nil { return false }
        switch tool {
        case .color: return press.button == .right || press.digit != nil && !press.modifiers.contains(.shift)
        case .ink: return press.button == .right || press.modifiers.isDisjoint(with: [.shift, .control])
        case .chain:
            if !previewKeys.isEmpty { return false }
            if press.modifiers.isEmpty { return geometry.bounds.contains(press.point) }
            return press.digit != nil || (press.cell == nil && press.button == .left && press.modifiers.isDisjoint(with: [.shift, .control]))
        case .boxes, .play: return false
        }
    }

    private func performClick(_ p: BoardPress, twice: Bool) {
        guard let g = lastGeometry else { return }
        let before = progress.current
        switch tool {
        case .play: return
        case .color: _ = colorClick(p, twice: twice)
        case .boxes:
            progress.current.boxes.edit(
                start: p.point, end: p.point, dragged: false, erase: p.erases, group: color, deleteGroup: groupOnPress,
                geometry: g)
        case .chain:
            chainSession.click(
                p, twice: twice, preciseEligible: preciseOnFirst, palette: color, deleteGroup: groupOnPress,
                preview: !previewKeys.isEmpty, board: before.board, state: &progress.current.chains,
                boxes: before.boxes, ink: before.ink)
        case .ink:
            if p.erases {
                let d = BoardDrag(points: [p.point], rectangle: false, radius: (g.grid.width + 20) * radius)
                progress.current.ink = before.ink.erased(
                    d, group: groupOnPress, whole: wholeStroke, geometry: g, candidateFontFactor: candidateInkFontFactor).kept
            } else if let cell = p.cell, let digit = p.digit {
                let kind: InkStroke.Kind = twice || p.modifiers.contains(.shift) ? .cross : .circle
                if p.modifiers.contains(.command) {
                    let both = before.ink.strokes.filter { $0.cell == cell && $0.digit == digit && $0.group == color }
                    _ = InkReasoning.toggleOutline(
                        in: &progress.current.ink, group: color, cell: cell, digit: digit,
                        kind: Set(both.map(\.kind)).count > 1 ? kind : nil, board: before.board,
                        unique: inkUnique(before))
                } else {
                    _ = InkReasoning.toggleMark(
                        InkStroke(kind: kind, group: color, width: Self.widths[inkWidth], cell: cell, digit: digit, light: authoredLight),
                        in: &progress.current.ink, board: before.board, enteringStart: gOnPress,
                        unique: inkUnique(before))
                }
            }
        }
        register(before)
    }

    private func showDragGuidance(_ press: BoardPress, rectangle: Bool) {
        switch tool {
        case .chain:
            showOperationMessage(press.erases ? "继续拖拽以删除框内链线" : "继续拖拽以切换框内链线的强弱")
        case .ink:
            if press.erases {
                showOperationMessage(rectangle ? "拖拽框选以批量删除" : wholeStroke ? "拖拽以擦除整笔" : "拖拽以局部擦除")
            } else {
                showOperationMessage(rectangle ? "拖拽以绘制椭圆" : "拖拽以自由涂鸦")
            }
        case .color:
            if press.erases { showOperationMessage("拖拽以擦除标色") }
        case .boxes:
            showOperationMessage(press.erases ? "拖拽以移除框内选区" : "拖拽以框选格子")
        case .play: break
        }
    }

    private func showPointerResult(_ before: BoardPage, press: BoardPress, dragged: Bool,
                                   double: Bool = false, precise: Bool = false) {
        let after = progress.current
        switch tool {
        case .play: return
        case .color:
            let added = Set(after.marks).subtracting(before.marks).count
            let removed = Set(before.marks).subtracting(after.marks).count
            if added > 0 { showOperationMessage("已标色 \(added) 项") }
            else if removed > 0 { showOperationMessage("已擦除 \(removed) 项标色") }
            else { showOperationMessage("没有可更改的标色") }
        case .ink:
            if press.erases {
                let hit = before.ink != after.ink
                showOperationMessage(!hit ? "没有擦到笔迹" : dragged && drag?.rectangle == true
                    ? "已删除框内笔迹" : wholeStroke ? "已擦除整笔" : "已擦除触及的笔迹")
            } else if dragged {
                showOperationMessage(drag?.rectangle == true ? "已绘制椭圆" : "已绘制自由笔迹")
            } else if before.ink != after.ink {
                if press.modifiers.contains(.command) { showOperationMessage("已切换涂鸦轮廓归属") }
                else if after.ink.strokes.count < before.ink.strokes.count { showOperationMessage("已移除候选标记") }
                else { showOperationMessage(double || press.modifiers.contains(.shift) ? "已标记叉号" : "已圈出候选") }
            } else if press.digit == nil { showOperationMessage("点击候选可圈出数字") }
            else { showOperationMessage("候选标记没有变化") }
        case .chain:
            let old = before.chains, new = after.chains
            if dragged {
                if old.paths == new.paths { showOperationMessage(press.erases ? "框内没有可删除的链线" : "框内没有可切换的链线") }
                else { showOperationMessage(press.erases ? "已删除框内链线" : "已切换框内链线的强弱") }
            } else if let rejection = chainSession.previewRejection {
                showOperationFeedback(generalOptions.localized(rejection.message), sound: .unavailable)
            } else if chainSession.endpoint != nil {
                showOperationMessage(press.erases ? "右键点另一端，精确删除这条链线" : "左键点另一端，精确切换这条链线的强弱")
            } else if precise {
                let changed = old.paths != new.paths
                showOperationMessage(!changed ? "两端之间的链线未改变" : press.erases ? "已删除指定链线" : "已切换指定链线的强弱")
            } else if !chainSession.choices.isEmpty {
                showOperationMessage(chainSession.startingSegment ? "请选择起点" : "请选择要连接的链组")
            } else if press.erases {
                if old.paths == new.paths { showOperationMessage("没有可移除的链线") }
                else {
                    let removedLink = old.paths.reduce(0) { $0 + $1.edges.count } > new.paths.reduce(0) { $0 + $1.edges.count }
                    showOperationMessage(removedLink ? "已移除最近一条链线" : "已移除最近端点")
                }
            } else if double && press.modifiers.isEmpty {
                if let strong = new.latestIsStrong, strong != old.latestIsStrong {
                    showOperationMessage(strong ? "最近一条已改为强链" : "最近一条已改为弱链")
                } else { showOperationMessage("没有可切换的链线") }
            } else if old.paths.reduce(0, { $0 + $1.edges.count }) < new.paths.reduce(0, { $0 + $1.edges.count }) {
                showOperationMessage(old.nextStrong ? "已连接强链" : "已连接弱链")
            } else if old.paths != new.paths {
                showOperationMessage(press.modifiers.contains(.shift) && !double ? "已扩展端点组" : "已选起点，点击候选连接下一端")
            } else if press.modifiers == .command && old.active != new.active {
                showOperationMessage("已选起点，点击候选连接下一端")
            } else if old.active != nil && new.active == nil {
                showOperationMessage("已结束当前链")
            } else if old.nextStrong != new.nextStrong {
                showNextChainRelation()
            } else {
                showOperationMessage(press.digit == nil ? "点击候选以连接链线" : "此端点未连接")
            }
        case .boxes:
            showOperationMessage(before.boxes == after.boxes ? "选框没有变化" :
                                 press.erases ? "已移除选框内的格子" : "当前选框共 \(after.boxes.footprint.count) 格")
        }
    }

    @discardableResult private func replaceMarks(_ marks: [BoardMark]) -> Bool {
        guard marks != progress.current.marks else { return false }
        progress.markUndo.append(progress.current.marks)
        progress.markRedo.removeAll()
        progress.current.marks = marks
        return true
    }

    private func colorClick(_ press: BoardPress, twice: Bool) -> Bool {
        guard !press.modifiers.contains(.command), !press.modifiers.contains(.option) else { return false }
        var marks = progress.current.marks
        guard let cell = press.cell else {
            if press.erases, let i = marks.lastIndex(where: { groupOnPress == nil || $0.color == groupOnPress }) {
                marks.remove(at: i)
                return replaceMarks(marks)
            }
            return false
        }
        guard press.erases || generalOptions.colorValues || progress.current.board.values[cell] == 0 else { return false }
        let digit = twice || press.modifiers.contains(.shift) ? press.digit : 0
        guard let digit = digit else { return false }
        let mark = BoardMark(cell: cell, digit: digit, color: color, light: authoredLight)
        if let i = marks.firstIndex(where: { $0.cell == cell && $0.digit == digit }) {
            if press.erases {
                if groupOnPress == nil || marks[i].color == groupOnPress { marks.remove(at: i) }
            } else {
                marks[i] = mark
            }
        } else if !press.erases {
            marks.append(mark)
        }
        return replaceMarks(marks)
    }

    // MARK: - Hint requests, reading and confirmation

    func closeHint() { resetHint(keepingTechniqueCatalogue: false) }

    private func resetHint(keepingTechniqueCatalogue: Bool) {
        objectWillChange.send()
        hintDrawerCollapsed = false
        transcription = nil
        transcriptionProblem = nil
        hintRequests.cancel()
        cancelReasoningSearch()
        techniqueReadingID = nil
        if keepingTechniqueCatalogue { namedCatalogue.previewCells = nil }
        else { clearTechniqueCatalogue() }
        knownTechnique = nil
        knownTechniqueInstance = nil
        readingOrigin = nil
        tabGroup = nil
        acceptedDigits = 0
        reading = nil
        interruptedReading = nil
        timeline.observe(progress.current, proof: nil)
        sourceIsCurrent = nil
        resetHintPreview()
    }

    private func resetHintPreview(keepingKey: Bool = false) {
        hoveredReference = nil
        wholeHint = false
        hint = hint.rebound(to: reading?.current.references.count ?? 0, keepingKey: keepingKey)
        hint.setPaused(!hintHasFocus, now: Self.now)
        schedule()
    }

    private func clearTechniqueCatalogue() {
        namedCatalogue.clear()
        techniqueSelection = nil
        techniqueReadingID = nil
    }

    @discardableResult
    func returnToTechniqueChooser() -> Bool {
        guard canReturnToTechniqueChooser else { return false }
        resetHint(keepingTechniqueCatalogue: true)
        return true
    }

    func openTechniqueChooser() {
        cancelReasoningSearch()
        guard canEdit, frozen == nil, !choosingTechnique || techniqueTab != .techniques || staleReasoning else { return }
        cancelHintPreparation()
        showingSolutionPath = false
        objectWillChange.send()
        // Opening the palette replaces an in-flight lookup, but cancellation
        // of the palette preserves an already accepted reading.
        if hintRequestPending { closeHint() }
        clearTechniqueCatalogue()
        namedCatalogue.open(reasoningInput, config: solverConfig, scopes: availableMatchInputs) { [weak self] in self?.objectWillChange.send() }
    }

    func openCurrentReasoning() {
        guard canEdit, frozen == nil, !choosingTechnique || currentReasoning == nil || staleReasoning else { return }
        guard let scope = matchInput else {
            cancelReasoningSearch()
            missingMatchInput()
            return
        }
        guard reasoningSearchScope != scope else { return }
        cancelHintPreparation()
        let input = reasoningInput
        guard input.board.values.contains(0),
              input.board.values.indices.allSatisfy({ cell in
                  let value = input.board.values[cell], legal = input.board.legalMask(at: cell)
                  if value != 0 { return legal & NativeBoardSnapshot.bit(value) != 0 }
                  let candidates = input.board.candidates[cell]
                  return candidates != 0 && candidates & ~legal == 0
              }) else {
            cancelReasoningSearch()
            showAnalysisMessage("当前盘面无法查找思路。请检查已填数字和候选数。")
            return
        }
        if hintRequestPending { closeHint() }
        objectWillChange.send()
        clearOperationMessage(identifier: "native-board-operation-message")
        reasoningSearchScope = scope
        let config = solverConfig
        inkUniqueness.request(for: input.board) { [weak self] in self?.receivedSolution() }
        inkUniqueness.whenResolvedForReasoning { [weak self] solution in
            guard let self, self.reasoningSearchScope == scope, self.progress.current.board == input.board else { return }
            self.findCurrentReasoning(scope, input: input, config: config, solution: solution)
        }
    }

    private func findCurrentReasoning(_ scope: NativeHintMatchInput, input: CurrentReasoningInput,
                                      config: NativeSolverConfig, solution: [UInt8]?) {
        let prepared = preparedHints
        reasoningRequests.start(source: scope.source, compute: { cancelled -> [NativeHintStep]? in
            if let solution, !input.agrees(with: solution) { return nil }
            return try prepared.steps(scope, on: input.board, config: config, firstOnly: false, cancelled: cancelled)
        }, deliver: { [weak self] outcome, _ in
            guard let self else { return }
            self.objectWillChange.send()
            self.reasoningSearchScope = nil
            guard self.canEdit, self.frozen == nil, self.progress.current.board == input.board, self.matchInput == scope else { return }
            switch outcome {
            case .success(.some(let steps)) where !steps.isEmpty:
                self.showingSolutionPath = false
                self.clearTechniqueCatalogue()
                self.namedCatalogue.showMatches(steps, input: input, scope: scope)
            case .success(.some):
                self.showAnalysisMessage(scope.source.noMatchMessage)
            case .success(.none):
                self.showAnalysisMessage("已填数字或剩余候选与本题的唯一解不符。请检查盘面。")
            case .failure(let error):
                self.showAnalysisMessage(error.localizedDescription, sound: .failure)
            }
        })
    }

    private func cancelReasoningSearch() {
        guard reasoningSearchScope != nil else { return }
        inkUniqueness.stopWaitingForReasoning()
        objectWillChange.send()
        reasoningSearchScope = nil
        reasoningRequests.cancel()
    }

    private func invalidateReasoningSearch() {
        if let scope = reasoningSearchScope,
           (scope != matchInput || frozen != nil || !canEdit) { cancelReasoningSearch() }
    }

    func techniqueRelations(for kind: NativeHintTechnique) -> [NativeTechniqueRelation] {
        namedCatalogue.relations(for: techniqueInstances[kind] ?? [], input: reasoningInput, currentScopes: availableMatchInputs)
    }

    func techniqueRelations(for instance: NativeTechniqueInstance) -> [NativeTechniqueRelation] {
        namedCatalogue.relations(for: [instance.step], input: reasoningInput, currentScopes: availableMatchInputs)
    }

    func openSolutionPath() {
        cancelReasoningSearch()
        guard canEdit, frozen == nil, !showingSolutionPath else { return }
        if hintRequestPending { closeHint() }
        clearTechniqueCatalogue()
        showingSolutionPath = true
    }

    func closeTechniqueChooser() {
        cancelReasoningSearch()
        guard choosingTechnique else { return }
        objectWillChange.send()
        clearTechniqueCatalogue()
        if showingSolutionPath { showingSolutionPath = false }
    }

    func techniqueChoices(_ kind: NativeHintTechnique) -> [NativeTechniqueInstance] {
        namedCatalogue.numberedInstances(kind)
    }

    func adoptTechnique(_ step: NativeHintStep) {
        guard let instance = techniqueChoices(step.technique).first(where: { $0.step == step }) else { return }
        adoptTechnique(instance)
    }

    private func currentInstance(_ instance: NativeTechniqueInstance) -> Bool {
        choosingTechnique && canEdit && frozen == nil && !staleReasoning && namedCatalogue.source == progress.current.board &&
            namedCatalogue.owns(instance)
    }

    func adoptTechnique(_ instance: NativeTechniqueInstance) {
        guard currentInstance(instance), let board = namedCatalogue.source else { return }
        let step = instance.step, context = currentReasoning
        let page = progress.current
        if reviewHint(step, source: board, keepingTechniqueCatalogue: true, sourceIsCurrent: { [weak self] in
            guard let self else { return false }
            switch context?.kind {
            case .boxes: return self.progress.current.boxes == page.boxes
            case .chain: return self.progress.current.chains == page.chains
            case .digits, nil: return true
            }
        }) {
            techniqueSelection = instance
            techniqueReadingID = reading?.id
            knownTechnique = step.technique
            knownTechniqueInstance = "实例 \(instance.number)/\(instance.total)"
        }
    }

    var namedTechniques: [NativeHintTechnique] {
        if currentReasoning != nil { return namedCatalogue.preferredOrder }
        var rank = [String: Int]()
        for rule in solverConfig.rules where rule.enabled {
            for kind in NativeFineHints.types(rule.kind) { rank[kind] = rule.index }
            if rule.kind == "SIMPLE_COLORS" {
                rank["SIMPLE_COLORS_TRAP"] = rule.index
                rank["SIMPLE_COLORS_WRAP"] = rule.index
            }
            if rule.kind == "MULTI_COLORS" {
                rank["MULTI_COLORS_1"] = rule.index
                rank["MULTI_COLORS_2"] = rule.index
            }
        }
        return techniqueInstances.keys.sorted { (rank[$0.key] ?? Int.max, $0.key) < (rank[$1.key] ?? Int.max, $1.key) }
    }

    func adoptDefaultHint() {
        closeHint()
        openHint()
    }

    func previewTechnique(_ step: NativeHintStep?) {
        guard choosingTechnique else { return }
        let choice = step.flatMap { selected in techniqueChoices(selected.technique).first { $0.step == selected } }
        previewInstance(choice)
    }

    func previewInstance(_ choice: NativeTechniqueInstance?) {
        guard choosingTechnique else { return }
        let cells = choice.flatMap { currentInstance($0) ? $0.cells : nil }
        guard cells != namedCatalogue.previewCells else { return }
        objectWillChange.send()
        namedCatalogue.previewCells = cells
    }

    @discardableResult
    func annotateInstance(_ instance: NativeTechniqueInstance, group: Int, box: Bool) -> Bool {
        guard (0..<AnnotationPalette.names.count).contains(group), currentInstance(instance) else { return false }
        finishPointer()
        guard currentInstance(instance) else { return false }
        return annotateHintCells(Set(instance.cells), group: group, box: box)
    }

    func openHint() {
        guard canEdit, frozen == nil else { return }
        if let reading = reading, reading.source == progress.current.board, sourceIsCurrent?() == true { return }
        if hintRequests.source == .ordinary { return }
        requestOrdinaryHint(continuing: interruptedReading)
    }

    private func requestOrdinaryHint(continuing previous: NativeHintReading?) {
        let board = progress.current.board
        let policy = solverConfig
        let options = generalOptions
        let prepared = preparedHints
        requestHint(from: .ordinary, board: board, keepText:previous) { cancelled in
            if let previous = previous, previous.source != board,
               let resumed = try previous.revalidated(on:board,config:policy,cancelled:cancelled) { return resumed }
            let path = try prepared.ordinary(board, config: policy, cancelled: cancelled)
            if let step = path.steps.first, step.kind != "GIVE_UP" {
                let hint = step.hint()
                if let previous = previous, previous.source == board, previous.isFinal, previous.step == hint {
                    let next = NativeHintReading(step:hint, source:board)
                    return .step(hint,stages:next.stages,index:next.stages.count - 1)
                }
                return .step(hint)
            }
            if path.ending == .unrated { return .notice("当前鱼型设置无法给出可验证的下一步。") }
            if let kind = path.missing {
                return .notice(String(format: options.localized("当前尚未支持搜索「%@」。"), NativeHintTechnique(key: kind).name))
            }
            return board.values.contains(0) ? .noMatch : .notice("棋盘已填满。")
        }
    }

    private var boxHintFilter: UInt16 {
        !inverseFilter && hintDigits.nonzeroBitCount == 1 ? hintDigits : 0
    }

    private func cancelPendingBoxHintIfFilterChanged() {
        if hintRequests.source == .boxes || hintRequests.source == .tabBoxes,
           acceptedDigits != boxHintFilter {
            closeHint()
        }
    }

    func openBoxHint(cells: [Int], sourceIsCurrent: @escaping () -> Bool) {
        guard canEdit, frozen == nil else { return }
        let board = progress.current.board
        guard !cells.isEmpty else {
            showAnalysisMessage("先框选要分析的格")
            return
        }
        let config = solverConfig
        let filter = boxHintFilter
        let digit = filter == 0 ? nil : UInt8(filter.trailingZeroBitCount + 1)
        requestHint(from: .boxes, board: board, sourceIsCurrent: sourceIsCurrent) { cancelled in
            if let match = try NativeFineHints.search(.boxes(Set(cells), active: false, allowPartial: true),
                                                     board: board, config: config, preferredDigit: digit, cancelled: cancelled) {
                return .step(match.step, partial: match.partial)
            }
            return .noMatch
        }
        acceptedDigits = filter
    }

    func toggleHintDigit(_ digit: UInt8, additive: Bool) {
        guard canEdit, frozen == nil, (1...9).contains(digit) else { return }
        let bit = NativeBoardSnapshot.bit(digit)
        let next = additive ? (hintDigits ^ bit) : (hintDigits & bit != 0 ? 0 : bit)
        objectWillChange.send()
        if hintRequests.source == .tabDigits { closeHint() }
        hintDigits = next
        let selected = NativeBoardStatus.digits(next)
        showOperationMessage(selected.isEmpty ? "已清除数字筛选" : "筛选数字 \(selected)")
    }

    private var digitMatchInput: NativeHintMatchInput? {
        let digits = Set((UInt8(1)...9).filter { hintDigits & NativeBoardSnapshot.bit($0) != 0 })
        return (1...2).contains(digits.count) ? .digits(digits) : nil
    }

    private var boxMatchInput: NativeHintMatchInput? {
        let boxes = progress.current.boxes
        guard !boxes.footprint.isEmpty else { return nil }
        let preferred = boxHintFilter == 0 ? nil : UInt8(boxHintFilter.trailingZeroBitCount + 1)
        return .boxes(groups: boxes.groups, active: palettes[.boxes] ?? 0, digit: preferred)
    }

    private var chainMatchInput: NativeHintMatchInput? {
        NativeFineChain(authored: progress.current.chains, board: progress.current.board).map(NativeHintMatchInput.chain)
    }

    private var matchInput: NativeHintMatchInput? {
        if tool == .chain, !progress.current.chains.paths.isEmpty { return chainMatchInput }
        if tool == .boxes, let boxes = boxMatchInput { return boxes }
        return digitMatchInput
    }

    private var availableMatchInputs: [NativeHintMatchInput] {
        [boxMatchInput, chainMatchInput, digitMatchInput].compactMap { $0 }
    }

    private func cancelHintPreparation() {
        scheduledPreparation?.cancel()
        scheduledPreparation = nil
        pendingPreparation?.cancel()
        pendingPreparation = nil
    }

    private func scheduleHintPreparation() {
        cancelHintPreparation()
        guard automaticTimers, canEdit, frozen == nil, hintHasFocus, preparationPauses.isEmpty else { return }
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.canEdit, self.frozen == nil, self.hintHasFocus, self.preparationPauses.isEmpty,
                  self.active == nil, self.pending == nil, self.playMouse.press == nil,
                  !self.hintRequestPending, !self.choosingTechnique, self.reasoningSearchScope == nil,
                  self.visibleReading == nil, self.progress.current.board.values.contains(0) else { return }
            // A drawn chain requires high-order search. Avoid even building its matching
            // representation on the main thread for a speculative request.
            if self.tool == .chain && !self.progress.current.chains.paths.isEmpty { return }
            let scope = self.tool == .boxes ? self.boxMatchInput ?? self.digitMatchInput : self.digitMatchInput
            let board = self.progress.current.board, config = self.solverConfig, prepared = self.preparedHints
            let task = BlockOperation()
            task.addExecutionBlock { [weak task] in
                guard let task, !task.isCancelled else { return }
                prepared.prepare(board, config: config, scope: scope, cancelled: { task.isCancelled })
            }
            self.pendingPreparation = task
            self.preparationQueue.async { task.start() }
        }
        scheduledPreparation = item
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(350), execute: item)
    }

    private func missingMatchInput() {
        let chain = progress.current.chains
        if tool == .chain, !chain.paths.isEmpty {
            let assembly = chain.assembly()
            showAnalysisMessage(assembly.path == nil ? assembly.message : "无法按当前链查找。请检查链的端点和强弱关系。")
        } else {
            showAnalysisMessage("先筛选 1 或 2 个数字，或按 ⌥F12 查找全盘。")
        }
    }

    func analyzeHint(fresh: Bool = false, previous: Bool = false) {
        guard canEdit, frozen == nil, !choosingTechnique else { return }
        cancelReasoningSearch()
        if !fresh {
            if let reading {
                setHintDrawerCollapsed(false)
                if previous { moveHint(-1) }
                else if !reading.isFinal { moveHint(1) }
                return
            }
            if interruptedReading != nil {
                if !previous { moveHint(1) }
                return
            }
            if hintRequestPending {
                if !previous { _ = hintRequests.deferInput(.advanceAnalysis) }
                return
            }
            if previous { return }
        }

        if tool == .ink {
            finishPointer()
            if inspectInk(from: progress.current, applyPreview: false) { return }
            if digitMatchInput == nil {
                showAnalysisMessage("当前涂鸦没有可应用的结论")
                return
            }
        }
        if tool == .chain, !progress.current.chains.paths.isEmpty, chainMatchInput == nil {
            inspectSource(applyPreview: false)
            return
        }
        quickHint(force: fresh, includeAuthoredAnalysis: true)
    }

    // Select the first proof using the same scope and ordering as the matching catalogue.
    func quickHint(force: Bool = false, includeAuthoredAnalysis: Bool = false) {
        guard canEdit, frozen == nil else { return }
        guard let input = matchInput else {
            if !force { closeHint() }
            missingMatchInput()
            return
        }
        let page = progress.current
        let tool = tool
        let filter = input.kind == .boxes ? boxHintFilter : hintDigits
        let group = color
        if !force, readingOrigin == input.source || hintRequests.source == input.source {
            switch input.kind {
            case .chain: if sourceIsCurrent?() == true { return }
            case .boxes: if tabGroup == group, acceptedDigits == filter, sourceIsCurrent?() == true { return }
            case .digits: if acceptedDigits == filter { return }
            }
        }
        let config = solverConfig
        let prepared = preparedHints
        requestHint(from: input.source, board: page.board, sourceIsCurrent: { [weak self] in
            guard let self else { return false }
            switch input.kind {
            case .boxes: return self.progress.current.boxes == page.boxes
            case .chain: return self.progress.current.chains == page.chains
            case .digits: return true
            }
        }, requestIsCurrent: { [weak self] in self?.tool == tool && self?.matchInput == input }) { cancelled in
            if let step = try prepared.steps(input, on: page.board, config: config, firstOnly: true, cancelled: cancelled).first {
                return .step(step)
            }
            guard includeAuthoredAnalysis, !cancelled() else { return .noMatch }
            switch input {
            case let .boxes(groups, _, digit):
                let cells = Set(groups.joined())
                if let match = try NativeFineHints.search(.boxes(cells, active: false, allowPartial: true),
                    board: page.board, config: config, preferredDigit: digit, cancelled: cancelled) {
                    return .step(match.step, partial: match.partial)
                }
            case .chain:
                if let path = page.chains.assembly().path {
                    return try Self.authoredChainAnswer(path, board: page.board)
                }
            case .digits: break
            }
            return .noMatch
        }
        tabGroup = input.kind == .boxes ? group : nil
        acceptedDigits = filter
    }

    private func requestHint(
        from kind: NativeHintRequests.Source, board: NativeBoardSnapshot, keepText: NativeHintReading? = nil,
        sourceIsCurrent: @escaping () -> Bool = { true },
        requestIsCurrent: @escaping () -> Bool = { true },
        compute: @escaping (() -> Bool) throws -> NativeHintAnswer
    ) {
        let keepCollapsed = keepText != nil && hintDrawerCollapsed
        cancelHintPreparation()
        closeHint()
        interruptedReading = keepText
        hintDrawerCollapsed = keepCollapsed
        clearOperationMessage(identifier: "native-board-operation-message")
        self.sourceIsCurrent = sourceIsCurrent
        hintRequests.start(
            source: kind, compute: compute,
            deliver: { [weak self] result, inputs in
                guard let self = self else { return }
                guard self.canEdit, self.frozen == nil, self.progress.current.board == board, sourceIsCurrent(), requestIsCurrent() else {
                    self.closeHint()
                    return
                }
                self.objectWillChange.send()
                switch result {
                case .success(.step(let step, let stages, let partial, let index)):
                    let digits = self.acceptedDigits
                    let tabGroup = self.tabGroup
                    let drawerWasCollapsed = self.hintDrawerCollapsed
                    guard self.reviewHint(step, source: board, stages: stages, sourceIsCurrent: sourceIsCurrent) else {
                        self.closeHint()
                        self.showAnalysisMessage(NativeHintError.engine.localizedDescription, sound: .failure)
                        return
                    }
                    self.hintDrawerCollapsed = drawerWasCollapsed
                    self.reading?.index = index
                    self.resetHintPreview()
                    // An authored fallback uses the same annotation and replay lifecycle as the explicit tool action.
                    if step.technique == .userChain, kind == .tabChain { self.readingOrigin = .chain }
                    else if partial, kind == .tabBoxes { self.readingOrigin = .boxes }
                    else { self.readingOrigin = kind }
                    self.tabGroup = tabGroup
                    self.acceptedDigits = digits
                    if !partial && (kind == .boxes || kind == .chain) { self.moveHint(100) }
                    for input in inputs {
                        switch input {
                        case .key(let down, let time):
                            if down { self.hint.press(time) } else { self.hint.release(time) }
                        case .focus(let gained, let time): self.hint.setPaused(!gained, now: time)
                        case .wheel(let delta, let time): _ = self.hint.wheel(delta, now: time)
                        case .move(let change): self.moveHint(change)
                        case .advanceAnalysis:
                            if self.reading?.isFinal == false { self.moveHint(1) }
                        }
                    }
                    if self.automaticTimers { self.hint.tick(Self.now) }
                    self.schedule()
                case .success(.noMatch):
                    self.closeHint()
                    self.showAnalysisMessage(kind.noMatchMessage)
                case .success(.notice(let text)):
                    self.closeHint()
                    self.showAnalysisMessage(text)
                case .failure(let error):
                    self.closeHint()
                    self.showAnalysisMessage(error.localizedDescription, sound: .failure)
                }
            })
    }

    @discardableResult
    func reviewHint(
        _ step: NativeHintStep, source: NativeBoardSnapshot, stages: [NativeHintStage]? = nil,
        keepingTechniqueCatalogue: Bool = false, sourceIsCurrent: @escaping () -> Bool = { true }
    ) -> Bool {
        guard canEdit, frozen == nil, source == progress.current.board, sourceIsCurrent(),
            step.applying(to: source) != nil
        else { return false }
        if (step.technique == .userChain || step.technique == .userInk) && stages?.isEmpty != false { return false }
        resetHint(keepingTechniqueCatalogue: keepingTechniqueCatalogue)
        reading = NativeHintReading(step: step, source: source, stages: stages)
        self.sourceIsCurrent = sourceIsCurrent
        timeline.observe(progress.current, proof: reading?.id)
        resetHintPreview()
        return true
    }

    func invalidateHintSourceIfNeeded() {
        invalidateReasoningSearch()
        if sourceIsCurrent?() == false { closeHint() }
    }

    func moveHint(_ change: Int) {
        guard frozen == nil else { return }
        if interruptedReading != nil, hintRequestPending { return }
        if hintRequests.deferInput(.move(change)) { return }
        if let prior = interruptedReading {
            if change > 0 { requestOrdinaryHint(continuing:prior) }
            return
        }
        guard reading != nil else {
            openHint()
            return
        }
        guard let current = reading else { return }
        if change == 1 && current.isFinal { requestOrdinaryHint(continuing:current); return }
        let index = min(max(0, current.index + change), current.stages.count - 1)
        guard index != current.index else { return }
        objectWillChange.send()
        reading?.index = index
        resetHintPreview(keepingKey: true)
    }

    @discardableResult
    func annotateHint(id: UUID, stage: Int, reference: Int?, whole: Bool, group: Int, box: Bool) -> Bool {
        guard canEdit, frozen == nil, (0..<4).contains(group), let reading = reading,
            id == reading.id, stage == reading.index, reading.source == progress.current.board,
            sourceIsCurrent?() == true
        else { return false }
        let refs = reading.current.references
        let cells: Set<Int>
        if let index = reference, refs.indices.contains(index) {
            cells = Set(refs[index].cells)
        } else if whole {
            cells = Set(reading.wholeReferences.flatMap(\.cells))
        } else {
            return false
        }
        finishPointer()
        guard reading.source == progress.current.board, sourceIsCurrent?() == true else { return false }
        return annotateHintCells(cells, group: group, box: box)
    }

    private func annotateHintCells(_ cells: Set<Int>, group: Int, box: Bool) -> Bool {
        guard !cells.isEmpty else { return false }
        objectWillChange.send()
        let before = progress.current
        if box {
            progress.current.boxes.groups[group].formUnion(cells)
        } else {
            var marks = before.marks.filter { !($0.digit == 0 && cells.contains($0.cell)) }
            for cell in cells.sorted() where !before.marks.contains(BoardMark(cell: cell, digit: 0, color: group)) {
                marks.append(BoardMark(cell: cell, digit: 0, color: group))
            }
            _ = replaceMarks(marks)
        }
        commitAnnotation(before)
        return true
    }

    func hintHover(_ index: Int?, whole: Bool = false) {
        guard frozen == nil, index != hoveredReference || whole != wholeHint else { return }
        objectWillChange.send()
        hoveredReference = index
        wholeHint = whole
    }

    @discardableResult
    func applyHint(id: UUID) -> Bool {
        if let pending = transcription { return pending.reading == id && confirmChainTranscription() }
        guard canEdit, frozen == nil, let reading = reading, reading.id == id,
            reading.isFinal
        else { return false }
        guard reading.source == progress.current.board, sourceIsCurrent?() == true,
            let changed = reading.step.applying(to: reading.source)
        else {
            closeHint()
            return false
        }
        objectWillChange.send()
        finishPointer()
        guard reading.source == progress.current.board, sourceIsCurrent?() == true else {
            closeHint()
            return false
        }
        if reading.step.technique == .userInk {
            let page = progress.current
            guard let answer = InkReasoning.proposal(in: page.ink, group: color, board: page.board, unique: inkUnique(page)),
                  answer.step == reading.step, answer.board == changed, answer.stage?.text == reading.current.text else {
                closeHint()
                return false
            }
            return commitInkAnswer(answer, from: page)
        }
        let before = progress.current
        var rendered = frame
        rendered.reference = nil
        rendered.preview = []
        let text = reading.stages.map { $0.title + "\n" + $0.text }.joined(separator: "\n\n")
        do {
            var proof = try NativeReplayFrame.capture(rendered, kind: "proof", label: reading.current.title,
                                                        text: text, freeze: true)
            proof.phase = "evidence"
            proof.branchPage = before
            var applied = rendered
            applied.page.board = changed
            applied.showHistoricalRemovals = true
            let image = try BoardPainter.png(applied)
            if readingOrigin == .boxes || readingOrigin == .chain {
                var input = try NativeReplayFrame.capture(BoardFrame(page: before, visual: visual, general: generalOptions), kind: "authored-input",
                                                          label: readingOrigin == .boxes ? "选框" : "自由链", freeze: true)
                input.phase = "input"
                proof.kind = "authored-result"
                proof.phase = "result"
                proofFrames = [input, proof]
            } else { proofFrames = [proof] }
            appliedPreview = (image, text)
            actionLabel = "应用提示"
        } catch { problem = error.localizedDescription; return false }
        if readingOrigin == .boxes { progress.current.boxes.clear(group: nil) }
        if readingOrigin == .chain {
            progress.current.chains.clear(group: nil)
            chainSession.reset()
        }
        register(before)
        tool = .play
        progress.boardUndo.append(progress.current.board)
        progress.boardRedo.removeAll()
        progress.current.board = changed
        boardDidChange(explicitRemovals: reading.step.deletions)
        return true
    }

    func hintKey(down: Bool, now: Int) {
        guard frozen == nil, interruptedReading == nil else { return }
        objectWillChange.send()
        if down, reading == nil, !hintRequestPending { openHint() }
        if hintRequests.deferInput(.key(down: down, time: now)) { return }
        if down {
            hint.press(now)
        } else {
            hint.release(now)
        }
        schedule()
    }

    func wheel(_ delta: Double, now: Int) -> Bool {
        guard frozen == nil else { return false }
        objectWillChange.send()
        return hintRequests.deferInput(.wheel(delta, time: now)) || hint.wheel(delta, now: now)
    }

    // MARK: - Tool shortcuts and source-specific reasoning

    func toolKey(_ key: BoardTool, down: Bool, now: Int) {
        guard canEdit, frozen == nil else { return }
        if down {
            guard toolKeyState == nil else { return }
            let previous = tool
            let double = lastToolTap.flatMap { tap -> BoardTool? in
                tap.key == key && (0...300).contains(now - tap.at) && tap.board == progress.current.board
                    ? tap.origin : nil
            }
            chooseTool(key)
            lastToolTap = nil
            doubleToolOrigin = double
            toolKeyState = (key, previous, now, false)
        } else if let press = toolKeyState, press.key == key {
            let double = doubleToolOrigin
            toolKeyState = nil
            doubleToolOrigin = nil
            if press.used || now - press.at >= 250 {
                if active != nil { endingBorrow = press.previous } else { chooseTool(press.previous) }
            } else if let origin = double {
                if key != .play { clearAnnotations(all: false) }
                chooseTool(key == .play ? .play : origin)
            } else {
                if key != .play, key == press.previous, let origin = settledOrigins[key] {
                    chooseTool(origin)
                } else if key != press.previous {
                    settledOrigins[key] = press.previous
                }
                lastToolTap = (key, now, press.previous, progress.current.board)
            }
        }
    }
    func startKey(down: Bool, now: Int) {
        guard tool == .ink, frozen == nil else { return }
        objectWillChange.send()
        if down {
            guard gPress == nil else { return }
            if let last = gLastTap, (0...300).contains(now - last) {
                finishPointer()
                gLastTap = nil
                enteringStart = false
                let before = progress.current
                if InkReasoning.clearStarts(in: &progress.current.ink, group: color) {
                    playOperationSound(.clear)
                }
                commitAnnotation(before)
            } else {
                gPress = (now, enteringStart, false)
                enteringStart = true
            }
        } else if let p = gPress {
            enteringStart = p.used || now - p.at >= 250 ? false : !p.wasOn
            gLastTap = !p.used && now - p.at < 250 ? now : nil
            gPress = nil
        }
    }
    func toggleStart() {
        objectWillChange.send()
        enteringStart.toggle()
        showOperationMessage(enteringStart ? "点击候选以标记起点" : "已退出起点标记")
    }
    var erasingInk: Bool { tool == .ink && active?.erases == true }
    var eraserModeTitle: String { wholeStroke ? "整笔擦除" : "局部擦除" }
    var nextChainTitle: String { progress.current.chains.nextStrong ? "下一条为强链" : "下一条为弱链" }
    var eraserPercent: Int { Int((radius * 200).rounded()) }
    func chooseWidth(_ index: Int) {
        let width = min(3, max(0, index))
        guard canEdit, tool == .ink, frozen == nil, width != inkWidth else { return }
        objectWillChange.send()
        inkWidth = width
        let requested = Self.widths[width]
        if progress.resizeCandidateMarks(to: requested) { dirty = true }
        if var first = pending {
            _ = first.before.resizeCandidateMarks(to: requested)
            pending = first
        }
        if let end = drag?.points.last, let geometry = lastGeometry { move(end, geometry: geometry) }
        if active == nil && pending == nil { autosave() }
        showOperationMessage("笔宽已改为\(["细", "中", "粗", "特粗"][width])")
    }
    func setCommandDown(_ down: Bool) {
        if commandDown != down {
            objectWillChange.send()
            commandDown = down
        }
    }
    func inkNumber(_ digit: UInt8, cross: Bool) {
        guard tool == .ink, frozen == nil, canEdit, let cell = selected, (1...9).contains(digit) else { return }
        objectWillChange.send()
        finishPointer()
        let before = progress.current
        let mark = InkStroke(
            kind: cross ? .cross : .circle, group: color, width: Self.widths[inkWidth], cell: cell, digit: Int(digit), light: authoredLight)
        _ = InkReasoning.toggleMark(mark, in: &progress.current.ink, board: before.board, enteringStart: enteringStart)
        commitAnnotation(before)
    }
    func toggleEraser() {
        objectWillChange.send()
        finishPointer()
        wholeStroke.toggle()
        showOperationMessage("已切换为\(eraserModeTitle)")
    }
    private func commitAnnotation(_ before: BoardPage) {
        if before.ink != progress.current.ink { transcriptionProblem = nil }
        register(before)
        guard before != progress.current else { return }
        invalidateHintSourceIfNeeded()
        dirty = true
        autosave()
    }
    func clearAnnotations(all: Bool) {
        guard canEdit, frozen == nil else { return }
        objectWillChange.send()
        finishPointer()
        let before = progress.current
        let group = heldGroup
        let scope = all && group == nil ? BoardTool.allCases : [tool]
        if scope.contains(.color) { _ = replaceMarks(before.marks.filter { group != nil && $0.color != group }) }
        if scope.contains(.chain) {
            progress.current.chains.clear(group: group)
            chainSession.reset()
        }
        if scope.contains(.boxes) { progress.current.boxes.clear(group: group) }
        if scope.contains(.ink) {
            if let group = group {
                progress.current.ink.strokes.removeAll { $0.group == group }
                progress.current.ink.consumedGroups.remove(group)
                progress.current.ink.proofs.removeValue(forKey: group)
            } else {
                progress.current.ink = InkToolState()
            }
            enteringStart = false
        }
        if progress.current != before {
            playOperationSound(.eraseInkBatch)
            showOperationMessage(all && group == nil ? "已清除全部批注" : "已清除\(tool.title)批注")
        }
        commitAnnotation(before)
    }
    private func showNextChainRelation() {
        showOperationMessage(nextChainTitle)
    }

    func chainAction(_ action: String) {
        guard tool == .chain, canEdit, frozen == nil else { return }
        objectWillChange.send()
        finishPointer()
        let before = progress.current
        switch action {
        case "next":
            progress.current.chains.toggleNext()
            showNextChainRelation()
        case "back": progress.current.chains.backtrack(deleteGroup: heldGroup)
        default: return
        }
        commitAnnotation(before)
    }

    func chooseChainNode(_ node: ChainToolNode) {
        guard tool == .chain, canEdit, frozen == nil else { return }
        objectWillChange.send()
        finishPointer()
        let before = progress.current
        let startingSegment = chainSession.startingSegment
        chainSession.choose(
            node, board: before.board, state: &progress.current.chains, preview: !previewKeys.isEmpty,
            boxes: before.boxes, ink: before.ink)
        if let rejection = chainSession.previewRejection {
            showOperationFeedback(generalOptions.localized(rejection.message), sound: .unavailable)
        } else if before.chains != progress.current.chains {
            showOperationMessage(startingSegment ? "已选起点，点击候选连接下一端" :
                                 before.chains.nextStrong ? "已连接强链" : "已连接弱链")
        }
        commitAnnotation(before)
    }
    func inspectSource() { inspectSource(applyPreview: true) }

    private func inspectSource(applyPreview: Bool) {
        if transcription != nil {
            if applyPreview { _ = confirmChainTranscription() }
            return
        }
        guard frozen == nil, canEdit else { return }
        objectWillChange.send()
        finishPointer()
        if applyPreview, tool != .ink, let displayed = reading, displayed.isFinal {
            _ = applyHint(id: displayed.id)
            return
        }
        let authored: NativeHintRequests.Source? = tool == .boxes ? .boxes : tool == .chain ? .chain : nil
        if applyPreview, let kind = authored {
            if hintRequests.source == kind, sourceIsCurrent?() == true { return }
            if readingOrigin == kind, sourceIsCurrent?() == true, reading != nil {
                return
            }
        }
        let page = progress.current
        switch tool {
        case .ink:
            if !inspectInk(from: page, applyPreview: applyPreview) {
                showAnalysisMessage("当前涂鸦没有可应用的结论")
            }
        case .chain:
            let assembled = page.chains.assembly()
            guard let path = assembled.path else {
                showAnalysisMessage(assembled.message)
                return
            }
            requestHint(
                from: .chain, board: page.board,
                sourceIsCurrent: { [weak self] in
                    self?.progress.current.chains == page.chains
                }
            ) { _ in
                try Self.authoredChainAnswer(path, board: page.board)
            }
        case .boxes:
            openBoxHint(
                cells: page.boxes.footprint.sorted(),
                sourceIsCurrent: { [weak self] in
                    self?.progress.current.boxes == page.boxes
                })
        default:
            openHint()
        }
    }
    private static func authoredChainAnswer(_ path: ChainToolPath, board: NativeBoardSnapshot) throws -> NativeHintAnswer {
        let result = try path.analyze(board: board)
        if let step = result.step, result.status == .proven || result.status == .assumed {
            return .step(step, stages: result.stages)
        }
        return result.status == .noConclusion ? .noMatch : .notice(result.message)
    }

    private func inspectInk(from page: BoardPage, applyPreview: Bool) -> Bool {
        if applyPreview, let displayed = reading, displayed.step.technique == .userInk {
            return applyHint(id: displayed.id)
        }
        let group = color
        guard let answer = InkReasoning.proposal(in: page.ink, group: group, board: page.board, unique: inkUnique(page)) else {
            if applyPreview, let displayed = reading, displayed.isFinal { return applyHint(id: displayed.id) }
            return false
        }
        if let step = answer.step, let stage = answer.stage {
            return reviewHint(step, source: page.board, stages: [stage], sourceIsCurrent: { [weak self] in
                guard let self else { return false }
                return self.tool == .ink && self.color == group && self.progress.current.ink == page.ink
            })
        }
        return commitInkAnswer(answer, from: page)
    }

    private func commitInkAnswer(_ answer: InkReasoning.Proposal, from page: BoardPage) -> Bool {
        let adopting = answer.step == nil
        let text = answer.stage?.text ?? ""
        do {
            let picture = frame
            var input = try NativeReplayFrame.capture(picture, kind: adopting ? "doodle-or-input" : "doodle-conclusion-input",
                                                     label: "涂鸦推理", text: text, freeze: true)
            input.phase = "input"
            input.branchPage = page
            var applied = picture
            applied.page.board = answer.board
            if adopting { applied.page.ink = answer.ink }
            applied.showHistoricalRemovals = true
            appliedPreview = (try BoardPainter.png(applied), text)
            proofFrames = [input]
            actionLabel = "应用涂鸦推理"
        } catch { problem = error.localizedDescription; return false }
        progress.current.ink = answer.ink
        if adopting {
            commitAnnotation(page)
        } else {
            progress.boardUndo.append(page.board)
            progress.boardRedo.removeAll()
            progress.current.board = answer.board
            register(page)
            var removals = Array(repeating: UInt16(0), count: 81)
            for atom in answer.step?.inkConclusions?.falses ?? [] {
                removals[atom / 10] |= NativeBoardSnapshot.bit(UInt8(atom % 10))
            }
            boardDidChange(explicitRemovals: removals)
        }
        showOperationMessage(adopting ? "已采纳涂鸦推理" : "已应用涂鸦结论")
        return true
    }

    func annotationWheel(_ delta: Double, now: Int, command: Bool) -> Bool {
        if wheel(delta, now: now) { return true }
        guard tool != .play, frozen == nil, delta.isFinite, delta != 0 else { return false }
        if !previewKeys.isEmpty { return true }
        if active?.erases == true && (tool == .ink || tool == .color) {
            objectWillChange.send()
            radius = min(0.2, max(0.006, radius + CGFloat(delta) * 0.005))
            if let d = drag, let end = d.points.last, let geometry = lastGeometry { move(end, geometry: geometry) }
            return true
        }
        if command && tool != .ink { return false }
        return stepAnnotationWheel(delta, now: now, command: command)
    }

    func statusPaletteWheel(_ delta: Double, at now: Int) -> Bool {
        guard canEdit, frozen == nil, tool != .play, active == nil, previewKeys.isEmpty,
              !hint.isKeyHeld, delta.isFinite, delta != 0 else { return false }
        return stepAnnotationWheel(delta, now: now, command: false)
    }

    private func stepAnnotationWheel(_ delta: Double, now: Int, command: Bool) -> Bool {
        if wheelTime.map({ now - $0 >= 350 }) != false {
            wheelConsumed = false
            wheelAmount = 0
        }
        wheelTime = now
        if !wheelConsumed {
            if delta * wheelAmount < 0 { wheelAmount = 0 }
            wheelAmount += delta
            if abs(wheelAmount) + 1e-9 >= 1 {
                wheelConsumed = true
                let change = wheelAmount > 0 ? 1 : -1
                if command {
                    chooseWidth(inkWidth + change)
                } else {
                    chooseColor((color + change + 6) % 6)
                }
            }
        }
        return true
    }

    func toggleFreeze() {
        objectWillChange.send()
        finishPointer()
        autosave()
        if frozen == nil && (hintRequestPending || transcription != nil) { closeHint() }
        if frozen == nil { closeTechniqueChooser() }
        if frozen == nil {
            let captured = frame
            do {
                var image = try NativeReplayFrame.capture(captured, kind: "snapshot", label: "冻结画面", text: reading?.current.text ?? "", freeze: true)
                image.branchPage = progress.current
                if recorder.capture([image], nowNanos: Self.nanos, wallMillis: Self.wall) { dirty = true; autosave() }
                frozen = captured
            } catch { problem = error.localizedDescription }
        } else { frozen = nil }
        resetKeys()
        chainSession.reset()
    }
}

// Key commands that act on a live board. Text editors and replay controls keep their own responder chain.
extension NativeBoardModel {
    func navigate(_ code: UInt16, command: Bool, shift: Bool) {
        guard frozen == nil, canEdit else { return }
        guard let current = selected else { select(navigationAnchor); return }
        let row = current / 9, col = current % 9
        let vertical = code == 125 || code == 126
        let positive = code == 124 || code == 125 || code == 119
        let stride = vertical ? 9 : 1
        var next = current
        if code == 115 || code == 119 {
            next = command ? (positive ? 72 : 0) + col : row * 9 + (positive ? 8 : 0)
        } else if command && shift, hintDigits.nonzeroBitCount == 1 {
            let order = vertical ? (0..<81).map { ($0 % 9) * 9 + $0 / 9 } : Array(0..<81)
            let index = vertical ? col * 9 + row : current
            let rest = positive ? Array(order.dropFirst(index + 1)) : Array(order.prefix(index).reversed())
            let masks = displayedCandidates
            next = rest.first { progress.current.board.values[$0] == 0 && masks[$0] & hintDigits != 0 } ?? current
        } else {
            var axis = vertical ? row : col
            let limit = positive ? 8 : 0
            if axis == limit {
                next += (positive ? -8 : 8) * stride
            } else {
                repeat {
                    axis += positive ? 1 : -1
                    next += positive ? stride : -stride
                } while command && axis != limit && progress.current.board.values[next] != 0
            }
        }
        if shift && (!command || code == 115 || code == 119) {
            let start = selectionCells.first ?? current
            let rows = min(start / 9, next / 9)...max(start / 9, next / 9)
            let cols = min(start % 9, next % 9)...max(start % 9, next % 9)
            let cells = cols.flatMap { col in rows.map { row in row * 9 + col } }
            selectCells([start] + cells.filter { $0 != start && $0 != next } + (next == start ? [] : [next]))
        } else {
            select(next)
        }
    }

    private var displayedCandidates: [UInt16] {
        mouseOptions.showCandidates ? progress.current.board.candidates : progress.current.board.userCandidates
    }

    func deleteWithKeyboard() {
        guard canEdit, frozen == nil, tool == .play, let cell = selected else { return }
        edit(0)
        if progress.extra?.editingClues == true && mouseOptions.editModeAutoAdvance && cell < 80 {
            selectCells(selectionCells.filter { $0 != cell + 1 } + [cell + 1])
        }
    }

    func enterKeyboardDigit(_ digit: UInt8) {
        guard tool == .play else { return }
        if digit == 0 { deleteWithKeyboard(); return }
        guard selectionCells.count > 1 else { edit(digit); return }
        let cells = selectionCells.filter { !progress.current.board.fixed[$0] }
        guard !cells.isEmpty else { unavailableOperation("给定数不能修改。"); return }
        finishPointer()
        let previous = progress.current.board
        changePlayBoard { board in for cell in cells { board.setValue(digit, at: cell) } }
        if progress.current.board != previous { playDigitEntrySound(digit, cells: cells) }
    }

    func toggleKeyboardCandidate(_ digit: UInt8) {
        guard let cell = selected, (1...9).contains(digit) else { return }
        let cells = selectionCells.isEmpty ? [cell] : selectionCells
        finishPointer()
        togglePlayCandidate(digit, in: cells)
    }

    func enterBoardKey() {
        guard canEdit, frozen == nil, !choosingTechnique else { return }
        if let reading, reading.isFinal, reading.source == progress.current.board, sourceIsCurrent?() == true {
            _ = applyHint(id: reading.id)
            return
        }
        guard tool == .play, let cell = selected else { return }
        let cells = selectionCells.isEmpty ? [cell] : selectionCells
        if cells.count == 1, let single = playSingle(at: cell) {
            edit(single)
            return
        }
        guard hintDigits.nonzeroBitCount == 1 else { return }
        let digit = UInt8(hintDigits.trailingZeroBitCount + 1)
        finishPointer()
        togglePlayCandidate(digit, in: cells, individually: true)
    }

    func keyboardFilter(_ digit: UInt8, additive: Bool, invert: Bool = false) {
        let bit = NativeBoardSnapshot.bit(digit)
        guard hintDigits & bit != 0 || displayedCandidates.contains(where: { $0 & bit != 0 }) else {
            unavailableOperation("当前盘面没有这个候选数。")
            return
        }
        toggleHintDigit(digit, additive: additive)
        if invert { inverseFilter.toggle() }
    }

    var canCycleToolbarFilter: Bool {
        canEdit && frozen == nil && tool == .play && hintDigits.nonzeroBitCount == 1
    }

    func cycleToolbarFilter(_ offset: Int) {
        guard canCycleToolbarFilter, offset % 9 != 0 else { return }
        let index = (hintDigits.trailingZeroBitCount + offset % 9 + 9) % 9
        toggleHintDigit(UInt8(index + 1), additive: false)
    }

    func cycleKeyboardFilter(_ delta: Int) {
        guard hintDigits != 0 else { return }
        let selected = (1...9).filter { hintDigits & NativeBoardSnapshot.bit(UInt8($0)) != 0 }
        guard let start = delta > 0 ? selected.last : selected.first else { return }
        for distance in 1...8 {
            let digit = UInt8((start - 1 + 9 + distance * delta) % 9 + 1)
            if displayedCandidates.contains(where: { $0 & NativeBoardSnapshot.bit(digit) != 0 }) {
                keyboardFilter(digit, additive: false)
                return
            }
        }
    }

    func toggleCountFilter(_ number: Int) {
        guard frozen == nil, canEdit else { return }
        objectWillChange.send()
        let added = countFilters.insert(number).inserted
        if !added { countFilters.remove(number) }
        let name = number == 2 ? "双值格" : "三值格"
        showOperationMessage(added ? "筛选\(name)" : "已取消\(name)筛选")
    }

    func revealCandidates(all: Bool, active: Bool) {
        guard all != revealAllCandidates || active != revealActiveCandidates else { return }
        objectWillChange.send()
        revealAllCandidates = all
        revealActiveCandidates = active
    }

    func hoverReview(_ down: Bool) {
        let visible = down && hasPreviousBoard && canEdit && frozen == nil
        guard reviewHoverHeld != visible else { return }
        objectWillChange.send()
        reviewHoverHeld = visible
    }

    func holdReview(_ down: Bool) {
        guard reviewKeyHeld != down, canEdit, frozen == nil else { return }
        objectWillChange.send()
        reviewKeyHeld = down
    }

    func holdHouse(letter: String?, digit: UInt8? = nil) -> Bool {
        guard frozen == nil, canEdit else { return false }
        if let digit = digit, keyboardHouse != nil {
            objectWillChange.send()
            keyboardHouseNumber = digit
            return true
        }
        if letter == nil && keyboardHouse == nil { return false }
        objectWillChange.send()
        keyboardHouse = letter
        keyboardHouseNumber = nil
        return letter != nil
    }

    func releaseHouse(_ letter: String?, digit: UInt8?) {
        if let digit = digit, digit == keyboardHouseNumber {
            objectWillChange.send()
            keyboardHouseNumber = nil
        } else if let letter = letter, letter == keyboardHouse {
            _ = holdHouse(letter: nil)
        }
    }

    func fillSingles() {
        guard canEdit, frozen == nil else { return }
        finishPointer()
        closeHint()
        let before = progress.current
        var config = solverConfig
        config.rules.removeAll { !["FULL_HOUSE", "NAKED_SINGLE", "HIDDEN_SINGLE"].contains($0.kind) }
        do {
            let path = try NativeLogicalEngine.rate(before.board, config: config, cancelled: { false })
            var page = before
            var frames: [NativeReplayFrame] = []
            for (index, logical) in path.steps.enumerated() {
                guard let next = logical.applying(to: page.board) else { return }
                let step = logical.hint()
                var reading = NativeHintReading(step: step, source: page.board)
                reading.index = reading.stages.count - 1
                let picture = BoardFrame(page: page, selected: nil, reference: nil, visual: visual, general: generalOptions, answerDiagram: reading.answerDiagram)
                var proof = try NativeReplayFrame.capture(picture, kind: "proof", label: step.technique.name,
                    text: reading.stages.map(\.text).joined(separator: "\n"), freeze: true)
                proof.phase = "evidence"
                frames.append(proof)
                page.board = next
                if index != path.steps.count - 1 {
                    var applied = NativeReplayFrame(operationID: 0, wallTimeMillis: 0, elapsedMillis: 0,
                        kind: "apply", label: step.technique.name, page: page)
                    applied.phase = "applied"
                    applied.branchPage = page
                    frames.append(applied)
                }
            }
            guard page.board != before.board else { return }
            objectWillChange.send()
            proofFrames = frames
            actionLabel = "填入全部单数"
            progress.current.board = page.board
            progress.boardUndo.append(before.board)
            progress.boardRedo.removeAll()
            boardDidChange()
        } catch { objectWillChange.send(); problem = error.localizedDescription }
    }
}

extension NativeBoardModel {
    var transcribingChain: Bool { transcription != nil }
    var transcriptionStatus: String? {
        guard transcribingChain, let batch = reading?.step.authoredConclusions else { return nil }
        let group = ["A", "B", "C", "D", "E", "F"][color]
        return transcriptionProblem ?? "转录到涂鸦组 \(group)（\(batch.truths.count) 个真候选，\(batch.falses.count) 个假候选）。请选择或标记本组起点，再确认转录。"
    }

    func cancelChainTranscription() {
        if transcription != nil { closeHint() }
    }

    @discardableResult
    func enterChainTranscription(prepare: Bool) -> Bool {
        if !prepare {
            guard transcription != nil else { return false }
            _ = confirmChainTranscription()
            return true
        }
        guard tool == .chain, canEdit, frozen == nil, !hintRequestPending, let reading = reading,
              reading.isFinal, reading.step.technique == .userChain, reading.step.authoredConclusions != nil,
              readingOrigin == .chain || readingOrigin == .tabChain || knownTechnique == .userChain,
              reading.source == progress.current.board, sourceIsCurrent?() == true,
              !progress.current.chains.paths.isEmpty else { return false }
        let paths = progress.current.chains.paths
        chooseTool(.ink)
        guard self.reading?.id == reading.id, sourceIsCurrent?() == true else { return false }
        transcription = (reading.id, paths)
        sourceIsCurrent = { [weak self] in self?.progress.current.chains.paths == paths }
        return true
    }

    @discardableResult
    private func confirmChainTranscription() -> Bool {
        guard let pending = transcription else { return false }
        guard canEdit, frozen == nil, tool == .ink, let reading = reading, reading.id == pending.reading,
              reading.source == progress.current.board, progress.current.chains.paths == pending.paths,
              sourceIsCurrent?() == true, let batch = reading.step.authoredConclusions else {
            closeHint()
            return false
        }
        objectWillChange.send()
        guard active == nil else { transcriptionProblem = "请先结束当前涂鸦手势。"; return false }
        finishPointer()
        let before = progress.current
        guard let changed = batch.replacing(before.ink, group: color, board: before.board,
                                            width: Self.widths[inkWidth], light: authoredLight) else {
            transcriptionProblem = "请在目标涂鸦组标记同为圈或同为叉的有效起点。"
            return false
        }
        closeHint()
        progress.current.ink = changed
        progress.current.chains.clear(group: nil)
        chainSession.reset()
        enteringStart = false
        gPress = nil
        gLastTap = nil
        commitAnnotation(before)
        return true
    }
}
