import AppKit
import SwiftUI

struct CandidateBoardView: View {
    @ObservedObject var model: NativeBoardModel
    var boardChanged: ((NativeBoardSnapshot) -> Void)?
    var cancelSolutionCount: (() -> Void)?
    var showOperationToast: Bool
    var loadingPuzzle: Bool
    let saveExport: ((NativeBoardExport) -> Void)?
    let hintWindow: NativeHintWindowController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var boardFocus = HintDrawerFocus()

    init(model: NativeBoardModel, boardChanged: ((NativeBoardSnapshot) -> Void)? = nil,
         cancelSolutionCount: (() -> Void)? = nil, showOperationToast: Bool = true,
         loadingPuzzle: Bool = false, saveExport: ((NativeBoardExport) -> Void)? = nil,
         hintWindow: NativeHintWindowController? = nil) {
        self.model = model
        self.boardChanged = boardChanged
        self.cancelSolutionCount = cancelSolutionCount
        self.showOperationToast = showOperationToast
        self.loadingPuzzle = loadingPuzzle
        self.saveExport = saveExport
        self.hintWindow = hintWindow ?? NativeHintWindowController()
    }

    var body: some View {
        Group {
            if model.reviewing {
                NativeReplayPanel(model: model).id(model.reviewIdentity)
            } else if model.canEdit || loadingPuzzle {
                boardBody
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle").accessibilityHidden(true)
                    Text("无法打开原生进度").font(.headline)
                    if let problem = model.problem { Text(problem).multilineTextAlignment(.center) }
                    Button("重试", action: model.retry)
                }.padding().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .overlay(Group {
            if showOperationToast, (model.reviewing || !model.canEdit), let message = model.operationMessage {
                NativeOperationToast(message: message, tone: model.operationMessageTone, identifier: model.operationMessageID)
                    .padding(12).allowsHitTesting(false)
            }
        }, alignment: .topTrailing)
        .onAppear { model.didEdit = boardChanged }
        .onChange(of: loadingPuzzle) { busy in
            if !busy, model.canEdit { boardFocus.restore() }
        }
    }

    private var boardBody: some View {
        let status = NativeBoardStatus(model: model)
        return VStack(spacing: 0) {
            NativeBoardInfoBar(model: model, status: status)
                .opacity(model.writable ? 1 : 0)
                .overlay(GeometryReader { geometry in
                    if geometry.size.width >= 720 {
                        operationMessage
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                            .padding(.trailing, 12)
                    }
                }.allowsHitTesting(cancelSolutionCount != nil))
            NativeBoardReadingArea(model: model, hintWindow: hintWindow,
                                   restoreBoardFocus: boardFocus.restore, loadingPuzzle: loadingPuzzle) {
                BoardSurface(model: model, focus: boardFocus, inputSuspended: loadingPuzzle)
                    .opacity(model.writable ? 1 : 0)
                    .overlay(Group {
                        if loadingPuzzle {
                            BlankBoardSurface(style: model.frame)
                                .transition(.opacity)
                                .allowsHitTesting(false).accessibilityHidden(true)
                        }
                    })
                    .animation(reduceMotion ? nil : .timingCurve(0.2, 0, 0, 1, duration: 0.15), value: loadingPuzzle)
            }
            .overlay(GeometryReader { geometry in
                if geometry.size.width < 720 {
                    operationMessage
                        .padding(.horizontal, 12).padding(.bottom, 10)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                }
            }.allowsHitTesting(cancelSolutionCount != nil))
            Divider()
            NativeBoardStatusBar(model: model, status: status, saveExport: saveExport,
                restoreHint: model.isHintDrawerAvailable && model.hintDrawerCollapsed
                    ? { model.setHintDrawerCollapsed(false) } : nil)
                .opacity(model.writable ? 1 : 0)
            if let error = model.problem {
                HStack {
                    Text(error)
                    Spacer()
                    Button("重试", action: model.retry)
                }.padding(8)
            }
        }
    }

    @ViewBuilder private var operationMessage: some View {
        if showOperationToast, let search = model.hintSearchMessage {
            NativeOperationToast(message: search, tone: .neutral, identifier: "native-hint-searching", showsProgress: true)
                .allowsHitTesting(false)
        } else if showOperationToast, let cancel = cancelSolutionCount {
            HStack(spacing: 8) {
                ProgressView().scaleEffect(0.65).frame(width: 14, height: 14)
                Text("正在检查解数…").font(.callout)
                Button("取消", action: cancel).buttonStyle(WorkbenchControlStyle())
            }.padding(.horizontal, 10).padding(.vertical, 4)
                .background(Capsule().fill(Color(NSColor.windowBackgroundColor)))
                .overlay(Capsule().strokeBorder(Color(NSColor.separatorColor)))
        } else if showOperationToast, let message = model.operationMessage,
                  model.frozen == nil || model.operationMessageTone != .neutral {
            NativeOperationToast(message: message, tone: model.operationMessageTone, identifier: model.operationMessageID)
        }
    }

}

struct NativeOperationToast: View {
    @Environment(\.colorScheme) private var colorScheme
    let message: String
    let tone: NativeOperationMessageTone
    let identifier: String
    var cancel: (() -> Void)? = nil
    var showsProgress = false

    private var foreground: Color {
        switch tone {
        case .neutral: return .primary
        case .warning:
            return colorScheme == .dark ? Color(red: 1, green: 0.84, blue: 0.43)
                : Color(red: 0.47, green: 0.32, blue: 0)
        case .failure:
            return colorScheme == .dark ? Color(red: 1, green: 0.59, blue: 0.61)
                : Color(red: 0.65, green: 0.12, blue: 0.18)
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            if showsProgress {
                ProgressView().controlSize(.small)
                    .scaleEffect(0.8).frame(width: 14, height: 14)
                    .accessibilityHidden(true)
            }
            Text(message).font(.callout).foregroundColor(foreground).lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            if let cancel {
                Button("取消", action: cancel).buttonStyle(WorkbenchControlStyle())
            }
        }
            .padding(.horizontal, 14).padding(.vertical, 6)
            .background(Capsule().fill(Color(NSColor.windowBackgroundColor)))
            .overlay(Capsule().strokeBorder(Color(NSColor.separatorColor)))
            .shadow(color: .black.opacity(0.12), radius: 5, x: 0, y: 2)
            .accessibilityIdentifier(identifier)
    }
}

private final class HintDrawerFocus: ObservableObject {
    weak var canvas: BoardCanvas?

    func restore() {
        guard let canvas = canvas, let window = canvas.window, window.attachedSheet == nil,
              !canvas.isHiddenOrHasHiddenAncestor else { return }
        window.makeFirstResponder(canvas)
    }
}

private struct BlankBoardSurface: NSViewRepresentable {
    let style: BoardFrame

    final class Surface: NSView {
        var placeholder: BoardFrame?
        override var isFlipped: Bool { true }

        override func draw(_ dirtyRect: NSRect) {
            guard let context = NSGraphicsContext.current?.cgContext, let placeholder else { return }
            BoardPainter.draw(placeholder, drag: nil, in: context, bounds: bounds, showsCoordinates: true)
        }
    }

    func makeNSView(context: Context) -> Surface { Surface() }

    func updateNSView(_ view: Surface, context: Context) {
        view.placeholder = BoardFrame(page: BoardPage(board: .blank), visual: style.visual,
                                     colorMode: style.colorMode, general: style.general, showCandidates: false)
        view.needsDisplay = true
    }
}

private struct BoardSurface: NSViewRepresentable {
    @ObservedObject var model: NativeBoardModel
    let focus: HintDrawerFocus
    let inputSuspended: Bool
    func makeNSView(context: Context) -> BoardCanvas {
        let canvas = BoardCanvas(model: model)
        focus.canvas = canvas
        canvas.inputSuspended = inputSuspended
        return canvas
    }
    func updateNSView(_ nsView: BoardCanvas, context: Context) {
        nsView.inputSuspended = inputSuspended
        nsView.refresh()
    }
}

private final class BoardCanvas: NSView {
    private let model: NativeBoardModel
    private var pointerFeedback: BoardPointerFeedback?
    private var pointerFeedbackTimer: Timer?
    private var boxAddition: BoxAdditionFeedback?
    private var digitMotion: BoardDigitMotion?
    private var boardMotionTimer: Timer?
    private var cursorTracking: NSTrackingArea?
    private var savedMouseCoalescing: Bool?
    private var holdingHouseKey = false
    private var keyboardHouse: BoardHouse?
    private var heldCoordinate: BoardHouse?
    private var hoveredCoordinate: BoardHouse?
    private var houseWheelRemainder: CGFloat = 0
    private var discardHouseMomentum = false
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { true }
    private var geometry: BoardGeometry {
        BoardGeometry(bounds: bounds, separatedBoxes: model.generalOptions.drawMode == 0, showsCoordinates: true)
    }
    var inputSuspended = false
    private var canPreviewHouse: Bool {
        !inputSuspended && model.canEdit && model.frozen == nil && !model.reviewing && !model.choosingTechnique && window?.attachedSheet == nil
    }
    private var displayFrame: BoardFrame {
        var frame = model.frame
        if canPreviewHouse { frame.housePreview = heldCoordinate ?? keyboardHouse }
        return frame
    }

    init(model: NativeBoardModel) {
        self.model = model
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("数独棋盘")
        setAccessibilityIdentifier("native-board")
        model.didFinishPointerGesture = { [weak self] feedback in self?.showPointerFeedback(feedback) }
        model.didCommitBoardDigits = { [weak self] before, removals in
            self?.showDigitMotion(before: before, explicitRemovals: removals)
        }
        refresh()
    }
    required init?(coder: NSCoder) { nil }

    func refresh() {
        if !canPreviewHouse { clearHousePreview() }
        if !model.trackingInkPointer || model.drag == nil {
            setAccessibilityValue(displayFrame.accessibilityValue + (model.frozen == nil ? "" : "，冻结画面"))
        }
        needsDisplay = true
        syncInkSampling()
        updateBoardCursor()
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        BoardPainter.draw(displayFrame, drag: model.drag, in: ctx, bounds: bounds,
                          showsCoordinates: true, hoveredCoordinate: hoveredCoordinate,
                          boxAddition: visibleBoxAddition, digitMotion: visibleDigitMotion)
    }

    override func updateTrackingAreas() {
        if let tracking = cursorTracking { removeTrackingArea(tracking) }
        let tracking = NSTrackingArea(rect: .zero, options: [.cursorUpdate, .mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect],
                                      owner: self, userInfo: nil)
        addTrackingArea(tracking)
        cursorTracking = tracking
        super.updateTrackingAreas()
    }

    override func cursorUpdate(with event: NSEvent) { updateBoardCursor() }
    override func mouseEntered(with event: NSEvent) { updateBoardCursor() }
    override func mouseMoved(with event: NSEvent) {
        let next = canPreviewHouse ? geometry.coordinate(at: point(event)) : nil
        guard hoveredCoordinate != next else { return }
        hoveredCoordinate = next
        needsDisplay = true
        updateBoardCursor()
    }
    override func mouseExited(with event: NSEvent) {
        hoveredCoordinate = nil
        needsDisplay = true
        clearPointerFeedback()
    }

    private func updateBoardCursor() {
        guard let host = window, host.isKeyWindow,
              bounds.intersection(visibleRect).contains(convert(host.mouseLocationOutsideOfEventStream, from: nil)) else { return }
        if canPreviewHouse, geometry.coordinate(at: convert(host.mouseLocationOutsideOfEventStream, from: nil)) != nil {
            NSCursor.pointingHand.set()
            return
        }
        let annotating = model.frozen == nil && model.tool != .play
        let base: NSCursor = annotating ? .crosshair : .arrow
        guard model.frozen == nil, let cue = model.pointerDragFeedback ?? pointerFeedback else {
            base.set()
            return
        }
        BoardGestureCursor.cursor(for: cue, base: base, annotating: annotating).set()
    }

    private func showPointerFeedback(_ feedback: BoardPointerFeedback) {
        pointerFeedbackTimer?.invalidate()
        pointerFeedback = feedback
        updateBoardCursor()
        pointerFeedbackTimer = Timer.scheduledTimer(withTimeInterval: 0.32, repeats: false) { [weak self] _ in
            self?.clearPointerFeedback()
        }
    }

    private func clearPointerFeedback() {
        pointerFeedbackTimer?.invalidate()
        pointerFeedbackTimer = nil
        pointerFeedback = nil
        updateBoardCursor()
    }

    private var canAnimateBoard: Bool {
        window?.isKeyWindow == true && model.canEdit && model.frozen == nil && !model.reviewing
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    private var visibleBoxAddition: (feedback: BoxAdditionFeedback, opacity: CGFloat)? {
        guard let feedback = boxAddition, canAnimateBoard,
              feedback.cells.isSubset(of: model.progress.current.boxes.groups[feedback.group])
        else { return nil }
        let opacity = feedback.opacity(at: ProcessInfo.processInfo.systemUptime)
        return opacity > 0 ? (feedback, opacity) : nil
    }

    private func showBoxAddition(_ cells: Set<Int>, group: Int) {
        guard !cells.isEmpty, canAnimateBoard else { return }
        boxAddition = BoxAdditionFeedback(cells: cells, group: group, start: ProcessInfo.processInfo.systemUptime)
        trackBoardMotion()
    }

    private var visibleDigitMotion: (edit: BoardDigitMotion, elapsed: TimeInterval)? {
        guard let edit = digitMotion, canAnimateBoard, edit.after == model.progress.current.board else { return nil }
        let elapsed = ProcessInfo.processInfo.systemUptime - edit.start
        return elapsed < BoardDigitMotion.duration ? (edit, elapsed) : nil
    }

    private func showDigitMotion(before: NativeBoardSnapshot, explicitRemovals: [UInt16]) {
        guard canAnimateBoard else { return }
        digitMotion = BoardDigitMotion(before: before, after: model.progress.current.board,
                                      explicitRemovals: explicitRemovals, start: ProcessInfo.processInfo.systemUptime)
        trackBoardMotion()
    }

    private func trackBoardMotion() {
        needsDisplay = true
        guard boardMotionTimer == nil else { return }
        boardMotionTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            if self.visibleBoxAddition == nil && self.visibleDigitMotion == nil { self.clearBoardMotion() }
            else { self.needsDisplay = true }
        }
    }

    private func clearBoardMotion() {
        guard boardMotionTimer != nil else { return }
        boardMotionTimer?.invalidate()
        boardMotionTimer = nil
        boxAddition = nil
        digitMotion = nil
        needsDisplay = true
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if let old = window { NotificationCenter.default.removeObserver(self, name: nil, object: old) }
        clearBoardMotion()
        restoreMouseCoalescing()
        super.viewWillMove(toWindow: newWindow)
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window = window else { return }
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowLostFocus),
            name: NSWindow.didResignKeyNotification, object: window)
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowRegainedFocus),
            name: NSWindow.didBecomeKeyNotification, object: window)
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self = self, let window = window, self.window === window,
                window.firstResponder === window || window.firstResponder === window.contentView || window.firstResponder == nil || self.model.focusOnBoardReturn
            else { return }
            self.model.focusOnBoardReturn = false
            window.makeFirstResponder(self)
        }
    }
    @objc private func windowLostFocus() {
        clearPointerFeedback()
        clearBoardMotion()
        clearHousePreview()
        model.cancelChainTranscription()
        model.focus(false, now: NativeBoardModel.now)
        refresh()
        restoreMouseCoalescing()
    }
    @objc private func windowRegainedFocus() {
        if window?.firstResponder === self { model.focus(true, now: NativeBoardModel.now) }
    }
    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { model.focus(true, now: NativeBoardModel.now) }
        return accepted
    }
    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted {
            clearHousePreview()
            clearBoardMotion()
            model.focus(false, now: NativeBoardModel.now)
            refresh()
            restoreMouseCoalescing()
        }
        return accepted
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    private var pointerArea: CGRect?
    private func pointerGeometry() -> BoardGeometry {
        let area = convert(bounds, to: nil)
        if let previous = pointerArea, previous != area {
            // A press or a double-click candidate belongs to the old grid.
            model.finishPointer()
            needsDisplay = true
        }
        pointerArea = area
        return geometry
    }
    private func point(_ e: NSEvent) -> CGPoint { convert(e.locationInWindow, from: nil) }
    private func time(_ e: NSEvent) -> Int { Int(e.timestamp * 1000) }
    private func mouseModifiers(_ e: NSEvent) -> BoardModifiers {
        var flags: BoardModifiers = []
        if e.modifierFlags.contains(.shift) { flags.insert(.shift) }
        if e.modifierFlags.contains(.control) { flags.insert(.control) }
        if e.modifierFlags.contains(.option) { flags.insert(.option) }
        if e.modifierFlags.contains(.command) { flags.insert(.command) }
        return flags
    }
    private func begin(_ e: NSEvent, _ button: BoardButton) {
        guard !inputSuspended else { return }
        clearPointerFeedback()
        clearBoardMotion()
        window?.makeFirstResponder(self)
        let boardGeometry = pointerGeometry()
        if canPreviewHouse, let coordinate = boardGeometry.coordinate(at: point(e)) {
            if button == .left {
                heldCoordinate = coordinate
                refresh()
            }
            return
        }
        model.press(point(e), button: button, modifiers: mouseModifiers(e), at: time(e), geometry: boardGeometry, pressedButtons: NSEvent.pressedMouseButtons)
        syncInkSampling()
    }
    override func mouseDown(with event: NSEvent) { begin(event, .left) }
    override func rightMouseDown(with event: NSEvent) { begin(event, .right) }
    private func updatePointerDrag(_ event: NSEvent) {
        guard !inputSuspended else { return }
        let geometry = pointerGeometry()
        let starting = model.drag == nil
        model.move(point(event), geometry: geometry)
        if model.trackingInkPointer {
            if model.drag != nil { needsDisplay = true }
            if starting { updateBoardCursor() }
        } else {
            updateBoardCursor()
        }
    }
    private func syncInkSampling() {
        if model.trackingInkPointer, window?.isKeyWindow == true {
            if savedMouseCoalescing == nil {
                savedMouseCoalescing = NSEvent.isMouseCoalescingEnabled
                NSEvent.isMouseCoalescingEnabled = false
            }
        } else {
            restoreMouseCoalescing()
        }
    }
    private func restoreMouseCoalescing() {
        guard let original = savedMouseCoalescing else { return }
        NSEvent.isMouseCoalescingEnabled = original
        savedMouseCoalescing = nil
    }
    override func mouseDragged(with event: NSEvent) {
        if heldCoordinate != nil {
            if let unit = geometry.coordinate(at: point(event)), unit != heldCoordinate {
                heldCoordinate = unit
                refresh()
            }
            return
        }
        updatePointerDrag(event)
    }
    override func rightMouseDragged(with event: NSEvent) { updatePointerDrag(event) }
    override func mouseUp(with event: NSEvent) {
        guard !inputSuspended else { return }
        if heldCoordinate != nil {
            heldCoordinate = nil
            refresh()
            return
        }
        let group = model.color
        let before = model.tool == .boxes ? model.progress.current.boxes.groups[group] : nil
        model.release(point(event), button: .left, at: time(event), geometry: pointerGeometry(), modifiers: mouseModifiers(event))
        if let before {
            showBoxAddition(model.progress.current.boxes.groups[group].subtracting(before), group: group)
        }
        syncInkSampling()
    }
    override func rightMouseUp(with event: NSEvent) {
        guard !inputSuspended else { return }
        let currentGeometry = pointerGeometry()
        let menuAllowed = model.hasPlayPress(button: .right) && !model.mouseOptions.singleClickMode
        model.release(point(event), button: .right, at: time(event), geometry: currentGeometry, modifiers: mouseModifiers(event))
        syncInkSampling()
        guard menuAllowed, let cell = geometry.cell(at: point(event)) else { return }
        let menu = NSMenu()
        let board = model.progress.current.board
        let cells = model.selectionCells
        func add(_ title: String, _ tag: Int) {
            let item = menu.addItem(withTitle: title, action: #selector(contextAction(_:)), keyEquivalent: "")
            item.tag = tag
            item.target = self
        }
        if cells.count == 1 && board.values[cell] != 0 {
            if !board.fixed[cell] { add("清除填数", 0) }
        } else if !cells.isEmpty {
            let masks = cells.map { model.mouseOptions.displayedMask(board, at: $0) }
            let common = masks.reduce(UInt16(511), &)
            let union = masks.reduce(UInt16(0), |)
            for number in 1...9 where common & NativeBoardSnapshot.bit(UInt8(number)) != 0 {
                add("填入 \(number)", number)
            }
            if union.nonzeroBitCount > 1 {
                for number in 1...9 where union & NativeBoardSnapshot.bit(UInt8(number)) != 0 {
                    add("移除候选 \(number)", -number)
                }
                if union.nonzeroBitCount > 2 { add("移除多个候选数…", 10) }
            }
            let colors = NSMenu()
            for (group, title) in AnnotationPalette.names.enumerated() {
                let item = colors.addItem(withTitle: title, action: #selector(contextAction(_:)), keyEquivalent: "")
                item.tag = 20 + group
                item.target = self
            }
            let colorsItem = menu.addItem(withTitle: "格子颜色", action: nil, keyEquivalent: "")
            colorsItem.submenu = colors
        }
        if !menu.items.isEmpty { menu.popUp(positioning: nil, at: point(event), in: self) }
    }

    @objc private func contextAction(_ item: NSMenuItem) {
        if item.tag >= 20 {
            model.togglePlayMenuColor(item.tag - 20)
        } else if item.tag == 10, let window = window {
            let alert = NSAlert()
            alert.messageText = "移除选中格的候选数"
            let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
            input.placeholderString = "输入 1 至 9 的数字"
            alert.accessoryView = input
            alert.addButton(withTitle: "移除")
            alert.addButton(withTitle: "取消")
            alert.window.initialFirstResponder = input
            alert.beginSheetModal(for: window) { [weak self] reply in
                if reply == .alertFirstButtonReturn {
                    let digits = input.stringValue.compactMap(\.wholeNumberValue).filter { (1...9).contains($0) }
                    let mask = digits.reduce(UInt16(0)) { $0 | NativeBoardSnapshot.bit(UInt8($1)) }
                    self?.model.excludePlayCandidates(mask)
                }
            }
        } else {
            model.applyPlayMenuNumber(item.tag)
        }
    }

    @objc func copy(_ sender: Any?) {
        do { try model.copyPuzzle(.pencilMarks) } catch {
            model.showOperationFeedback(model.generalOptions.localized(error.localizedDescription), sound: .failure)
        }
    }
    @objc func paste(_ sender: Any?) {
        NSApp.sendAction(Selector(("pastePuzzle:")), to: NSApp.delegate, from: self)
    }

    @objc func undo(_ sender: Any?) { if !inputSuspended { model.history(redo: false) } }
    @objc func redo(_ sender: Any?) { if !inputSuspended { model.history(redo: true) } }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if window?.firstResponder === self, window?.attachedSheet == nil,
           event.type == .keyDown, event.modifierFlags.contains(.command), boardKey(event) { return true }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if !boardKey(event) { super.keyDown(with: event) }
    }

    private static let keyModifiers: NSEvent.ModifierFlags = [.command, .shift, .control, .option]
    private static let filterKeys: [UInt16: UInt8] = [122:1, 120:2, 99:3, 118:4, 96:5, 97:6, 98:7, 100:8, 101:9]
    private static let toolKeys: [String: BoardTool] = ["m": .play, "p": .ink, "t": .color, "l": .chain, "s": .boxes]
    private static let paletteKeys = ["a": 0, "b": 1, "c": 2, "d": 3]
    private static func houseKind(_ modifiers: NSEvent.ModifierFlags) -> BoardHouse.Kind? {
        switch modifiers {
        case []: return .row
        case .shift: return .column
        case .option: return .box
        default: return nil
        }
    }

    private func clearHousePreview() {
        holdingHouseKey = false
        keyboardHouse = nil
        heldCoordinate = nil
        hoveredCoordinate = nil
        houseWheelRemainder = 0
    }

    private func updateKeyboardHouse(_ modifiers: NSEvent.ModifierFlags) {
        let kind = Self.houseKind(modifiers)
        guard kind != keyboardHouse?.kind else { return }
        keyboardHouse = kind.map { BoardHouse($0, cell: model.selected ?? 40) }
        houseWheelRemainder = 0
        refresh()
    }
    private func character(_ e: NSEvent) -> String {
        if let digits = e.characters, UInt8(digits) != nil { return digits }
        return (e.characters(byApplyingModifiers: []) ?? e.charactersIgnoringModifiers ?? "").lowercased()
    }

    private func boardKey(_ event: NSEvent) -> Bool {
        guard !inputSuspended, !model.reviewing, !model.choosingTechnique, window?.attachedSheet == nil else { return false }
        let m = event.modifierFlags.intersection(Self.keyModifiers)
        let key = character(event)
        let first = !event.isARepeat
        let code = event.keyCode
        if code == 53 {
            if first {
                if holdingHouseKey || heldCoordinate != nil {
                    clearHousePreview()
                    refresh()
                } else { model.escape() }
            }
            return true
        }
        if key == "v", canPreviewHouse, holdingHouseKey || Self.houseKind(m) != nil {
            if first {
                holdingHouseKey = true
                syncBoardModifiers(m)
            }
            return true
        }
        if key == "z" && (m == .command || m == [.command,.shift]) || key == "y" && m == .command {
            if first { model.history(redo: key == "y" || m.contains(.shift)) }
            return true
        }
        if [115,119,123,124,125,126].contains(code), m.isDisjoint(with: [.control,.option]) {
            model.navigate(code, command: m.contains(.command), shift: m.contains(.shift))
            return true
        }
        if code == 48 && m.isEmpty { if first { model.openCurrentReasoning() }; return true }
        if code == 103 && m.isEmpty { if first { model.fillSingles() }; return true }
        if code == 111 {
            if m == .shift { if first { model.openCurrentReasoning() }; return true }
            if m == [.command,.option] { if first { model.openTechniqueChooser() }; return true }
            if m == .option { if first { model.openHint() }; return true }
            if m == .command || m.isEmpty {
                if first { if m.isEmpty { model.openHint() }; model.moveHint(m.isEmpty ? 100 : 1) }
                return true
            }
        }
        if code == 50, m.isEmpty || m == .shift || m == .option {
            if first { model.analyzeHint(fresh: m == .option, previous: m == .shift) }
            return true
        }
        if m == [.option,.shift], ["r","c","b"].contains(key) {
            return model.holdHouse(letter: key)
        }
        if let digit = UInt8(key), digit <= 9 {
            if m == [.option,.shift], digit != 0 { return model.holdHouse(letter: nil, digit: digit) }
            if m == .option || m == [.option,.command] || m == [.option,.shift] {
                if first {
                    if digit > 0 { model.keyboardFilter(digit, additive: m.contains(.command)) }
                    else if !m.contains(.command) { model.toggleCountFilter(m.contains(.shift) ? 3 : 2) }
                }
                return true
            }
            if m == .command && digit > 0 { if first { model.toggleKeyboardCandidate(digit) }; return true }
            guard m.isEmpty || m == .shift else { return false }
            if model.tool == .ink { if first { model.inkNumber(digit, cross: m.contains(.shift)) } }
            else { model.enterKeyboardDigit(digit) }
            return true
        }
        if let digit = Self.filterKeys[code], m.isDisjoint(with: [.option,.control]) {
            if first { model.keyboardFilter(digit, additive: m.contains(.command), invert: m == .shift) }
            return true
        }
        if code == 109, m.isEmpty || m == .shift {
            if first { model.toggleCountFilter(m.contains(.shift) ? 3 : 2) }; return true
        }
        guard m.isEmpty || m == .shift else { return false }
        switch code {
        case 36, 76:
            if !first { return true }
            if model.enterChainTranscription(prepare: m == .shift) { return true }
            if m.isEmpty { model.enterBoardKey(); return true }
            return false
        case 51 where m.isEmpty, 117 where m.isEmpty:
            if model.tool == .chain { if first && code == 51 { model.chainAction("back") } } else { model.deleteWithKeyboard() }
            return true
        default: break
        }
        if key == "t", m == .shift {
            if first { model.chooseTool(model.tool == .play ? .color : .play) }
            return true
        }
        if m.isEmpty, let tool = Self.toolKeys[key] {
            if first { model.toolKey(tool, down: true, now: time(event)) }; return true
        }
        if m.isEmpty, let palette = Self.paletteKeys[key], model.tool != .play {
            if first { model.holdPalette(palette, down: true) }; return true
        }
        if let group = ["a","b","c","d","e"].firstIndex(of: key) {
            if first { model.paletteShortcut(group, shift: m == .shift) }
            return true
        }
        switch key {
        case "x" where m.isEmpty: if first { model.swapPalette() }
        case "h" where m.isEmpty: if first { model.hintKey(down: true, now: time(event)) }
        case "q" where m.isEmpty: if first { model.holdReview(true) }
        case "g" where m.isEmpty: if first { model.startKey(down: true, now: time(event)) }
        case "r": if first { model.clearAnnotations(all: m.isEmpty) }
        case ".", ",":
            if model.tool == .ink && (m == .shift || event.characters == ">" || event.characters == "<") { model.chooseWidth(model.inkWidth + (key == "." ? 1 : -1)) }
            else { model.cycleKeyboardFilter(key == "." ? 1 : -1) }
        case " " where m.isEmpty:
            if first {
                if model.tool == .chain { model.chainAction("next") }
                else if model.tool == .ink { model.setPreview("space", down: true) }
                else if model.hintDigits.nonzeroBitCount == 1 {
                    model.toggleKeyboardCandidate(UInt8(model.hintDigits.trailingZeroBitCount + 1))
                }
            }
        default: return false
        }
        return true
    }
    override func flagsChanged(with event: NSEvent) {
        guard !inputSuspended else { return }
        let mods = event.modifierFlags.intersection(Self.keyModifiers)
        syncBoardModifiers(mods)
        super.flagsChanged(with: event)
    }

    private func syncBoardModifiers(_ mods: NSEvent.ModifierFlags) {
        model.revealCandidates(all: !holdingHouseKey && mods.isSuperset(of: [.shift,.option]),
                               active: !holdingHouseKey && mods.isSuperset(of: [.shift,.command]))
        if holdingHouseKey || mods != [.shift,.option] { _ = model.holdHouse(letter: nil) }
        model.setCommandDown(mods.contains(.command))
        model.setPreview("option", down: !holdingHouseKey && mods.contains(.option))
        if holdingHouseKey { updateKeyboardHouse(mods) }
    }
    override func otherMouseDown(with event: NSEvent) {
        guard !inputSuspended else { return }
        if event.buttonNumber == 2 {
            window?.makeFirstResponder(self)
            model.setPreview("middle", down: true)
        } else {
            super.otherMouseDown(with: event)
        }
    }
    override func otherMouseUp(with event: NSEvent) {
        guard !inputSuspended else { return }
        if event.buttonNumber == 2 { model.setPreview("middle", down: false) } else { super.otherMouseUp(with: event) }
    }
    override func keyUp(with event: NSEvent) {
        guard !inputSuspended else { return }
        let released = character(event)
        if released == "v", holdingHouseKey {
            holdingHouseKey = false
            keyboardHouse = nil
            houseWheelRemainder = 0
            syncBoardModifiers(event.modifierFlags.intersection(Self.keyModifiers))
            refresh()
            return
        }
        model.releaseHouse(released, digit: UInt8(released))
        if released == "q" { model.holdReview(false); return }
        if !released.isEmpty {
            let key = released
            if let tool = Self.toolKeys[key] {
                model.toolKey(tool, down: false, now: time(event))
                return
            }
            if let group = Self.paletteKeys[key] {
                model.holdPalette(group, down: false)
                return
            }
            if key == "g" {
                model.startKey(down: false, now: time(event))
                return
            }
            if key == " " {
                model.setPreview("space", down: false)
                return
            }
        }
        if event.charactersIgnoringModifiers?.lowercased() == "h" {
            model.hintKey(down: false, now: time(event))
        } else {
            super.keyUp(with: event)
        }
    }
    override func scrollWheel(with event: NSEvent) {
        guard !inputSuspended else { return }
        if !event.momentumPhase.isEmpty, discardHouseMomentum || holdingHouseKey { return }
        if event.momentumPhase.isEmpty { discardHouseMomentum = holdingHouseKey || heldCoordinate != nil }
        if holdingHouseKey || heldCoordinate != nil {
            guard let house = keyboardHouse, canPreviewHouse, heldCoordinate == nil else { return }
            if !event.phase.intersection([.began, .ended, .cancelled]).isEmpty { houseWheelRemainder = 0 }
            let horizontal = event.scrollingDeltaX, vertical = event.scrollingDeltaY
            let delta = -(abs(horizontal) > abs(vertical) ? horizontal : vertical)
            guard delta.isFinite, delta != 0 else { return }
            let offset: Int
            if event.hasPreciseScrollingDeltas {
                if delta * houseWheelRemainder < 0 { houseWheelRemainder = 0 }
                let steps = houseWheelRemainder + delta / 10
                offset = Int(min(9, max(-9, steps)))
                houseWheelRemainder = steps.truncatingRemainder(dividingBy: 1)
            } else {
                offset = delta > 0 ? 1 : -1
            }
            if offset != 0 {
                keyboardHouse = house.stepped(by: offset)
                refresh()
            }
            return
        }
        let delta = -Double(event.scrollingDeltaY) / (event.hasPreciseScrollingDeltas ? 10 : 1)
        if !model.annotationWheel(delta, now: time(event), command: event.modifierFlags.contains(.command)) {
            super.scrollWheel(with: event)
        }
    }
}

private enum BoardGestureCursor {
    private struct Key: Hashable {
        let crosshair, secondary, doubled, dragged: Bool
    }

    private static var cache: [Key: NSCursor] = [:]

    static func cursor(for gesture: BoardPointerFeedback, base: NSCursor, annotating: Bool) -> NSCursor {
        let key = Key(crosshair: annotating, secondary: gesture.button == .right,
                      doubled: gesture.isDouble, dragged: gesture.isDrag)
        if let cached = cache[key] { return cached }

        let size = NSSize(width: max(base.image.size.width, base.hotSpot.x + 19), height: max(22, base.image.size.height))
        let image = NSImage(size: size, flipped: true) { _ in
            base.image.draw(in: CGRect(origin: .zero, size: base.image.size), from: .zero,
                            operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            let y = min(base.hotSpot.y + (key.crosshair ? 4 : 1), size.height - 5)
            let x = base.hotSpot.x + (key.crosshair ? 6 : 9)
            let ink = NSColor(srgbRed: 0.10, green: 0.24, blue: 0.42, alpha: 1)
            for index in 0..<(key.doubled ? 2 : 1) {
                let width: CGFloat = key.dragged && index == 0 ? 5 : 3
                let shape = NSBezierPath(roundedRect: CGRect(x: x + CGFloat(index) * 5, y: y, width: width, height: 3),
                                         xRadius: 2, yRadius: 2)
                NSColor.white.setStroke()
                shape.lineWidth = 1.6
                shape.stroke()
                if key.secondary {
                    NSColor.white.setFill()
                    shape.fill()
                    ink.setStroke()
                    shape.lineWidth = 1
                    shape.stroke()
                } else {
                    ink.setFill()
                    shape.fill()
                }
            }
            return true
        }
        let cursor = NSCursor(image: image, hotSpot: base.hotSpot)
        cache[key] = cursor
        return cursor
    }
}
