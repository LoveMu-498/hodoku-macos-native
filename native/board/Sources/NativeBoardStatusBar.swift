// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import Combine
import SwiftUI

struct NativeBoardStatusBar: View {
    @ObservedObject var model: NativeBoardModel
    let status: NativeBoardStatus
    let saveExport: ((NativeBoardExport) -> Void)?
    var restoreHint: (() -> Void)? = nil

    @Environment(\.colorScheme) private var colorScheme
    @State private var reviewHovered = false

    private var editable: Bool { model.canEdit && model.frozen == nil }

    var body: some View {
        GeometryReader { bounds in
            let wide = bounds.size.width >= 660
            HStack(spacing: wide ? 8 : 5) {
                Button(action: { model.showingBoardSummary.toggle() }) {
                    HStack(spacing: 5) {
                        Image(systemName: "chart.bar")
                        if let ordinal = model.progress.extra?.difficulty, model.visual.levels.indices.contains(ordinal) {
                            let level = model.visual.levelColors(ordinal, dark: colorScheme == .dark)
                            Text(status.grade ?? NativeBoardAppearance.levelNames[ordinal])
                                .padding(.horizontal, 4).padding(.vertical, 1)
                                .foregroundColor(Color(NativeBoardAppearance.cgColor(level.foreground)))
                                .background(RoundedRectangle(cornerRadius: 3).fill(Color(NativeBoardAppearance.cgColor(level.background))))
                        } else { Text(status.mode) }
                        if wide, let score = status.score { Text("\(score) 分").foregroundColor(.secondary) }
                        if wide, status.grade != nil { Text(status.mode).foregroundColor(.secondary) }
                    }
                }
                .accessibilityLabel("作答状态")
                .accessibilityValue([status.mode, status.grade, status.score.map { "\($0) 分" }].compactMap { $0 }.joined(separator: "，"))
                .help("查看解题摘要")
                .accessibilityIdentifier("native-board-status")
                .accessibilityAddTraits(model.showingBoardSummary ? .isSelected : [])
                .popover(isPresented: $model.showingBoardSummary, arrowEdge: .top) { details }

                Text("\(status.filled)/81").font(.system(size: 12).monospacedDigit()).foregroundColor(.secondary)
                    .accessibilityLabel("已填 \(status.filled) 格，共 81 格").help("已填 \(status.filled) 格")
                if let selection = status.selection {
                    Text(selection).font(.system(size: 12).monospacedDigit()).foregroundColor(.secondary)
                        .fixedSize().accessibilityIdentifier("native-selection-status")
                    if let content = status.selectedContent {
                        Text(content).font(.system(size: 12).monospacedDigit())
                            .lineLimit(1).truncationMode(.tail)
                            .help([content, status.selectionDetail].compactMap { $0 }.joined(separator: "，"))
                            .accessibilityIdentifier("native-selection-content")
                    }
                }
                Spacer(minLength: 2)
                annotationStatus
                BoardElapsedTime(model: model)
                    .layoutPriority(1)
                Button {
                    model.hoverReview(true)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                        if !reviewHovered { model.hoverReview(false) }
                    }
                } label: { icon("clock.arrow.circlepath") }
                    .accessibilityLabel("预览上一步盘面")
                    .accessibilityIdentifier("native-review-previous")
                    .help("悬停或按住 Q 预览上一步盘面")
                    .disabled(!editable || !model.hasPreviousBoard)
                    .onHover { inside in
                        reviewHovered = inside
                        model.hoverReview(inside)
                    }
                    .onDisappear { model.hoverReview(false) }

                Button(action: model.openTechniqueChooser) {
                    Label("技巧", systemImage: "list.bullet").fixedSize().frame(minHeight: 25)
                }
                .accessibilityLabel("选择技巧").accessibilityIdentifier("native-technique-open")
                .help("选择技巧（⌥⌘F12）").disabled(!editable)

                Divider().frame(height: 14)
                Button(action: model.toggleFreeze) { icon(model.frozen == nil ? "pause.circle" : "play.circle.fill") }
                    .accessibilityLabel(model.frozen == nil ? "冻结画面" : "返回棋盘")
                    .accessibilityIdentifier("native-freeze").help(model.frozen == nil ? "冻结当前画面" : "返回棋盘")
                    .disabled(!model.canEdit)
                if let restore = restoreHint {
                    Button(action: restore) { icon("sidebar.right") }.accessibilityLabel("展开提示")
                        .accessibilityIdentifier("native-hint-expand").help("展开提示")
                }
                NativeBoardShareMenu(model: model, save: saveExport)
                    .disabled(!model.canEdit)
            }.lineLimit(1).font(.system(size: 12)).buttonStyle(WorkbenchControlStyle())
                .padding(.horizontal, wide ? 12 : 8).frame(width: bounds.size.width, height: bounds.size.height)
        }.frame(height: 34).background(Color(NSColor.windowBackgroundColor))
            .onDisappear { model.showingBoardSummary = false }
    }

    @ViewBuilder private var annotationStatus: some View {
        if model.tool == .chain {
            let strong = model.progress.current.chains.nextStrong
            HStack(spacing: 4) {
                ChainRelationGlyph(strong: strong).frame(width: 16, height: 10)
                Text(strong ? "强链" : "弱链")
            }.fixedSize().foregroundColor(.secondary)
                .accessibilityElement(children: .ignore).accessibilityLabel(model.nextChainTitle)
                .accessibilityIdentifier("native-chain-mode-status").help(model.nextChainTitle)
        } else if model.tool == .ink {
            HStack(spacing: 4) {
                EraserStrokeGlyph(whole: model.wholeStroke).frame(width: 18, height: 14)
                Text(model.eraserModeTitle)
            }.fixedSize().foregroundColor(.secondary)
                .accessibilityElement(children: .ignore).accessibilityLabel(model.eraserModeTitle)
                .accessibilityIdentifier("native-eraser-mode-status")
        }
    }

    private var details: some View {
        let board = model.frozen?.page.board ?? model.progress.current.board
        let given = board.fixed.filter { $0 }.count
        return VStack(alignment: .leading, spacing: 9) {
            Text("解题摘要").font(.headline)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("native-status-analysis")
            detail("模式", status.mode)
            detail("原题难度", status.grade ?? "未评级")
            if let score = status.score { detail("原题评分", "\(score) 分") }
            Divider()
            detail("给定", "\(given) 格")
            detail("已填", "\(status.filled - given) 格")
            detail("剩余", "\(81 - status.filled) 格")
            detail("普通候选", "\(board.candidates.reduce(0) { $0 + $1.nonzeroBitCount }) 个")
            if let selection = status.selection { detail("选区", selection) }
            if let content = status.selectedContent { Text(content) }
            if let content = status.selectionDetail { Text(content).foregroundColor(.secondary) }
            if status.filtered { Text(status.filterSummary).foregroundColor(.secondary) }
        }.font(.system(size: 12)).padding(14).frame(minWidth: 195)
    }

    private func detail(_ key: String, _ value: String) -> some View {
        HStack {
            Text(key).foregroundColor(.secondary)
            Spacer(minLength: 18)
            Text(value).font(.system(size: 12).monospacedDigit())
        }
    }

    private func icon(_ name: String) -> some View {
        Image(systemName: name).frame(width: 23, height: 25).contentShape(Rectangle())
    }


}

private struct BoardElapsedTime: View {
    let model: NativeBoardModel
    @State private var seconds: Int64 = 0
    @State private var tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        let hours = seconds / 3_600
        let minutes = seconds / 60 % 60
        let remainder = seconds % 60
        let mmss = String(format: "%02lld:%02lld", minutes, remainder)
        let formatted = hours > 0 ? "\(hours):" + mmss : mmss
        HStack(spacing: 4) {
            Image(systemName: "stopwatch")
            Text(formatted).font(.system(size: 12).monospacedDigit())
        }.foregroundColor(.secondary).fixedSize()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("本局用时").accessibilityValue(formatted)
            .accessibilityIdentifier("native-attempt-elapsed")
            .help("本局用时")
            .onAppear(perform: refresh)
            .onReceive(tick) { _ in refresh() }
            .onChange(of: model.recorder?.document.id) { _ in refresh() }
    }

    private func refresh() { seconds = model.elapsedPlaySeconds }
}

/// Scroll events bubble from native controls to their enclosing view. Handling them
/// here limits a palette wheel gesture to its own bounds without a window monitor.
struct BoardStatusPalette: NSViewRepresentable {
    static let barWidth: CGFloat = 255
    var model: NativeBoardModel

    final class Host: NSHostingView<Swatches> {
        override func scrollWheel(with event: NSEvent) {
            let modifiers = event.modifierFlags.intersection([.shift, .command, .option, .control])
            let delta = -Double(event.scrollingDeltaY) / (event.hasPreciseScrollingDeltas ? 10 : 1)
            if !modifiers.isEmpty || !rootView.model.statusPaletteWheel(delta, at: Int(event.timestamp * 1000)) {
                super.scrollWheel(with: event)
            }
        }
    }

    func makeNSView(context: Context) -> Host { Host(rootView: Swatches(model: model)) }
    func updateNSView(_ view: Host, context: Context) {
        if view.rootView.model !== model { view.rootView = Swatches(model: model) }
    }

    struct Swatches: View {
        @ObservedObject var model: NativeBoardModel
        var body: some View {
            HStack(spacing: 1) {
                Button(action: model.swapPalette) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.left.arrow.right").frame(width: 18)
                        Text("主副色").font(.system(size: 12)).fixedSize()
                    }.frame(height: 24)
                }
                    .accessibilityLabel("交换主副色").accessibilityValue(model.lightPrimary ? "浅色为主" : "深色为主")
                    .accessibilityIdentifier("native-palette-swap")
                    .disabled(model.tool != .color && model.tool != .ink)
                    .help("交换主色和副色（X）")
                ForEach(AnnotationPalette.names.indices, id: \.self) { group in
                    let selected = model.color == group
                    let pale = model.lightPrimary && (model.tool == .color || model.tool == .ink)
                    Button(action: { model.chooseColor(group) }) {
                        HStack(spacing: 0) {
                            Color(model.visual.annotationColor(group, light: pale)).frame(width: 10)
                            Color(model.visual.annotationColor(group, light: !pale)).frame(width: 5)
                        }.frame(height: 13).clipShape(RoundedRectangle(cornerRadius: 3))
                        .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.primary.opacity(0.3), lineWidth: 0.5))
                        .padding(3)
                        .frame(width: 24, height: 24).contentShape(Rectangle())
                    }
                    .buttonStyle(WorkbenchControlStyle(selected: selected))
                    .accessibilityLabel("色组 " + AnnotationPalette.names[group])
                    .accessibilityAddTraits(selected ? .isSelected : [])
                    .accessibilityIdentifier("native-palette-\(group)")
                    .help(AnnotationPalette.names[group] + "，滚轮切换色组")
                }
                Menu {
                    Button("清除此工具的批注") { model.clearAnnotations(all: false) }
                    Button("清除全部批注") { model.clearAnnotations(all: true) }
                } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(BorderlessButtonMenuStyle())
                .fixedSize().accessibilityLabel("批注操作").accessibilityIdentifier("native-annotation-actions")
                .help("清理批注")
            }.buttonStyle(.plain)
        }
    }
}
