// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import SwiftUI

struct NativeBoardInfoBar: View {
    @ObservedObject var model: NativeBoardModel
    let status: NativeBoardStatus
    @State private var paletteOpen = false
    @Environment(\.colorScheme) private var colorScheme

    private var positive: Color { colorScheme == .dark ? Color(red: 0.48, green: 0.83, blue: 0.65)
                                                        : Color(red: 0.11, green: 0.41, blue: 0.28) }
    private var negative: Color { colorScheme == .dark ? Color(red: 1, green: 0.48, blue: 0.52)
                                                        : Color(red: 0.69, green: 0.16, blue: 0.22) }

    var body: some View {
        GeometryReader { bounds in
            let wide = bounds.size.width >= 720
            HStack(spacing: wide ? 10 : 6) {
                if model.tool == .play || model.frozen != nil {
                    Text("数字筛选").foregroundColor(.secondary)
                    CandidateDigitFilters(model: model, status: status)
                        .frame(width: 227, height: 28)
                    Divider().frame(height: 14)
                    countButton(2)
                    countButton(3)
                    if status.filtered {
                        Text(status.filterSummary).font(.caption).foregroundColor(.secondary)
                            .lineLimit(1).accessibilityIdentifier("native-digit-filter")
                    }
                } else {
                    Text(model.tool.title).fontWeight(.semibold)
                    if wide || model.tool == .color {
                        BoardStatusPalette(model: model).frame(width: BoardStatusPalette.barWidth, height: 26)
                    } else {
                        Button(action: { paletteOpen.toggle() }) {
                            HStack(spacing: 4) {
                                Circle().fill(Color(model.visual.annotationColor(model.color, light: model.lightPrimary)))
                                    .frame(width: 10, height: 10)
                                Text(AnnotationPalette.names[model.color])
                                Image(systemName: "chevron.down").font(.caption2)
                            }.frame(minHeight: 24)
                        }.buttonStyle(.borderless).accessibilityLabel("标注色组")
                            .accessibilityValue(AnnotationPalette.names[model.color])
                            .accessibilityIdentifier("native-palette-open")
                            .popover(isPresented: $paletteOpen) {
                                BoardStatusPalette(model: model).frame(width: BoardStatusPalette.barWidth, height: 26).padding(8)
                            }
                    }
                    if model.tool != .color {
                        Divider().frame(height: 16)
                        annotationControls
                    }
                }
                Spacer(minLength: 0)
            }.font(.system(size: 12)).controlSize(.small).frame(height: 30)
                .disabled(!model.canEdit || model.frozen != nil)
            .lineLimit(1).padding(.horizontal, wide ? 14 : 10)
            .frame(width: bounds.size.width, height: bounds.size.height, alignment: .leading)
        }.frame(height: 38).background(Color(NSColor.controlBackgroundColor))
            .overlay(Divider(), alignment: .bottom)
    }

    private func countButton(_ count: Int) -> some View {
        CandidateCountFilter(model: model, count: count, selected: status.filterCounts.contains(count))
    }

    @ViewBuilder private var annotationControls: some View {
        switch model.tool {
        case .ink:
            if model.erasingInk {
                Text("橡皮 \(model.eraserPercent)%").font(.caption)
            } else {
                BoardInkWidthControl(model: model).frame(width: 54, height: 26)
            }
            Button(action: model.toggleStart) {
                stateLabel("起点") { Image(systemName: model.enteringStart ? "scope" : "circle.circle") }
            }
                .buttonStyle(WorkbenchControlStyle(selected: model.enteringStart))
                .accessibilityLabel("起点").help("标记起点（G）")
                .accessibilityAddTraits(model.enteringStart ? .isSelected : [])
            Button(action: model.toggleEraser) {
                stateLabel(model.eraserModeTitle) { EraserStrokeGlyph(whole: model.wholeStroke).frame(width: 23, height: 17) }
            }
                .buttonStyle(WorkbenchControlStyle(selected: model.wholeStroke))
                .accessibilityLabel("擦除方式").accessibilityValue(model.eraserModeTitle)
                .accessibilityIdentifier("native-eraser-mode")
                .help(model.wholeStroke ? "整笔擦除。点击切换为局部擦除" : "局部擦除。点击切换为整笔擦除")
                .accessibilityAddTraits(model.wholeStroke ? .isSelected : [])
        case .chain:
            let chains = model.progress.current.chains
            let strong = chains.nextStrong
            Button(action: { model.chainAction("next") }) {
                stateLabel(strong ? "下一条强链" : "下一条弱链") {
                    ChainRelationGlyph(strong: strong).frame(width: 21, height: 10)
                }
            }
            .buttonStyle(WorkbenchControlStyle())
            .accessibilityLabel("下一条链").accessibilityValue(strong ? "强链" : "弱链")
            .accessibilityIdentifier("native-next-chain")
            .help(model.nextChainTitle + "。点击切换")
            Divider().frame(height: 16)
            chainJunctions(chains.junctionCounts(), group: nil)
            chainJunctions(chains.junctionCounts(group: model.color), group: model.color)
            if !model.chainSession.choices.isEmpty {
                Menu("选择链组") {
                    ForEach(model.chainSession.choices, id: \.atoms) { node in
                        Button(node.label) { model.chooseChainNode(node) }
                    }
                }.fixedSize().accessibilityIdentifier("native-chain-choices")
            }
        case .boxes:
            let page = model.progress.current
            let groups = [model.color] + page.boxes.groups.indices.filter { $0 != model.color && !page.boxes.groups[$0].isEmpty }
            ForEach(groups, id: \.self) { group in
                boxStatistics(page.boxes.statistics(group: group, board: page.board), group: group)
            }
        default: EmptyView()
        }
    }
    private func stateLabel<Glyph: View>(_ title: String, @ViewBuilder glyph: () -> Glyph) -> some View {
        return HStack(spacing: 4) {
            glyph()
            Text(verbatim: model.generalOptions.localized(title))
        }.padding(.horizontal, 4).frame(height: 24)
    }

    private func chainJunctions(_ counts: ChainJunctionCounts, group: Int?) -> some View {
        let tint = group.map { Color(model.visual.annotationColor($0)) } ?? .primary
        let scope = group.map { "当前色组（\(AnnotationPalette.names[$0])）" } ?? "全部链"
        return VStack(alignment: .leading, spacing: 0) {
            chainJunctionCount(strong: true, count: counts.strong, tint: tint, scope: scope, group: group,
                               ambiguous: counts.hasAmbiguousNodes)
            chainJunctionCount(strong: false, count: counts.weak, tint: tint, scope: scope, group: group,
                               ambiguous: counts.hasAmbiguousNodes)
        }.fixedSize()
    }

    private func chainJunctionCount(strong: Bool, count: Int, tint: Color, scope: String,
                                    group: Int?, ambiguous: Bool) -> some View {
        let title = scope + (strong ? "双强接点" : "双弱接点")
        return HStack(spacing: 3) {
            ChainRelationGlyph(strong: strong, junction: true).frame(width: 25, height: 8)
                .foregroundColor(tint.opacity(count == 0 ? 0.36 : 1))
            if count > 0 {
                Text(verbatim: String(count)).font(.system(size: 10, weight: .semibold).monospacedDigit())
                    .foregroundColor(count == 1 ? positive : negative)
            }
        }.frame(height: 12)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(String(count))
        .accessibilityIdentifier((group == nil ? "native-chain-double-" : "native-chain-group-double-") + (strong ? "strong" : "weak"))
        .help(title + (ambiguous ? "，只计关系明确的接点" : ""))
    }

    private func boxStatistics(_ stats: (cells: Int, digits: Int), group: Int) -> some View {
        let active = group == model.color
        let scope = AnnotationPalette.names[group] + "选框"
        let description = "\(stats.cells) 个空格，\(stats.digits) 种候选"
        return HStack(spacing: 3) {
            ALSGroupGlyph().stroke(style: StrokeStyle(lineWidth: 1.1, lineCap: .round, lineJoin: .round))
                .frame(width: 13, height: 12).foregroundColor(Color(model.visual.annotationColor(group)))
            Text(verbatim: "\(stats.cells) / \(stats.digits)")
                .font(.system(size: 11, weight: active ? .semibold : .regular).monospacedDigit())
                .foregroundColor(stats.digits <= stats.cells + 1 ? positive : negative)
        }.fixedSize().padding(.horizontal, 3).frame(height: 24)
            .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(active ? 0.07 : 0)))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(scope).accessibilityValue(description)
            .accessibilityIdentifier("native-box-stats-\(group)")
            .help(scope + "，" + description + "。绿字表示候选种数不超过空格数加一。ALS 还要求空格同属一行、列或宫，且候选种数恰好多一。")
    }

}

struct ChainRelationGlyph: Shape {
    var strong: Bool
    var junction = false

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let radius: CGFloat = 1.35
        let ends = [rect.minX + radius, rect.maxX - radius]
        let centers = junction ? [ends[0], rect.midX, ends[1]] : ends
        for x in centers {
            path.addEllipse(in: CGRect(x: x - radius, y: rect.midY - radius, width: 2 * radius, height: 2 * radius))
        }
        var strokes = Path()
        for (left, right) in zip(centers, centers.dropFirst()) {
            let start = left + radius + 1.1, end = right - radius - 1.1
            let middle = (start + end) / 2
            strokes.move(to: CGPoint(x: start, y: rect.midY))
            strokes.addLine(to: CGPoint(x: strong ? end : middle - 1.25, y: rect.midY))
            if !strong {
                strokes.move(to: CGPoint(x: middle + 1.25, y: rect.midY))
                strokes.addLine(to: CGPoint(x: end, y: rect.midY))
            }
        }
        path.addPath(strokes.strokedPath(StrokeStyle(lineWidth: strong ? 1.45 : 1.15, lineCap: .round)))
        return path
    }
}

private struct ALSGroupGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        let left = rect.minX + 1, right = rect.maxX - 1
        let top = rect.minY + 1, bottom = rect.maxY - 1
        return Path { path in
            path.move(to: CGPoint(x: left + 2, y: top))
            path.addLines([CGPoint(x: left, y: top), CGPoint(x: left, y: bottom), CGPoint(x: left + 2, y: bottom)])
            path.move(to: CGPoint(x: right - 2, y: top))
            path.addLines([CGPoint(x: right, y: top), CGPoint(x: right, y: bottom), CGPoint(x: right - 2, y: bottom)])
            for center in [CGPoint(x: rect.midX, y: rect.midY - 2.5), CGPoint(x: rect.midX, y: rect.midY + 2.5)] {
                path.addEllipse(in: CGRect(x: center.x - 0.65, y: center.y - 0.65, width: 1.3, height: 1.3))
            }
        }
    }
}

/// The intact parts of the stroke show what a local pass leaves behind.
struct EraserStrokeGlyph: View {
    var whole: Bool

    var body: some View {
        GeometryReader { proxy in
            let point: (CGFloat, CGFloat) -> CGPoint = { x, y in
                CGPoint(x: proxy.size.width * x, y: proxy.size.height * y)
            }
            let ink = Path { path in
                path.move(to: point(0.08, 0.80))
                path.addCurve(to: point(0.49, 0.67), control1: point(0.22, 0.08), control2: point(0.41, 0.05))
                path.move(to: point(0.83, 0.31))
                path.addQuadCurve(to: point(0.95, 0.17), control: point(0.89, 0.17))
            }
            let eraser = Path { path in
                path.move(to: point(0.54, 0.77))
                path.addLines([point(0.75, 0.38), point(0.92, 0.62), point(0.76, 0.91), point(0.65, 0.91)])
                path.closeSubpath()
                path.move(to: point(0.64, 0.59))
                path.addLine(to: point(0.81, 0.82))
            }
            ZStack {
                ink.stroke(style: StrokeStyle(lineWidth: 1.55, lineCap: .round)).opacity(whole ? 0.30 : 1)
                eraser.stroke(style: StrokeStyle(lineWidth: 1.15, lineCap: .round, lineJoin: .round))
            }
        }.accessibilityHidden(true)
    }
}

struct CandidateDigitFilters: NSViewRepresentable {
    let model: NativeBoardModel
    let status: NativeBoardStatus

    static func isAdditive(_ modifiers: NSEvent.ModifierFlags, sticky: Bool = false) -> Bool {
        sticky || !modifiers.intersection([.command, .control]).isEmpty
    }

    final class Host: NSHostingView<Buttons> {
        private var remainder: CGFloat = 0
        private var lastScroll: TimeInterval?
        private var lastFilter: UInt16?

        override func scrollWheel(with event: NSEvent) {
            let model = rootView.model
            let point = convert(event.locationInWindow, from: nil)
            guard rootView.enabled, model.canCycleToolbarFilter, bounds.intersection(visibleRect).contains(point) else {
                remainder = 0
                lastScroll = nil
                lastFilter = nil
                super.scrollWheel(with: event)
                return
            }
            guard event.momentumPhase.isEmpty else { return }
            let x = event.scrollingDeltaX, y = event.scrollingDeltaY
            let delta = -(abs(x) > abs(y) ? x : y)
            if lastFilter != model.hintDigits || lastScroll.map({ event.timestamp - $0 > 0.25 }) != false
                || !event.phase.intersection([.began, .ended, .cancelled]).isEmpty {
                remainder = 0
            }
            lastScroll = event.timestamp
            guard delta.isFinite, delta != 0 else { return }
            let offset: Int
            if event.hasPreciseScrollingDeltas {
                if delta * remainder < 0 { remainder = 0 }
                let steps = remainder + delta / 10
                offset = Int(min(9, max(-9, steps)))
                remainder = steps.truncatingRemainder(dividingBy: 1)
            } else {
                offset = delta > 0 ? 1 : -1
                remainder = 0
            }
            model.cycleToolbarFilter(offset)
            lastFilter = model.hintDigits
        }
    }

    func makeNSView(context: Context) -> Host {
        let host = Host(rootView: Buttons(model: model, status: status, enabled: context.environment.isEnabled,
                                         dark: context.environment.colorScheme == .dark))
        host.setAccessibilityIdentifier("native-digit-filter-strip")
        return host
    }

    func updateNSView(_ host: Host, context: Context) {
        host.rootView = Buttons(model: model, status: status, enabled: context.environment.isEnabled,
                                dark: context.environment.colorScheme == .dark)
    }

    struct Buttons: View {
        let model: NativeBoardModel
        let status: NativeBoardStatus
        let enabled: Bool
        let dark: Bool

        var body: some View {
            let tint = Color(CandidateFilterColors.accent(mode: dark ? .dark : .light))
            HStack(spacing: 2) {
                ForEach(1...9, id: \.self) { digit in
                    let bit = NativeBoardSnapshot.bit(UInt8(digit))
                    let selected = status.filterDigits & bit != 0
                    let count = status.placed[digit]
                    let description = count == 9 ? "已填满 9 格" : "已填 \(count)/9"
                    let available = !status.showingBoardCandidates || status.availableDigits & bit != 0
                    Button(action: {
                        let flags = NSApp.currentEvent?.modifierFlags ?? NSEvent.modifierFlags
                        model.toggleHintDigit(UInt8(digit), additive: CandidateDigitFilters.isAdditive(flags))
                    }) {
                        Text("\(digit)")
                            .font(.system(size: 13, weight: selected ? .bold : .medium).monospacedDigit())
                            .foregroundColor(selected ? tint : (available ? .primary : .secondary))
                            .strikethrough(count == 9)
                            .frame(width: 23, height: 24)
                            .contentShape(Rectangle())
                    }.buttonStyle(WorkbenchControlStyle(selected: selected, tint: tint))
                        .accessibilityLabel("筛选数字 \(digit)").accessibilityValue(description)
                        .accessibilityAddTraits(selected ? .isSelected : [])
                        .accessibilityIdentifier("native-digit-filter-\(digit)")
                        .help(selected && status.filterDigits.nonzeroBitCount == 1
                              ? "\(digit)　\(description)；滚动切换数字；按住 ⌘ 或 Control 点选多个数字"
                              : "\(digit)　\(description)；按住 ⌘ 或 Control 点选多个数字")
                }
            }.padding(2)
                .background(RoundedRectangle(cornerRadius: 7).fill(Color.secondary.opacity(0.08)))
                .disabled(!enabled)
        }
    }
}

struct CandidateCountFilter: View {
    @ObservedObject var model: NativeBoardModel
    let count: Int
    let selected: Bool
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let tint = Color(CandidateFilterColors.accent(forCount: count, mode: colorScheme == .dark ? .dark : .light))
        let label = count == 2 ? "双值格" : "三值格"
        Button {
            model.toggleCountFilter(count)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "\(count).square").font(.system(size: 13))
                Text(label)
            }.foregroundColor(selected ? tint : .primary)
                .padding(.horizontal, 4).frame(height: 23)
        }
        .buttonStyle(WorkbenchControlStyle(selected: selected, tint: tint))
        .accessibilityLabel(label).help(label)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("native-filter-count-\(count)")
    }
}

struct WorkbenchControlStyle: ButtonStyle {
    var selected = false
    var alignment: Alignment = .center
    var tint: Color = .accentColor

    func makeBody(configuration: Configuration) -> some View {
        StateView(configuration: configuration, selected: selected, alignment: alignment, tint: tint)
    }

    private struct StateView: View {
        let configuration: Configuration
        let selected: Bool
        let alignment: Alignment
        let tint: Color
        @Environment(\.isEnabled) private var enabled
        @Environment(\.isFocused) private var focused
        @State private var hovered = false

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: 5)
            let active = enabled && (configuration.isPressed || hovered)
            configuration.label
                .frame(minWidth: 21, minHeight: 21, alignment: alignment)
                .background(shape.fill(selected ? tint.opacity(active ? 0.26 : 0.16)
                    : Color.primary.opacity(!enabled ? 0 : configuration.isPressed ? 0.15 : hovered ? 0.08 : 0)))
                .overlay(shape.strokeBorder(focused ? Color.accentColor.opacity(0.9) : selected ? tint.opacity(0.5) : .clear, lineWidth: focused ? 1.5 : 1))
                .opacity(enabled ? 1 : 0.42)
                .contentShape(Rectangle())
                .onHover { hovered = $0 }
        }
    }
}


struct BoardInkWidthControl: NSViewRepresentable {
    let model: NativeBoardModel

    final class Host: NSHostingView<Dot> {
        private var lastScroll: TimeInterval?
        private var amount = 0.0

        override func scrollWheel(with event: NSEvent) {
            let flags = event.modifierFlags.intersection([.shift, .command, .option, .control])
            let point = convert(event.locationInWindow, from: nil)
            guard flags.isEmpty, bounds.intersection(visibleRect).contains(point),
                  rootView.model.canEdit, rootView.model.frozen == nil, !rootView.model.erasingInk else {
                super.scrollWheel(with: event)
                return
            }
            adjust(-Double(event.scrollingDeltaY) / (event.hasPreciseScrollingDeltas ? 10 : 1), at: event.timestamp)
        }

        func adjust(_ delta: Double, at time: TimeInterval) {
            guard delta.isFinite, delta != 0 else { return }
            if lastScroll.map({ time - $0 > 0.25 }) != false || delta * amount < 0 { amount = 0 }
            lastScroll = time
            amount += max(-4, min(4, delta))
            let step = Int(amount)
            if step != 0 {
                amount -= Double(step)
                rootView.model.chooseWidth(rootView.model.inkWidth + step)
            }
        }
    }

    func makeNSView(context: Context) -> Host {
        let host = Host(rootView: Dot(model: model))
        host.setAccessibilityIdentifier("native-ink-width-host")
        return host
    }
    func updateNSView(_ host: Host, context: Context) {
        if host.rootView.model !== model { host.rootView = Dot(model: model) }
    }

    struct Dot: View {
        @ObservedObject var model: NativeBoardModel
        private let names = ["细", "中", "粗", "特粗"]
        var body: some View {
            Button {
                model.chooseWidth((model.inkWidth + 1) % names.count)
            } label: {
                HStack(spacing: 4) {
                    Circle().fill(Color.primary)
                        .frame(width: 4 + CGFloat(model.inkWidth) * 2.7, height: 4 + CGFloat(model.inkWidth) * 2.7)
                        .frame(width: 16)
                    Text(names[model.inkWidth]).font(.system(size: 12))
                }.frame(width: 54, height: 26)
            }
            .buttonStyle(WorkbenchControlStyle())
            .accessibilityLabel("笔宽").accessibilityValue(names[model.inkWidth])
            .accessibilityIdentifier("native-ink-width")
            .help("笔宽：\(names[model.inkWidth])。点击或滚动切换")
        }
    }
}
