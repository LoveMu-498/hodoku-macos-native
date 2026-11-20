import Combine
import Foundation
import HodokuEngine

/// A request owns its flag until both the main thread and the solver have released it.
final class CountCancellation {
    let pointer: OpaquePointer

    init?() {
        guard let flag = hodoku_cancellation_new() else { return nil }
        pointer = flag
    }

    func cancel() { hodoku_cancellation_request(pointer) }
    deinit { hodoku_cancellation_free(pointer) }
}

enum CountOutcome: Equatable {
    case exhausted(Int), bound(Int), limited(Int), cancelled, invalid, engineFailure

    var message: String {
        switch self {
        case .exhausted(0): return "当前盘面无解"
        case .exhausted(1): return "当前盘面有唯一解"
        case .exhausted(let n): return "当前盘面有 \(n) 个解"
        case .bound(let n): return "当前盘面至少有 \(n) 个解"
        case .limited(let n): return "达到搜索上限，已找到 \(n) 个解"
        case .cancelled: return "已取消解数检查"
        case .invalid: return "盘面或候选无效，请检查重复数字及候选"
        case .engineFailure: return "解数检查失败，可重新检查"
        }
    }
}

enum NativeCountEngine {
    static func count(values: [UInt8], candidates: [UInt16], bound: Int32 = 1,
                      budget: Int32 = 1_000_000, cancellation: CountCancellation) -> CountOutcome {
        guard hodoku_engine_abi_version() == HODOKU_ENGINE_ABI_VERSION else { return .engineFailure }
        var result = HodokuCountResult()
        let status = values.withUnsafeBufferPointer { digits in
            candidates.withUnsafeBufferPointer { masks in
                hodoku_count_solutions_v1(digits.baseAddress, digits.count,
                    masks.isEmpty ? nil : masks.baseAddress, masks.count,
                    bound, budget, cancellation.pointer, &result)
            }
        }
        guard status == 0 else { return status == 1 ? .invalid : .engineFailure }
        switch result.termination {
        case HODOKU_EXHAUSTED: return .exhausted(Int(result.count))
        case HODOKU_SOLUTION_BOUND: return .bound(Int(result.count))
        case HODOKU_LIMIT: return .limited(Int(result.count))
        case HODOKU_CANCELLED: return .cancelled
        default: return .engineFailure
        }
    }
}

/// User actions and published state are confined to the main thread. Only immutable arrays
/// and the request's atomic cancellation flag cross the solver queue.
final class SolutionCounter: ObservableObject {
    @Published private(set) var message: String?
    @Published private(set) var isSearching = false
    private let queue = DispatchQueue(label: "org.hodoku.nativecandidate.solution-count", qos: .userInitiated)
    private var current: CountCancellation?
    var didFinish: ((CountOutcome) -> Void)?

    func check(values: [UInt8], candidates: [UInt16]) {
        invalidate()
        guard let request = CountCancellation() else {
            message = CountOutcome.engineFailure.message
            didFinish?(.engineFailure)
            return
        }
        current = request
        isSearching = true
        message = "正在检查解数…"
        queue.async { [weak self] in
            let result = NativeCountEngine.count(values: values, candidates: candidates, cancellation: request)
            DispatchQueue.main.async { [weak self] in
                guard let self = self, self.current === request else { return }
                self.current = nil
                self.isSearching = false
                self.message = result.message
                self.didFinish?(result)
            }
        }
    }

    func invalidate() {
        current?.cancel()
        current = nil
        message = nil
        isSearching = false
    }

    func cancel() {
        invalidate()
        message = CountOutcome.cancelled.message
        didFinish?(.cancelled)
    }
}
