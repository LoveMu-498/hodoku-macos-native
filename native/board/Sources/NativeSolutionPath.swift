// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import SwiftUI

struct SolutionPathResult {
    enum Ending: Equatable { case solved, unavailable, cancelled, timeLimit, failed(String) }
    struct Row {
        let step: NativeHintStep
        let source: NativeBoardSnapshot
    }
    let steps: [Row]
    let finalBoard: NativeBoardSnapshot
    let ending: Ending
    var difficulty: Int?
    var score: Int?

    static func compute(_ original: NativeBoardSnapshot, config: NativeSolverConfig = .standard, deadline: DispatchTime,
                        cancelled: () -> Bool) -> Self {
        var board = original
        var steps = [Row]()
        func finish(_ ending: Ending) -> Self { Self(steps: steps, finalBoard: board, ending: ending) }
        do {
            if cancelled() { return finish(.cancelled) }
            if DispatchTime.now() >= deadline { return finish(.timeLimit) }
            let path = try NativeLogicalEngine.rate(original,config:config,cancelled:{ cancelled() || DispatchTime.now() >= deadline })
            for proof in path.steps where proof.kind != "GIVE_UP" {
                let step = proof.hint()
                guard let next = step.applying(to:board) else { return finish(.failed(NativeHintError.engine.localizedDescription)) }
                steps.append(Row(step:step,source:board))
                board = next
            }
            switch path.ending {
            case .solved: return Self(steps:steps,finalBoard:board,ending:.solved,difficulty:path.difficulty,score:path.score)
            case .cancelled: return finish(cancelled() ? .cancelled : .timeLimit)
            case .contradiction: return finish(.failed(NativeHintError.contradiction.localizedDescription))
            case .unrated: return finish(.failed("当前鱼型设置无法为此盘面评分。"))
            case .unsupported: return finish(.failed("下一项搜索尚未支持：" + NativeHintTechnique(key:path.missing ?? "").name))
            default: return finish(.unavailable)
            }
        } catch { return finish(.failed(error.localizedDescription)) }
    }
}

private final class SolutionPathJob: ObservableObject {
    @Published private(set) var result: SolutionPathResult?
    @Published private(set) var running = false
    private var current: BlockOperation?
    private(set) var requestID = UUID()
    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInitiated
        return queue
    }()

    func clear() {
        current?.cancel()
        current = nil
        result = nil
        running = false
    }

    func start(_ board: NativeBoardSnapshot, config: NativeSolverConfig) {
        clear()
        let op = BlockOperation()
        current = op
        running = true
        requestID = UUID()
        op.addExecutionBlock { [weak self, weak op] in
            guard let op = op else { return }
            let result = SolutionPathResult.compute(board, config:config, deadline: .now() + .seconds(3)) { op.isCancelled }
            DispatchQueue.main.async { [weak self, weak op] in
                guard let self = self, let op = op, self.current === op else { return }
                self.result = result
                self.running = false
                self.current = nil
            }
        }
        queue.addOperation(op)
    }
}

enum NativeTechniqueTab: String, Hashable { case techniques, reasoning, path }

struct NativeSolutionPathHeight: PreferenceKey {
    static let defaultValue: CGFloat? = nil
    static func reduce(value: inout CGFloat?, nextValue: () -> CGFloat?) { value = nextValue() }
}

struct NativeSolutionPath: View {
    @ObservedObject var model: NativeBoardModel
    @StateObject private var analysis = SolutionPathJob()
    @State private var expanded = Set<Int>()
    private var board: NativeBoardSnapshot { model.progress.current.board }

    // Reserve space for the tabs, result summary, refresh button and panel insets.
    // Check collapsed rows at the minimum sidebar width. Expanded explanations
    // may wrap or scroll, so opening one restores the normal reading width.
    private var fittingHeight: CGFloat? {
        guard model.generalOptions.useDefaultFontSize, let result = analysis.result,
              result.ending == .solved, expanded.isEmpty else { return nil }
        let font = NSFont.systemFont(ofSize: 15)
        return result.steps.enumerated().reduce(CGFloat(116)) { height, entry in
            let title = "\(entry.offset + 1). \(entry.element.step.technique.name)" as NSString
            let bounds = title.boundingRect(with: NSSize(width: CGFloat(188), height: CGFloat.greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font])
            return height + max(22, ceil(bounds.height)) + 8
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if analysis.running {
                VStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("正在计算解题路径…").foregroundColor(.secondary)
                    Button("停止计算", action: analysis.clear)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let result = analysis.result {
                HStack(alignment: .top) {
                    ending(result).fixedSize(horizontal: false, vertical: true)
                        .accessibilityElement(children: .contain)
                    Spacer(minLength: 4)
                    Button(action: start) { Image(systemName: "arrow.clockwise") }
                        .accessibilityLabel("重新计算").help("重新计算")
                }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(result.steps.indices, id: \.self) { i in
                            let row = result.steps[i]
                            DisclosureGroup("\(i + 1). \(row.step.technique.name)", isExpanded: Binding(
                                get: { expanded.contains(i) },
                                set: { value in
                                    if value { expanded.insert(i) }
                                    else { expanded.remove(i) }
                                }
                            )) {
                                Text(NativeHintReading(step: row.step, source: row.source).stages.last?.text ?? "")
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }.padding(.trailing, 4)
                }.id(analysis.requestID)
            } else {
                Button("计算路径", action: start)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }.accessibilityElement(children: .contain)
            .accessibilityIdentifier("native-solution-path")
            .preference(key: NativeSolutionPathHeight.self, value: fittingHeight)
            .onAppear(perform: start)
            .onChange(of: board) { _ in start() }
            .onChange(of: model.solverConfig) { _ in start() }
            .onDisappear(perform: analysis.clear)
    }

    private func start() {
        expanded.removeAll()
        analysis.start(board, config: model.solverConfig)
    }

    @ViewBuilder private func ending(_ result: SolutionPathResult) -> some View {
        switch result.ending {
        case .solved:
            VStack(alignment: .leading, spacing: 3) {
                Text("已推演至终盘，共 \(result.steps.count) 步。")
                    .accessibilityIdentifier("native-solution-path-result")
                if let grade = result.difficulty, let score = result.score, (1...5).contains(grade) {
                    let name = model.generalOptions.localized(NativeBoardAppearance.levelNames[grade])
                    Text("\(name)  \(score) 分").font(.caption).foregroundColor(.secondary)
                }
            }
        case .unavailable: Text("当前技巧无法继续推演。")
        case .timeLimit: Text("计算超时，已列出找到的步骤。")
        case .failed(let reason): Text(reason)
        case .cancelled: EmptyView()
        }
    }
}
