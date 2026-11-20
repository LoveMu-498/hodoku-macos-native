import AppKit
import SwiftUI

struct NativeTechniqueChooser: View {
    @ObservedObject var model: NativeBoardModel
    let width: CGFloat
    var restoreBoardFocus: () -> Void = {}
    @State private var selected: NativeHintTechnique?
    @StateObject private var focus = TechniqueNavigationFocus()
    @State private var drafts = [NativeHintTechnique: String]()
    @State private var temporaryPreview = false
    @State private var showingHelp = false

    private var contentWidth: CGFloat { max(0, width - 24) }

    // The sidebar keeps its usual width when its list needs scrolling. Allow
    // for the tallest footer, scope label, separators and panel padding.
    static func fittingHeight(for model: NativeBoardModel) -> CGFloat? {
        guard !model.availableTechniqueLookupPending, !model.staleReasoning, !model.techniqueInstances.isEmpty,
              model.generalOptions.useDefaultFontSize else { return nil }
        return CGFloat(model.techniqueInstances.count) * 26 + 142
    }

    private var techniques: [NativeHintTechnique] { model.namedTechniques }
    private var choices: [NativeTechniqueInstance] { selected.map(model.techniqueChoices) ?? [] }
    private var number: String { selected.flatMap { drafts[$0] } ?? choices.first.map { String($0.number) } ?? "" }
    private var instance: NativeTechniqueInstance? {
        guard let n = Int(number) else { return nil }
        return choices.first { $0.number == n }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                HStack(spacing: 2) {
                    tabButton("选择技巧", tab: .techniques)
                    tabButton("当前思路", tab: .reasoning)
                    tabButton("解题路径", tab: .path)
                }
                .padding(2)
                .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.07)))
                .accessibilityElement(children: .contain)
                .accessibilityLabel("提示来源")
                Button(action: close) { Image(systemName: "xmark").frame(width: 21, height: 21) }
                    .buttonStyle(PlainButtonStyle()).accessibilityLabel("关闭技巧列表")
                    .accessibilityIdentifier("native-technique-close").help("关闭技巧列表")
                    .keyboardShortcut(.cancelAction)
            }
            if model.techniqueTab == .path {
                NativeSolutionPath(model: model)
            } else {
                catalogue
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onChange(of: model.techniqueCatalogueID) { _ in
            selected = nil
            drafts = [:]
            showingHelp = false
            selectInitial()
        }
    }

    private func tabButton(_ title: LocalizedStringKey, tab: NativeTechniqueTab) -> some View {
        let selected = model.techniqueTab == tab
        return Button {
            switch tab {
            case .techniques: model.openTechniqueChooser()
            case .reasoning: model.openCurrentReasoning()
            case .path: model.openSolutionPath()
            }
        } label: {
            Text(title).font(.system(size: 12, weight: selected ? .semibold : .regular))
                .lineLimit(1).minimumScaleFactor(0.72)
                .frame(maxWidth: .infinity, minHeight: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(WorkbenchControlStyle(selected: selected))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("native-technique-tab-" + tab.rawValue)
    }

    private var catalogue: some View {
        let catalogueID = model.techniqueCatalogueID
        return VStack(alignment: .leading, spacing: 8) {
            if let scope = model.currentReasoning {
                Text(scope.description).font(.caption).foregroundColor(.secondary)
                    .accessibilityIdentifier("native-technique-scope")
            }
            if model.staleReasoning {
                Text("棋盘或线索已改变。").foregroundColor(.secondary)
                Button("重新查找") {
                    if model.currentReasoning == nil { model.openTechniqueChooser() }
                    else { model.openCurrentReasoning() }
                }
            } else if model.availableTechniqueLookupPending && model.techniqueInstances.isEmpty {
                VStack(spacing: 10) {
                    ProgressView().controlSize(.small).accessibilityHidden(true)
                    Text("正在查找技巧…").font(.callout).foregroundColor(.secondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("native-technique-loading")
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            } else if model.techniqueInstances.isEmpty, let error = model.techniqueLookupError {
                Text(error).fixedSize(horizontal: false, vertical: true)
            } else if techniques.isEmpty {
                Text(model.generalOptions.localized(model.currentReasoning?.source.noMatchMessage ??
                    "当前盘面没有可用技巧。可检查候选数或求解设置。"))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("native-technique-empty")
            } else {
                techniqueList.frame(minHeight: 52, maxHeight: .infinity)
                Divider()
                controls
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(TechniqueKeyArea(focus: focus, selected: moveTechnique, hasInstance: !choices.isEmpty,
                                     move: move, adopt: adopt, cancel: close,
                                     hold: setTemporaryPreview, mark: annotate,
                                     box: boxInstance, defaultHint: { readDefault(full: true) },
                                     ownsInput: {
                                         model.choosingTechnique && model.techniqueTab != .path &&
                                            model.techniqueCatalogueID == catalogueID && !showingHelp
                                     }))
        .onChange(of: selected) { _ in preview() }
        .onChange(of: model.availableTechniqueLookupPending) { pending in if !pending { selectInitial() } }
        .onAppear { selectInitial() }
    }

    private var techniqueList: some View {
        ScrollViewReader { scroller in
            ScrollView {
                LazyVStack(spacing: 1) {
                    ForEach(techniques, id: \.self) { kind in
                        let active = selected == kind
                        let relations = model.techniqueRelations(for: kind)
                        let count = String(model.techniqueInstances[kind]?.count ?? 0)
                        let labels = relations.map(\.label)
                        let badgesInline = relations.isEmpty ||
                            72 + measure(count, size: 11, digits: true) + CGFloat(relations.count) * 34 <= contentWidth
                        let withText = badgesInline && showsRelationText(for: kind.name, count: count, relations: relations)
                        Button {
                            selected = kind
                            preview()
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 5) {
                                    Text(kind.name).font(.system(size: 13)).lineLimit(1)
                                    Spacer(minLength: 2)
                                    if badgesInline { relationBadges(relations, withText: withText) }
                                    Text(count).font(.system(size: 11).monospacedDigit()).foregroundColor(.secondary)
                                        .fixedSize()
                                }
                                if !badgesInline { relationBadges(relations, withText: false) }
                            }
                            .padding(.horizontal, 7).padding(.vertical, 3).frame(minHeight: 25)
                        }
                        .buttonStyle(WorkbenchControlStyle(selected: active, alignment: .leading)).id(kind)
                        .accessibilityLabel(([kind.name] + labels).joined(separator: "，"))
                        .accessibilityValue(count)
                        .accessibilityAddTraits(active ? .isSelected : [])
                        .help(([kind.name] + labels).joined(separator: "\n"))
                        .accessibilityIdentifier("native-technique-kind-" + kind.key)
                        .simultaneousGesture(TapGesture(count: 2).onEnded { if active { adopt() } })
                    }
                }
            }.accessibilityIdentifier("native-technique-list")
                .onChange(of: selected) { if let value = $0 { scroller.scrollTo(value) } }
        }
    }

    private var numberCaption: String {
        model.generalOptions.localized(model.currentReasoning == nil ? "原序号" : "序号")
    }

    private var totalCaption: String { "/ \(choices.first?.total ?? 0)" }

    private var hintCaption: String { model.generalOptions.localized("查看提示") }

    private var controls: some View {
        let arrangement = TechniqueFooterArrangement(
            width: contentWidth,
            numberWidth: measure(numberCaption, size: 11) + 56 + measure(totalCaption, size: 11, digits: true) + 8,
            actionsWidth: measure(hintCaption, size: 12, weight: .semibold) + 16 + 22 + 4)
        return VStack(alignment: .leading, spacing: 4) {
            if arrangement == .wrapped {
                numberControls(arrows: false)
                HStack { Spacer(minLength: 0); actions }
            } else {
                HStack(spacing: 8) {
                    numberControls(arrows: arrangement == .withArrows)
                    actions.frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            if instance == nil {
                let message = model.techniqueLookupError ?? "请输入列表中的序号"
                Text(model.generalOptions.localized(message))
                    .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("native-technique-status")
            }
        }
    }

    private func numberControls(arrows: Bool) -> some View {
        HStack(spacing: 4) {
            Text(numberCaption).font(.system(size: 11)).fixedSize()
            OriginalInstanceNumber(focus: focus, text: number, numbers: choices.map(\.number),
                                   changed: update, move: move, accept: adopt)
                .frame(width: 56, height: 22)
            Text(totalCaption).font(.system(size: 11).monospacedDigit()).foregroundColor(.secondary).fixedSize()
            if arrows {
                moveButton(-1)
                moveButton(1)
            }
        }
        .background(InstanceWheelArea(move: move, enabled: !choices.isEmpty))
    }

    private var actions: some View {
        HStack(spacing: 4) {
            Button(action: adopt) {
                Text(hintCaption).font(.system(size: 12, weight: .semibold))
                    .fixedSize().padding(.horizontal, 8).frame(height: 22)
            }
            .buttonStyle(WorkbenchControlStyle(selected: true))
            .disabled(instance == nil || model.availableTechniqueLookupPending)
            .accessibilityIdentifier("native-technique-view-hint")
            Button { showingHelp.toggle() } label: {
                Image(systemName: "info.circle").font(.system(size: 13)).frame(width: 22, height: 22)
            }
            .buttonStyle(WorkbenchControlStyle(selected: showingHelp))
            .accessibilityLabel("快捷键与进展").help("快捷键与进展")
            .accessibilityIdentifier("native-technique-info")
            .popover(isPresented: $showingHelp, arrowEdge: .bottom) {
                helpContent
            }
        }
    }

    private var helpContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("快捷键").font(.headline)
            VStack(alignment: .leading, spacing: 4) {
                shortcut("⌥", "预览实例")
                shortcut("A–D", "染色")
                shortcut("S", "框选")
                shortcut("H / ↩", "查看提示")
            }
            if let instance {
                Divider()
                ForEach(model.techniqueRelations(for: instance), id: \.kind) { relation in
                    relationBadge(relation, withText: true)
                }
                TechniqueProgressScoreView(step: instance.step, board: model.progress.current.board, config: model.solverConfig)
                    .id(instance.sourceID.uuidString + instance.step.technique.key + String(instance.number))
            }
        }
        .padding(12).frame(width: 222, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("native-technique-info-content")
    }

    private func shortcut(_ key: String, _ action: String) -> some View {
        HStack(spacing: 8) {
            Text(key).font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundColor(.secondary).frame(width: 48, alignment: .leading)
            Text(model.generalOptions.localized(action)).font(.callout)
        }
    }

    @ViewBuilder
    private func relationBadges(_ relations: [NativeTechniqueRelation], withText: Bool) -> some View {
        if !relations.isEmpty {
            HStack(spacing: 5) {
                ForEach(relations, id: \.kind) { relation in
                    relationBadge(relation, withText: withText)
                }
            }
            .fixedSize()
            .accessibilityHidden(true)
        }
    }

    private func relationBadge(_ relation: NativeTechniqueRelation, withText: Bool) -> some View {
        let icon: String
        switch relation.kind {
        case .boxes: icon = "viewfinder"
        case .chain: icon = "link"
        case .digits: icon = "number"
        }
        return HStack(spacing: 3) {
            Image(systemName: icon).font(.system(size: 11, weight: .medium)).frame(width: 12)
            Image(systemName: relation.matching ? "checkmark" : "circle.lefthalf.fill")
                .font(.system(size: 8, weight: .semibold)).frame(width: 9)
            if withText { Text(relation.label).font(.system(size: 11)).fixedSize() }
        }
        .foregroundColor(relation.matching ? .accentColor : .secondary)
        .padding(.horizontal, 4).frame(height: 17)
        .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.055)))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(relation.label)
    }

    private func showsRelationText(for title: String, count: String, relations: [NativeTechniqueRelation]) -> Bool {
        let badges = relations.reduce(CGFloat(0)) { $0 + 35 + measure($1.label, size: 11) }
        return measure(title, size: 13) + measure(count, size: 11, digits: true) + badges + 28 <= contentWidth
    }

    private func measure(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular, digits: Bool = false) -> CGFloat {
        let font = digits ? NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
            : NSFont.systemFont(ofSize: size, weight: weight)
        return ceil((text as NSString).size(withAttributes: [.font: font]).width) + 1
    }

    private func moveButton(_ direction: Int) -> some View {
        let position = choices.firstIndex { $0.number == instance?.number }
        let allowed = position.map { choices.indices.contains($0 + direction) } ?? false
        return Button { move(direction) } label: {
            Image(systemName: direction < 0 ? "chevron.left" : "chevron.right").frame(width: 18, height: 19)
        }.buttonStyle(WorkbenchControlStyle()).disabled(!allowed)
            .accessibilityLabel(direction < 0 ? "上一个实例" : "下一个实例")
            .accessibilityIdentifier(direction < 0 ? "native-technique-previous" : "native-technique-next")
    }

    private func selectInitial() {
        guard model.choosingTechnique, model.techniqueTab != .path, !model.availableTechniqueLookupPending else { return }
        if selected.map(techniques.contains) != true {
            if let restored = model.techniqueSelection,
               model.techniqueChoices(restored.step.technique).contains(where: {
                   $0.sourceID == restored.sourceID && $0.number == restored.number
               }) {
                selected = restored.step.technique
                drafts[restored.step.technique] = String(restored.number)
            } else {
                selected = techniques.first
            }
        }
        preview()
    }

    private func moveTechnique(_ delta: Int) {
        guard !techniques.isEmpty else { return }
        let current = selected.flatMap { techniques.firstIndex(of: $0) } ?? 0
        let target = min(techniques.count - 1, max(0, current + delta))
        selected = techniques[target]
        preview()
    }

    private func setTemporaryPreview(_ held: Bool) {
        guard temporaryPreview != held else { return }
        temporaryPreview = held
        preview()
    }

    private func preview() { model.previewInstance(temporaryPreview ? instance : nil) }

    private func update(_ value: String) {
        guard let kind = selected else { return }
        drafts[kind] = value
        preview()
    }

    private func move(_ offset: Int) {
        let rows = choices
        guard !rows.isEmpty else { return }
        let i = rows.firstIndex { $0.number == instance?.number } ?? 0
        update(String(rows[min(rows.count - 1, max(0, i + offset))].number))
    }

    private func annotate(_ group: Int, _ box: Bool) {
        guard let instance = instance, !model.availableTechniqueLookupPending else { return }
        _ = model.annotateInstance(instance, group: group, box: box)
    }

    private func boxInstance() { annotate(model.techniqueBoxGroup, true) }

    private func readDefault(full: Bool) {
        model.closeTechniqueChooser()
        model.adoptDefaultHint()
        if full { model.moveHint(100) }
        restoreBoardFocus()
    }

    private func adopt() {
        guard let instance = instance, !model.availableTechniqueLookupPending else { return }
        model.adoptTechnique(instance)
        if !model.choosingTechnique { restoreBoardFocus() }
    }
    private func close() { model.closeTechniqueChooser(); restoreBoardFocus() }
}

enum TechniqueFooterArrangement: Equatable {
    case withArrows, inline, wrapped

    init(width: CGFloat, numberWidth: CGFloat, actionsWidth: CGFloat) {
        let needed = numberWidth + 8 + actionsWidth
        if width >= needed + 50 { self = .withArrows }
        else if width >= needed { self = .inline }
        else { self = .wrapped }
    }
}

/// The editable menu accepts a displayed (one-based) instance number. Editing
/// and spinning only change the draft; Return is the explicit adoption action.
private struct OriginalInstanceNumber: NSViewRepresentable {
    var focus: TechniqueNavigationFocus
    var text: String
    var numbers: [Int]
    var changed: (String) -> Void
    var move: (Int) -> Void
    var accept: () -> Void

    final class Coordinator: NSObject, NSComboBoxDelegate {
        var numbers = [Int]()
        var updating = false
        var view: OriginalInstanceNumber
        init(_ view: OriginalInstanceNumber) { self.view = view }

        func controlTextDidChange(_ notification: Notification) {
            guard !updating, let box = notification.object as? NSComboBox else { return }
            view.changed(box.stringValue)
        }
        func comboBoxSelectionDidChange(_ notification: Notification) {
            guard !updating, let box = notification.object as? NSComboBox, box.indexOfSelectedItem >= 0 else { return }
            view.changed(box.objectValueOfSelectedItem as? String ?? "")
        }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.scrollToBeginningOfDocument(_:)), #selector(NSResponder.moveToBeginningOfDocument(_:)):
                textView.setSelectedRange(NSRange(location: 0, length: 0))
            case #selector(NSResponder.scrollToEndOfDocument(_:)), #selector(NSResponder.moveToEndOfDocument(_:)):
                textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
            case #selector(NSResponder.moveUp(_:)): view.move(-1)
            case #selector(NSResponder.moveDown(_:)): view.move(1)
            case #selector(NSResponder.insertNewline(_:)): view.accept()
            default: return false
            }
            return true
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSComboBox {
        let box = NSComboBox()
        box.completes = false
        box.numberOfVisibleItems = 9
        box.setAccessibilityLabel("实例序号")
        box.setAccessibilityIdentifier("native-technique-instance")
        box.delegate = context.coordinator
        focus.number = box
        return box
    }
    func updateNSView(_ box: NSComboBox, context: Context) {
        context.coordinator.view = self
        context.coordinator.updating = true
        defer { context.coordinator.updating = false }
        if context.coordinator.numbers != numbers {
            context.coordinator.numbers = numbers
            box.removeAllItems()
            box.addItems(withObjectValues: numbers.map(String.init))
        }
        if let n = Int(text), let i = numbers.firstIndex(of: n), box.indexOfSelectedItem != i { box.selectItem(at: i) }
        if box.stringValue != text { box.stringValue = text }
        box.isEnabled = !numbers.isEmpty
    }
}

/// The selector owns navigation as soon as it opens, even during AppKit's
/// transition from the main window to the popover. Text editing and Tab keep
/// their native responders.
final class TechniqueNavigationFocus: ObservableObject {
    weak var number: NSComboBox?
    weak var listResponder: NSResponder?

    func route(_ event: NSEvent, in host: NSWindow, hasInstance: Bool,
               selected: (Int) -> Void, move: (Int) -> Void, adopt: () -> Void, cancel: () -> Void) -> Bool {
        guard event.type == .keyDown, let origin = event.window, origin === host || origin === host.parent,
              origin.attachedSheet == nil, event.modifierFlags.intersection([.command,.control,.shift]).isEmpty
        else { return false }
        let responder = host.firstResponder
        if responder is NSButton || (responder as? NSView)?.accessibilityRole() == .button {
            if [36,76].contains(event.keyCode) { return false }
        }
        let editing = number.map { box in
            responder === box || (box.currentEditor().map { $0 === responder } ?? false)
        } ?? false
        switch event.keyCode {
        case 125, 126:
            if editing { move(event.keyCode == 125 ? 1 : -1) } else { selected(event.keyCode == 125 ? 1 : -1) }
        case 124:
            guard !editing, hasInstance, let number = number else { return false }
            listResponder = responder
            host.makeFirstResponder(number)
            number.selectText(nil)
        case 123:
            guard editing else { return false }
            host.makeFirstResponder(listResponder ?? host.contentView)
        case 36, 76: if !event.isARepeat { adopt() }
        case 53: if !event.isARepeat { cancel() }
        default: return false
        }
        return true
    }
}

struct TechniqueKeyArea: NSViewRepresentable {
    let focus: TechniqueNavigationFocus
    let selected: (Int) -> Void
    let hasInstance: Bool
    let move: (Int) -> Void
    let adopt, cancel: () -> Void
    let hold: (Bool) -> Void
    let mark: (Int, Bool) -> Void
    var box: (() -> Void)? = nil
    var defaultHint: (() -> Void)? = nil
    var ownsInput: () -> Bool = { true }

    final class Area: NSView {
        var input: TechniqueKeyArea?
        private var monitor: Any?, resign: NSObjectProtocol?
        private var boxHeld = false, boxChord = false, middleHeld = false, optionHeld = false
        private var owned = Set<UInt16>()
        private var tracking: NSTrackingArea?
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let tracking = tracking { removeTrackingArea(tracking) }
            let area = NSTrackingArea(rect: .zero, options: [.activeInKeyWindow, .inVisibleRect, .mouseEnteredAndExited],
                                      owner: self, userInfo: nil)
            addTrackingArea(area)
            tracking = area
        }
        override func mouseEntered(with event: NSEvent) {
            updateOption(event.modifierFlags.contains(.option))
        }
        private func updateOption(_ held: Bool) {
            guard optionHeld != held else { return }
            optionHeld = held && (window?.firstResponder as? NSText)?.isEditable != true
            input?.hold(optionHeld || middleHeld)
        }
        override var acceptsFirstResponder: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard let host = window else { return }
            DispatchQueue.main.async { [weak self, weak host] in
                guard let self = self, let host = host, self.window === host, !self.isHiddenOrHasHiddenAncestor,
                      self.input?.ownsInput() == true,
                      (host.firstResponder as? NSText)?.isEditable != true else { return }
                host.makeFirstResponder(self)
            }
            resign = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: host, queue: .main) {
                [weak self] _ in self?.release()
            }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged, .otherMouseDown, .otherMouseUp]) {
                [weak self] e in
                guard let self = self, let win = self.window else { return e }
                let inside = self.visibleRect.contains(self.convert(win.mouseLocationOutsideOfEventStream, from: nil))
                return self.handle(e, cursorInside: inside)
            }
        }
        func handle(_ e: NSEvent, cursorInside: Bool) -> NSEvent? {
            guard let host = window, e.window === host, !isHiddenOrHasHiddenAncestor, let x = input else { return e }
            if e.type == .keyUp, owned.remove(e.keyCode) != nil {
                if e.keyCode == 1 {
                    if boxHeld && !boxChord { x.box?() }
                    boxHeld = false
                    boxChord = false
                }
                return nil
            }
            guard x.ownsInput() else { return e }
            let number = x.focus.number
            let responder = host.firstResponder
            let editing = responder === number || (number?.currentEditor().map { $0 === responder } ?? false)
            if e.type == .otherMouseUp && middleHeld {
                middleHeld = false; x.hold(optionHeld)
                return nil
            }
            if e.type == .flagsChanged {
                updateOption(e.modifierFlags.contains(.option) && (cursorInside || responder === self) && !editing)
                return e
            }
            if e.type == .otherMouseDown && e.buttonNumber == 2 && cursorInside && !editing {
                middleHeld = true; x.hold(true)
                return nil
            }
            guard e.type == .keyDown, host.attachedSheet == nil else { return e }
            if owned.contains(e.keyCode) { return nil }
            var inside = editing || responder === self
            if !inside, let view = responder as? NSView, view !== host.contentView, !(view is NSTextView) {
                let rect = convert(view.bounds, from: view)
                inside = !rect.isEmpty && bounds.contains(NSPoint(x: rect.midX, y: rect.midY))
            }
            let modifiers = e.modifierFlags.intersection([.command, .control, .shift, .option])
            guard inside || (cursorInside && (modifiers == .option || middleHeld)) else { return e }
            if !editing, (responder as? NSText)?.isEditable != true, modifiers.isEmpty || modifiers == .option {
                switch e.keyCode {
                case 111 where modifiers.isEmpty && x.defaultHint != nil:
                    if !e.isARepeat { x.defaultHint?() }
                    return nil
                case 4:
                    if !e.isARepeat { x.adopt() }
                    return nil
                case 1 where x.hasInstance:
                    boxHeld = true
                    owned.insert(e.keyCode)
                    return nil
                default:
                    if x.hasInstance, let group = [UInt16(0), 11, 8, 2].firstIndex(of: e.keyCode) {
                        if !e.isARepeat { x.mark(group, boxHeld); boxChord = boxHeld }
                        owned.insert(e.keyCode)
                        return nil
                    }
                }
            }
            return x.focus.route(e, in: host, hasInstance: x.hasInstance, selected: x.selected,
                                 move: x.move, adopt: x.adopt, cancel: x.cancel) ? nil : e
        }
        private func release() {
            owned.removeAll(); boxHeld = false; boxChord = false; optionHeld = false; middleHeld = false
            input?.hold(false)
        }
        private func stop() {
            if let monitor = monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            if let resign = resign { NotificationCenter.default.removeObserver(resign); self.resign = nil }
        }
        deinit { stop() }
    }
    func makeNSView(context: Context) -> Area { Area() }
    func updateNSView(_ view: Area, context: Context) { view.input = self }
}

/// Only the original-number row handles wheel navigation.
struct InstanceWheelArea: NSViewRepresentable {
    var move: (Int) -> Void
    var enabled: Bool
    final class Area: NSView {
        var move: ((Int) -> Void)?
        private var monitor: Any?
        private var fraction: CGFloat = 0
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] e in
                guard let self = self, e.window === self.window else { return e }
                return self.route(e.scrollingDeltaY, precise: e.hasPreciseScrollingDeltas,
                                  at: self.convert(e.locationInWindow, from: nil)) ? nil : e
            }
        }

        func route(_ deltaY: CGFloat, precise: Bool, at location: CGPoint) -> Bool {
            guard let move = move, !isHiddenOrHasHiddenAncestor, bounds.intersection(visibleRect).contains(location) else { return false }
            let delta = -deltaY / (precise ? 10 : 1)
            guard delta.isFinite else { return false }
            if fraction * delta < 0 { fraction = 0 }
            fraction += max(-100, min(100, delta))
            let offset = Int(fraction)
            if offset != 0 {
                fraction -= CGFloat(offset)
                move(offset)
            }
            return true
        }

        private func stop() {
            if let monitor = monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            fraction = 0
        }
        deinit { stop() }
    }
    func makeNSView(context: Context) -> Area {
        let view = Area()
        view.setAccessibilityIdentifier("native-technique-wheel-area")
        return view
    }
    func updateNSView(_ view: Area, context: Context) { view.move = enabled ? move : nil }
}

private struct TechniqueProgressScoreView: View {
    let step: NativeHintStep
    let board: NativeBoardSnapshot
    let config: NativeSolverConfig
    @State private var result: NativeProgressScore?
    @State private var failure: String?
    @State private var job: BlockOperation?

    var body: some View {
        if let result {
            Text("直接单值 \(result.directSingles)　全部单值 \(result.singles)　进展分 \(Int(result.score))")
                .font(.caption).fixedSize(horizontal: false, vertical: true)
        } else {
            HStack {
                Button(job == nil ? (failure == nil ? "评估进展" : "重试评估") : "取消评估") {
                    if job != nil { cancel() } else { calculate() }
                }.controlSize(.small)
                if let failure { Text(failure).font(.caption).foregroundColor(.secondary) }
            }.onDisappear { cancel() }
        }
    }

    private func cancel() { job?.cancel(); job = nil }

    private func calculate() {
        failure = nil
        let operation = BlockOperation()
        job = operation
        operation.addExecutionBlock { [weak operation] in
            guard let operation else { return }
            let outcome = Result { try NativeProgressScore.evaluate(step, on: board, config: config, cancelled: { operation.isCancelled }) }
            DispatchQueue.main.async {
                guard !operation.isCancelled, job === operation else { return }
                job = nil
                switch outcome {
                case .success(let score): result = score
                case .failure(let error): failure = error.localizedDescription
                }
            }
        }
        DispatchQueue.global(qos: .userInitiated).async { operation.start() }
    }
}
