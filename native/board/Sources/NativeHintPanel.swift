import AppKit
import SwiftUI

struct NativeBoardReadingArea<Canvas: View>: View {
    @ObservedObject var model: NativeBoardModel
    @ObservedObject var hintWindow: NativeHintWindowController
    let restoreBoardFocus: () -> Void
    var loadingPuzzle = false
    @ViewBuilder let canvas: () -> Canvas
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var measurements = NativeHintTextMeasurements()
    @State private var previous: Target?
    @State private var travel: NativeHintBoardTravel?
    @State private var pathHeight: CGFloat?

    private struct Target: Equatable {
        let showing: Bool
        let tab: NativeTechniqueTab?
        let shift: CGFloat
        let cellWidth: CGFloat
        let windowOffset: CGFloat
        let reduceMotion: Bool
    }

    private struct Sizing: Equatable {
        let size: CGSize
        let readingID: UUID?
        let index: Int?
        let separatedBoxes: Bool
        let tab: NativeTechniqueTab?
        let listHeight: CGFloat?

        var open: Bool { readingID != nil || tab != nil }

        func layout(at size: CGSize, reading: NativeHintReading?, measurements: NativeHintTextMeasurements) -> NativeHintLayout {
            NativeHintLayout(size: size, open: open, separatedBoxes: separatedBoxes) { width, height in
                if let reading {
                    return measurements.height(for: reading, panelWidth: width) <= NativeHintTextMeasurements.capacity(for: height)
                }
                return listHeight.map { $0 <= height } ?? false
            }
        }
    }

    private var hintShowing: Bool {
        !loadingPuzzle && !model.choosingTechnique && model.isHintDrawerAvailable && !model.hintDrawerCollapsed
    }

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let reading = hintShowing ? model.visibleReading : nil
            let separatedBoxes = model.generalOptions.drawMode == 0
            let tab = model.choosingTechnique && !loadingPuzzle ? model.techniqueTab : nil
            let listHeight = tab == .path ? pathHeight : NativeTechniqueChooser.fittingHeight(for: model)
            let sizing = Sizing(size: size, readingID: reading?.id, index: reading?.index, separatedBoxes: separatedBoxes,
                                tab: tab, listHeight: listHeight)
            let layout = sizing.layout(at: size, reading: reading, measurements: measurements)
            let target = Target(showing: sizing.open, tab: tab, shift: layout.boardShift,
                cellWidth: layout.cellWidth, windowOffset: hintWindow.centerOffset, reduceMotion: reduceMotion)
            Group {
                if #available(macOS 12, *) {
                    TimelineView(.animation(paused: travel == nil)) { context in
                        scene(size: size, layout: layout, target: target, reading: reading, time: context.date)
                    }
                } else {
                    LegacyHintTimeline(active: travel != nil) { time in
                        scene(size: size, layout: layout, target: target, reading: reading, time: time)
                    }
                }
            }
            .onAppear { previous = target; updateWindow(sizing) }
            .onChange(of: target) { updateMotion($0, now: Date()) }
            .onChange(of: sizing) { updateWindow($0) }
        }
        .onPreferenceChange(NativeSolutionPathHeight.self) { pathHeight = $0 }
        .onDisappear { hintWindow.clear() }
        .onChange(of: model.hint.isKeyHeld) { held in
            if held { model.hintHover(nil) }
        }
    }

    private func scene(size: CGSize, layout: NativeHintLayout, target: Target,
                       reading: NativeHintReading?, time: Date) -> some View {
        let shift = presentedShift(target, time: time)
        let board = CGRect(origin: CGPoint(x: -shift, y: 0), size: size)
        let overlap = layout.centeredGrid.offsetBy(dx: -shift, dy: 0).intersection(layout.panel).width
        let picture = target.showing || shift != 0 ? model.frame : nil
        let background = picture.map(NativeHintBackdrop.boardBackground)
        return ZStack(alignment: .topLeading) {
            canvas().frame(width: board.width, height: board.height)
                .position(x: board.midX, y: board.midY)
            if target.showing, let picture {
                let visible = layout.exceedsOverlapLimit || overlap <= layout.overlapLimit
                let backdrop = overlap > 0
                    ? NativeHintBackdrop(picture: picture, size: size, card: layout.panel, shift: shift) : nil
                Group {
                    if let reading {
                        let capacity = NativeHintTextMeasurements.capacity(for: layout.panel.height)
                        let intrinsic = measurements.height(for: reading, panelWidth: layout.panel.width)
                        NativeHintPanel(model: model, width: layout.panel.width,
                            bodyHeight: reading.isFinal ? capacity : min(capacity, intrinsic),
                            scrolls: intrinsic > capacity, pointerActive: !model.hint.isKeyHeld,
                            restoreBoardFocus: restoreBoardFocus)
                    } else {
                        NativeTechniqueChooser(model: model, width: layout.panel.width, restoreBoardFocus: restoreBoardFocus)
                    }
                }
                .readingSurface(backdrop: backdrop)
                .frame(width: layout.panel.width, height: layout.panel.height, alignment: .topLeading)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier(reading == nil ? "native-technique-drawer" : "native-hint-drawer")
                .opacity(visible ? 1 : 0)
                .allowsHitTesting(visible)
                .accessibilityHidden(!visible)
                .position(x: layout.panel.midX, y: layout.panel.midY)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .background(Color(background ?? NSColor.windowBackgroundColor))
        .clipped()
    }

    private func updateWindow(_ sizing: Sizing) {
        guard sizing.open else { hintWindow.clear(); return }
        let measurements = measurements
        hintWindow.update(area: sizing.size) { [weak model] size in
            guard let model, !model.reviewing, sizing.separatedBoxes == (model.generalOptions.drawMode == 0) else { return nil }
            if let tab = sizing.tab {
                guard model.choosingTechnique, model.techniqueTab == tab else { return nil }
                return sizing.layout(at: size, reading: nil, measurements: measurements)
            }
            guard !model.choosingTechnique, model.isHintDrawerAvailable, !model.hintDrawerCollapsed,
                  let reading = model.visibleReading, reading.id == sizing.readingID, reading.index == sizing.index else { return nil }
            return sizing.layout(at: size, reading: reading, measurements: measurements)
        }
    }

    private func shouldStartTravel(from old: Target, to new: Target) -> Bool {
        old.showing != new.showing || old.tab != new.tab || (new.showing && old.windowOffset != new.windowOffset)
    }

    private func presentedShift(_ target: Target, time: Date) -> CGFloat {
        guard !target.reduceMotion else { return target.shift }
        if let previous, shouldStartTravel(from: previous, to: target) {
            let start = (travel?.shift(at: time) ?? previous.shift) + target.windowOffset - previous.windowOffset
            if abs(start - target.shift) >= max(24, target.cellWidth / 2) { return start }
        }
        return travel?.shift(at: time) ?? target.shift
    }

    private func updateMotion(_ target: Target, now: Date) {
        let old = previous
        previous = target
        guard let old, !target.reduceMotion else { travel = nil; return }
        let current = (travel?.shift(at: now) ?? old.shift) + target.windowOffset - old.windowOffset
        let next: NativeHintBoardTravel?
        if shouldStartTravel(from: old, to: target) {
            next = .forToggle(from: current, to: target.shift, cellWidth: target.cellWidth,
                              showing: target.showing, reduceMotion: target.reduceMotion, now: now)
        } else if let travel, travel.to != target.shift, travel.end > now {
            next = NativeHintBoardTravel(from: current, to: target.shift, start: now, duration: travel.end.timeIntervalSince(now))
        } else {
            return
        }
        travel = next
        if let next {
            DispatchQueue.main.asyncAfter(deadline: .now() + next.duration) {
                if travel == next { travel = nil }
            }
        }
    }
}

private struct LegacyHintTimeline<Content: View>: View {
    let active: Bool
    let content: (Date) -> Content
    @State private var time = Date()
    @State private var timer: Timer?

    var body: some View {
        content(time)
            .onAppear { run(active) }
            .onChange(of: active, perform: run)
            .onDisappear { run(false) }
    }

    private func run(_ active: Bool) {
        timer?.invalidate()
        timer = nil
        time = Date()
        guard active else { return }
        let next = Timer(timeInterval: 1 / 60, repeats: true) { _ in time = Date() }
        timer = next
        RunLoop.main.add(next, forMode: .common)
    }
}

final class NativeHintTextMeasurements: ObservableObject {
    static let panelPadding: CGFloat = 14
    static let textInset = NSSize(width: 2, height: 3)
    private var identity: (UUID, Int)?
    private var text: NSAttributedString?
    private var heights: [CGFloat: CGFloat] = [:]

    static func capacity(for panelHeight: CGFloat) -> CGFloat { max(38, panelHeight - 156) }

    func height(for reading: NativeHintReading, panelWidth: CGFloat) -> CGFloat {
        if identity?.0 != reading.id || identity?.1 != reading.index {
            identity = (reading.id, reading.index)
            text = HintReadingText.textForMeasurement(reading)
            heights.removeAll(keepingCapacity: true)
        }
        if let height = heights[panelWidth] { return height }
        let storage = NSTextStorage(attributedString: text ?? NSAttributedString(string: ""))
        let layout = NSLayoutManager()
        let width = max(1, panelWidth - 2 * (Self.panelPadding + Self.textInset.width))
        let container = NSTextContainer(containerSize: CGSize(width: width,
                                                             height: CGFloat.greatestFiniteMagnitude))
        storage.addLayoutManager(layout)
        layout.addTextContainer(container)
        layout.ensureLayout(for: container)
        let extraLine = layout.extraLineFragmentTextContainer === container ? layout.extraLineFragmentRect.maxY : 0
        let bottom = max(layout.usedRect(for: container).maxY, extraLine)
        let height = max(28, ceil(bottom) + 2 * Self.textInset.height)
        heights[panelWidth] = height
        return height
    }
}

private extension View {
    func readingSurface(backdrop: NativeHintBackdrop?) -> some View {
        modifier(NativeReadingSurface(backdrop: backdrop))
    }
}

private struct NativeReadingSurface: ViewModifier {
    let backdrop: NativeHintBackdrop?
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var hovered = false
    private let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)

    func body(content: Content) -> some View {
        content.background(readingBackground)
            .contentShape(shape)
            .onHover { hovered = $0 }
            .overlay(shape.strokeBorder(Color(NSColor.separatorColor), lineWidth: 1).allowsHitTesting(false))
            .shadow(color: Color.black.opacity(0.12), radius: 8, x: 0, y: 3)
            // Catch clicks on blank padding behind the controls and selectable text.
            .background(shape.fill(Color.clear).contentShape(shape).onTapGesture { })
    }

    @ViewBuilder private var readingBackground: some View {
        let color = Color(NSColor.windowBackgroundColor)
        if let backdrop, !reduceTransparency {
            let tint = backdrop.tint(darkAppearance: colorScheme == .dark, hovered: hovered)
            GeometryReader { geometry in
                NativeHintBackdropView(backdrop: backdrop)
                    .frame(width: geometry.size.width + 24, height: geometry.size.height + 24)
                    .blur(radius: hovered ? 3.2 : 1.35, opaque: true)
                    .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
                    .overlay(shape.fill(color.opacity(tint)))
                    .clipShape(shape)
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        } else {
            shape.fill(color)
        }
    }

}

struct NativeHintPanel: View {
    @ObservedObject var model: NativeBoardModel
    let width: CGFloat
    let bodyHeight: CGFloat
    let scrolls: Bool
    let pointerActive: Bool
    let restoreBoardFocus: () -> Void
    @State private var disclosedReading: UUID?

    private var techniqueName: String? {
        guard let reading = model.visibleReading else { return nil }
        return model.knownTechnique?.name ?? (reading.isFinal || reading.id == disclosedReading ? reading.step.technique.name : nil)
    }

    var body: some View { contents }

    private var contents: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                if model.canReturnToTechniqueChooser {
                    Button {
                        model.returnToTechniqueChooser()
                    } label: {
                        Image(systemName: "chevron.left").font(.system(size: 12, weight: .semibold))
                            .frame(width: 22, height: 22)
                    }
                    .buttonStyle(WorkbenchControlStyle())
                    .accessibilityLabel("返回技巧列表").help("返回技巧列表")
                    .accessibilityIdentifier("native-hint-return-to-techniques")
                } else {
                    Image(systemName: "lightbulb").font(.headline).foregroundColor(.accentColor)
                        .accessibilityHidden(true)
                }
                Text(techniqueName ?? model.visibleReading?.current.title ?? "提示")
                    .font(.headline).foregroundColor(Color(NSColor.labelColor))
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("native-hint-heading")
                Spacer(minLength: 0)
                if let reading = model.visibleReading {
                    if techniqueName == nil {
                        Button { disclosedReading = reading.id } label: {
                            Image(systemName: "eye").frame(width: 22, height: 22)
                        }.buttonStyle(WorkbenchControlStyle())
                            .accessibilityLabel("显示技巧名").help("显示技巧名")
                            .accessibilityIdentifier("native-hint-reveal-name")
                    }
                    Text("\(reading.index + 1) / \(reading.stages.count)").font(.caption.monospacedDigit())
                        .foregroundColor(.secondary)
                        .accessibilityLabel("第 \(reading.index + 1) 档，共 \(reading.stages.count) 档")
                }
                Button {
                    model.setHintDrawerCollapsed(true)
                    restoreBoardFocus()
                } label: {
                    Image(systemName: "minus").foregroundColor(Color(NSColor.labelColor))
                        .frame(width: 22, height: 22)
                }.buttonStyle(WorkbenchControlStyle())
                    .accessibilityLabel("收起提示").accessibilityIdentifier("native-hint-collapse")
                    .help("暂时收起。点顶部提示按钮返回这一档")
                Button {
                    model.closeHint()
                    restoreBoardFocus()
                } label: {
                    Image(systemName: "xmark").foregroundColor(Color(NSColor.labelColor))
                        .frame(width: 22, height: 22)
                }.buttonStyle(WorkbenchControlStyle())
                    .accessibilityLabel("关闭提示").accessibilityIdentifier("native-hint-close")
                    .help("关闭提示（Esc）")
            }

            if let reading = model.visibleReading {
                if let name = techniqueName {
                    let stage = reading.isFinal ? "完整理由与结果" : (reading.current.title == name ? nil : reading.current.title)
                    let detail = [stage, model.knownTechniqueInstance].compactMap { $0 }
                    if !detail.isEmpty {
                        Text(detail.joined(separator: "　")).font(.subheadline).lineLimit(1)
                    }
                }
                if let status = model.transcriptionStatus { Text(status).font(.callout) }
                NativeHintBody(model: model, reading: reading, pointerActive: pointerActive, scrolls: scrolls,
                    restoreBoardFocus: restoreBoardFocus)
                    .frame(height: bodyHeight)
                Divider()
                HStack(spacing: 8) {
                    Button(action: { model.moveHint(-1) }) {
                        Image(systemName: "chevron.left")
                    }.disabled(model.interruptedReading != nil || reading.index == 0)
                        .accessibilityLabel("上一档").accessibilityIdentifier("native-hint-back").help("上一档")
                    Button(model.interruptedReading == nil ? "下一档" : "复核提示") { model.moveHint(1) }
                        .disabled(model.hintRequestPending || (model.interruptedReading == nil && reading.isFinal))
                        .accessibilityIdentifier("native-hint-next")
                    Spacer(minLength: 0)
                    if !reading.isFinal && model.interruptedReading == nil && !model.transcribingChain {
                        Button("预览答案") {
                            model.moveHint(reading.stages.count - 1 - reading.index)
                            restoreBoardFocus()
                        }.disabled(model.hintRequestPending)
                            .accessibilityIdentifier("native-hint-answer")
                            .help("查看完整依据和待应用的结论")
                    } else {
                        Button(model.transcribingChain ? "确认转录" : "应用此步") {
                            model.applyHint(id: reading.id)
                            if !model.isHintDrawerAvailable { restoreBoardFocus() }
                        }.disabled(model.interruptedReading != nil)
                            .accessibilityIdentifier("native-hint-apply")
                    }
                }
            }
        }
        .padding(.horizontal, NativeHintTextMeasurements.panelPadding)
        .padding(.vertical, 14)
        .frame(width: width, alignment: .leading)
    }

}

struct NativeHintBackdrop {
    let picture: BoardFrame
    let size: CGSize
    let card: CGRect
    let shift: CGFloat

    static func boardBackground(_ picture: BoardFrame) -> NSColor {
        NSColor(cgColor: picture.visual.rendered(picture.colorMode).color("defaultCellColor")) ?? .windowBackgroundColor
    }

    func tint(darkAppearance: Bool, hovered: Bool) -> Double {
        let background = Self.boardBackground(picture).usingColorSpace(.sRGB)
        let brightness = background.map { 0.2126 * $0.redComponent + 0.7152 * $0.greenComponent + 0.0722 * $0.blueComponent }
        guard let brightness, (brightness < 0.5) == darkAppearance else {
            return hovered ? 0.76 : darkAppearance ? 0.65 : 0.54
        }
        return hovered ? 0.62 : 0.20
    }
}

private struct NativeHintBackdropView: NSViewRepresentable {
    let backdrop: NativeHintBackdrop

    final class Surface: NSView {
        var backdrop: NativeHintBackdrop?
        override var isFlipped: Bool { true }
        override var isOpaque: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func draw(_ dirtyRect: NSRect) {
            guard let context = NSGraphicsContext.current?.cgContext, let backdrop else { return }
            context.setFillColor(backdrop.picture.visual.rendered(backdrop.picture.colorMode).color("defaultCellColor"))
            context.fill(bounds)
            context.translateBy(x: 12 - backdrop.shift - backdrop.card.minX, y: 12 - backdrop.card.minY)
            BoardPainter.draw(backdrop.picture, drag: nil, in: context,
                              bounds: CGRect(origin: .zero, size: backdrop.size), showsCoordinates: true)
        }
    }

    func makeNSView(context: Context) -> Surface { Surface() }
    func updateNSView(_ view: Surface, context: Context) {
        view.backdrop = backdrop
        view.needsDisplay = true
    }
}

struct NativeHintBody: NSViewRepresentable {
    let model: NativeBoardModel
    let reading: NativeHintReading
    let pointerActive: Bool
    var scrolls = true
    let restoreBoardFocus: () -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = scrolls
        scroll.autohidesScrollers = true
        let view = HintReadingText(frame: scroll.contentView.bounds)
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = false
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        view.textContainerInset = NativeHintTextMeasurements.textInset
        view.setAccessibilityIdentifier("native-hint-body")
        view.setAccessibilityLabel("提示正文")
        scroll.documentView = view
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? HintReadingText else { return }
        if scroll.hasVerticalScroller != scrolls { scroll.hasVerticalScroller = scrolls }
        view.pointerActive = pointerActive
        view.restoreBoardFocus = restoreBoardFocus
        view.show(reading, model: model)
    }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: ()) {
        guard let text = scroll.documentView as? HintReadingText, scroll.window?.firstResponder === text
        else { return }
        text.restoreBoardFocus?()
    }
}

final class HintReadingText: NSTextView {
    var restoreBoardFocus: (() -> Void)?
    var pointerActive = true
    private weak var model: NativeBoardModel?
    private var readingID: UUID?
    private var stage = -1
    private var links: [(NSRange, Int)] = []
    private var earlierStages: [(NSRange, Int)] = []
    private var definitionBlocks: [(range: NSRange, earlier: Bool)] = []
    private var tracking: NSTrackingArea?
    private var middleDown = false
    private var keyMonitor: Any?
    private var resignObserver: NSObjectProtocol?
    private var ownedKeys = Set<UInt16>()
    private var boxHeld = false

    fileprivate static func attributedBody(_ stage: NativeHintStage, earlier: Bool = false,
                                           showDefinition: Bool = true) -> NSMutableAttributedString {
        let body = NSMutableAttributedString(string: stage.text, attributes: [
            .font: NSFont.systemFont(ofSize: NSFont.systemFontSize),
            .foregroundColor: earlier ? NSColor.secondaryLabelColor : NSColor.labelColor
        ])
        guard let definition = stage.definition else { return body }
        guard showDefinition else {
            body.deleteCharacters(in: definition.sectionRange)
            return body
        }
        let style = NSMutableParagraphStyle()
        style.firstLineHeadIndent = 25
        style.headIndent = 25
        style.tailIndent = -8
        body.addAttribute(.paragraphStyle, value: style, range: definition.textRange)
        return body
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stopMonitoring()
        guard let host = window else { return }
        resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification,
                    object: host, queue: .main) { [weak self] _ in
            self?.resetKeys()
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            guard let self = self, let window = self.window, event.window === window, window.isKeyWindow else { return event }
            let point = self.convert(window.mouseLocationOutsideOfEventStream, from: nil)
            let editor = window.firstResponder as? NSTextView
            let active = self.visibleRect.contains(point) && !self.isHiddenOrHasHiddenAncestor
                && (editor == nil || editor === self) && self.model?.frozen == nil
            return self.handleAnnotationKey(event, point: point, active: active) ? nil : event
        }
    }

    private func resetKeys() {
        ownedKeys.removeAll()
        boxHeld = false
        middleDown = false
    }

    private func stopMonitoring() {
        if let monitor = keyMonitor { NSEvent.removeMonitor(monitor); keyMonitor = nil }
        if let observer = resignObserver { NotificationCenter.default.removeObserver(observer); resignObserver = nil }
        resetKeys()
    }

    deinit { stopMonitoring() }

    func handleAnnotationKey(_ event: NSEvent, point: NSPoint, active: Bool) -> Bool {
        let code = event.keyCode
        let letter = event.charactersIgnoringModifiers?.lowercased()
        if event.type == .keyUp {
            guard ownedKeys.remove(code) != nil else { return false }
            if letter == "s" { boxHeld = false }
            return true
        }
        guard event.type == .keyDown, event.modifierFlags.intersection([.command,.shift,.control]).isEmpty else { return false }
        if event.isARepeat { return ownedKeys.contains(code) }
        guard active, pointerActive, let id = readingID else { return false }
        if letter == "s" { boxHeld = true; ownedKeys.insert(code); return true }
        guard let letter = letter, let group = ["a","b","c","d"].firstIndex(of: letter),
              model?.annotateHint(id: id, stage: stage, reference: reference(at: point),
                whole: middleDown || event.modifierFlags.contains(.option), group: group, box: boxHeld) == true
            else { return false }
        ownedKeys.insert(code)
        return true
    }

    func show(_ reading: NativeHintReading, model: NativeBoardModel) {
        self.model = model
        guard reading.id != readingID || stage != reading.index else { return }
        readingID = reading.id
        stage = reading.index
        let content = Self.content(reading)
        definitionBlocks = content.definitions
        links = content.links
        earlierStages = content.earlierStages
        textStorage?.setAttributedString(content.text)
        needsDisplay = true
        scrollRangeToVisible(NSRange(location: 0, length: 0))
    }

    private static func content(_ reading: NativeHintReading) -> (
        text: NSAttributedString, definitions: [(range: NSRange, earlier: Bool)],
        links: [(NSRange, Int)], earlierStages: [(NSRange, Int)]
    ) {
        let attributed = attributedBody(reading.current)
        var definitions: [(range: NSRange, earlier: Bool)] = []
        var shownTerms = Set<String>()
        if let definition = reading.current.definition {
            shownTerms.insert(definition.term)
            definitions.append((definition.textRange, false))
        }
        let links = reading.current.textLinks
        for (hit, _) in links {
            attributed.addAttributes([.foregroundColor: NSColor.linkColor,
                                      .underlineStyle: NSUnderlineStyle.single.rawValue], range: hit)
        }
        var earlierStages: [(NSRange, Int)] = []
        if reading.isFinal {
            for index in reading.stages.indices.dropLast().reversed() {
                let previous = reading.stages[index]
                attributed.append(NSAttributedString(string: "\n\n"))
                let title = "第 \(index + 1) 档　" + previous.title
                earlierStages.append((NSRange(location: attributed.length, length: (title as NSString).length), index))
                attributed.append(NSAttributedString(string: title, attributes: [
                    .font: NSFont.boldSystemFont(ofSize: NSFont.smallSystemFontSize), .foregroundColor: NSColor.linkColor,
                    .underlineStyle: NSUnderlineStyle.single.rawValue
                ]))
                attributed.append(NSAttributedString(string: "\n"))
                let showDefinition = previous.definition.map { shownTerms.insert($0.term).inserted } ?? true
                if showDefinition, let range = previous.definition?.textRange {
                    definitions.append((NSRange(location: attributed.length + range.location, length: range.length), true))
                }
                attributed.append(attributedBody(previous, earlier: true, showDefinition: showDefinition))
            }
        }
        return (attributed, definitions, links, earlierStages)
    }

    static func textForMeasurement(_ reading: NativeHintReading) -> NSAttributedString {
        content(reading).text
    }

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard !definitionBlocks.isEmpty, let layout = layoutManager, let container = textContainer else { return }
        let origin = textContainerOrigin
        let left = origin.x + container.lineFragmentPadding
        let width = bounds.width - 2 * left
        guard width > 25 else { return }
        let accent = NSColor.controlAccentColor
        let symbol = NSImage(systemSymbolName: "lightbulb", accessibilityDescription: nil)
        let size = NSImage.SymbolConfiguration(pointSize: 10, weight: .medium)
        let bulb: NSImage?
        if #available(macOS 12.0, *) {
            bulb = symbol?.withSymbolConfiguration(size.applying(.init(paletteColors: [accent])))
        } else {
            bulb = symbol?.withSymbolConfiguration(size)
        }
        for definition in definitionBlocks {
            let glyphs = layout.glyphRange(forCharacterRange: definition.range, actualCharacterRange: nil)
            guard glyphs.length > 0 else { continue }
            let first = layout.lineFragmentRect(forGlyphAt: glyphs.location, effectiveRange: nil)
            let last = layout.lineFragmentRect(forGlyphAt: NSMaxRange(glyphs) - 1, effectiveRange: nil)
            let box = NSRect(x: left, y: origin.y + first.minY - 3,
                             width: width, height: last.maxY - first.minY + 6)
            guard box.intersects(rect) else { continue }
            accent.withAlphaComponent(definition.earlier ? 0.055 : 0.09).setFill()
            NSBezierPath(roundedRect: box, xRadius: 5, yRadius: 5).fill()
            accent.withAlphaComponent(definition.earlier ? 0.38 : 0.68).setFill()
            let rule = NSRect(x: box.minX, y: box.minY + 3, width: 2, height: box.height - 6)
            NSBezierPath(roundedRect: rule, xRadius: 1, yRadius: 1).fill()
            if let bulb = bulb {
                let icon = NSRect(x: box.minX + 8, y: origin.y + first.midY - bulb.size.height / 2,
                                  width: bulb.size.width, height: bulb.size.height)
                bulb.draw(in: icon, from: .zero, operation: .sourceOver,
                          fraction: definition.earlier ? 0.6 : 1, respectFlipped: true, hints: nil)
            }
        }
    }

    override func updateTrackingAreas() {
        if let old = tracking { removeTrackingArea(old) }
        super.updateTrackingAreas()
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .inVisibleRect, .activeInKeyWindow],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    // NSLayoutManager clamps positions outside a line to its last glyph. Only a
    // glyph's own drawn rectangle may activate the corresponding board reference.
    private func character(at point: NSPoint) -> Int? {
        guard let layout = layoutManager, let container = textContainer else { return nil }
        let local = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        let index = layout.glyphIndex(for: local, in: container)
        guard index < layout.numberOfGlyphs,
              layout.boundingRect(forGlyphRange: NSRange(location: index, length: 1), in: container).contains(local)
        else { return nil }
        return layout.characterIndexForGlyph(at: index)
    }

    func reference(at point: NSPoint) -> Int? {
        guard let character = character(at: point) else { return nil }
        return links.first { NSLocationInRange(character, $0.0) }?.1
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 1, event.modifierFlags.intersection([.command, .shift, .option, .control]).isEmpty,
           let character = character(at: convert(event.locationInWindow, from: nil)),
           let earlier = earlierStages.first(where: { NSLocationInRange(character, $0.0) })?.1,
           let model = model, model.reading?.id == readingID {
            model.moveHint(earlier - stage)
            return
        }
        super.mouseDown(with: event)
    }

    private func hover(_ event: NSEvent) {
        guard pointerActive else { return }
        let p = convert(event.locationInWindow, from: nil)
        guard visibleRect.contains(p) else { model?.hintHover(nil); return }
        let hit = reference(at: p)
        model?.hintHover(hit, whole: hit == nil && (middleDown || event.modifierFlags.contains(.option)))
    }

    override func mouseMoved(with event: NSEvent) { hover(event) }
    override func mouseEntered(with event: NSEvent) { hover(event) }
    override func mouseExited(with event: NSEvent) { middleDown = false; model?.hintHover(nil) }
    override func flagsChanged(with event: NSEvent) { hover(event); super.flagsChanged(with: event) }
    override func otherMouseDown(with event: NSEvent) {
        if event.buttonNumber == 2 { middleDown = true; hover(event) } else { super.otherMouseDown(with: event) }
    }
    override func otherMouseUp(with event: NSEvent) {
        if event.buttonNumber == 2 { middleDown = false; hover(event) } else { super.otherMouseUp(with: event) }
    }
    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { model?.focus(true, now: NativeBoardModel.now) }
        return accepted
    }
    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted { resetKeys(); model?.focus(false, now: NativeBoardModel.now) }
        return accepted
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            if !event.isARepeat {
                model?.escape()
                if model?.isHintDrawerAvailable == false { restoreBoardFocus?() }
            }
            return
        }
        if event.keyCode == 111, event.modifierFlags.intersection([.command,.control,.option,.shift]) == .command {
            if !event.isARepeat { model?.moveHint(1) }
            return
        }
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if event.keyCode == 50, modifiers.isEmpty || modifiers == .shift || modifiers == .option {
            if !event.isARepeat { model?.analyzeHint(fresh: modifiers == .option, previous: modifiers == .shift) }
            return
        }
        if event.keyCode == 48, modifiers.isEmpty {
            if !event.isARepeat { model?.openCurrentReasoning() }
            return
        }
        guard modifiers.isDisjoint(with: [.command, .control, .option]),
              let model = model else { super.keyDown(with: event); return }
        if event.keyCode == 36 || event.keyCode == 76 {
            if !event.isARepeat, !modifiers.contains(.shift), readingID == model.reading?.id {
                if !model.enterChainTranscription(prepare: false) { model.enterBoardKey() }
                if !model.isHintDrawerAvailable { restoreBoardFocus?() }
            }
        }
        else if event.charactersIgnoringModifiers?.lowercased() == "h", !event.modifierFlags.contains(.shift) {
            if !event.isARepeat { model.hintKey(down: true, now: Int(event.timestamp * 1000)) }
        } else { super.keyDown(with: event) }
    }
    override func keyUp(with event: NSEvent) {
        if event.charactersIgnoringModifiers?.lowercased() == "h" {
            model?.hintKey(down: false, now: Int(event.timestamp * 1000))
        } else { super.keyUp(with: event) }
    }
    override func scrollWheel(with event: NSEvent) {
        let delta = -Double(event.scrollingDeltaY) / (event.hasPreciseScrollingDeltas ? 10 : 1)
        if model?.wheel(delta, now: Int(event.timestamp * 1000)) != true { super.scrollWheel(with: event) }
    }
}
