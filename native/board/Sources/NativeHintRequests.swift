import Foundation

enum NativeHintAnswer {
    case step(NativeHintStep, stages: [NativeHintStage]? = nil, partial: Bool = false, index: Int = 0)
    case noMatch
    case notice(String)
}

/// Owned by the main thread. Workers only see immutable captures and return a value.
/// Superseded or closed requests never deliver a result, even after an edit and undo.
final class NativeHintRequests {
    enum Source: String {
        case ordinary, boxes, chain, tabBoxes, tabDigits, tabChain

        var noMatchMessage: String {
            switch self {
            case .ordinary: return "未找到匹配的解题步骤。可检查候选数或求解设置。"
            case .boxes, .tabBoxes: return "未找到匹配的解题步骤。可调整选框。"
            case .chain, .tabChain: return "未找到匹配的解题步骤。可检查链的端点和强弱关系。"
            case .tabDigits: return "未找到匹配的解题步骤。可更换筛选，或按 ⌥F12 查找全盘。"
            }
        }
    }
    enum Input {
        case key(down: Bool, time: Int), focus(gained: Bool, time: Int), wheel(Double, time: Int), move(Int), advanceAnalysis
    }

    private let queue: DispatchQueue
    private var id: UUID?
    private var work: BlockOperation?
    private var inputs = [Input]()
    private var preview = BoardHintGesture(referenceCount: 1)
    private(set) var source: Source?

    init(queue: DispatchQueue) { self.queue = queue }

    func cancel() {
        work?.cancel()
        work = nil
        id = nil
        source = nil
        inputs.removeAll()
        preview = BoardHintGesture(referenceCount: 1)
    }

    func start<Value>(source: Source, compute: @escaping (() -> Bool) throws -> Value,
                      deliver: @escaping (Result<Value, Error>, [Input]) -> Void) {
        cancel()
        let token = UUID()
        id = token
        self.source = source
        let submitted = DispatchTime.now().uptimeNanoseconds
        let task = BlockOperation()
        task.addExecutionBlock { [weak self, weak task] in
            guard let task = task, !task.isCancelled else { return }
            let started = DispatchTime.now().uptimeNanoseconds
            let result = Result { try compute { task.isCancelled } }
            let finished = DispatchTime.now().uptimeNanoseconds
            DispatchQueue.main.async { [weak self] in
                let current = self?.id == token
                NativeSearchDiagnostics.record("request." + source.rawValue, counts: [
                    "queueMs": Int((started - submitted) / 1_000_000),
                    "workerMs": Int((finished - started) / 1_000_000), "superseded": current ? 0 : 1
                ], elapsedMS: Double(DispatchTime.now().uptimeNanoseconds - submitted) / 1_000_000)
                guard current, let self else { return }
                let inputs = self.inputs
                self.cancel()
                deliver(result, inputs)
            }
        }
        work = task
        queue.async { task.start() }
    }

    /// Retain gesture timestamps while waiting for the current stage's real references.
    @discardableResult
    func deferInput(_ input: Input) -> Bool {
        guard id != nil else { return false }
        switch input {
        case let .key(down, time): if down { preview.press(time) } else { preview.release(time) }
        case let .focus(gained, time): preview.setPaused(!gained, now: time)
        case let .wheel(delta, time): guard preview.wheel(delta, now: time) else { return false }
        case .move, .advanceAnalysis: break
        }
        inputs.append(input)
        return true
    }
}
