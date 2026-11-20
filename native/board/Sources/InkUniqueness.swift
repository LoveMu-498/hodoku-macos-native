import Foundation
import HodokuEngine

/// The rectangle may only use uniqueness proved from the givens. Authored ink,
/// player placements and manually reduced candidates are never solver inputs.
final class InkUniqueness {
    private final class Request {
        let token: OpaquePointer
        init?() {
            guard let token = hodoku_cancellation_new() else { return nil }
            self.token = token
        }
        func cancel() { hodoku_cancellation_request(token) }
        deinit { hodoku_cancellation_free(token) }
    }

    private var givens: [UInt8]?
    private(set) var solution: [UInt8]?
    private var active: Request?
    // Only the latest current-reasoning request can still own the chooser.
    // All coordination and completions run on the main thread.
    private var reasoningReady: (([UInt8]?) -> Void)?
    private let queue = DispatchQueue(label: "org.hodoku.nativecandidate.ink-uniqueness", qos: .utility)

    deinit { active?.cancel() }

    func evidence(for board: NativeBoardSnapshot, ink: InkToolState, ready: @escaping () -> Void) -> Bool {
        // One group must actually contain four circle assertions before UR is possible.
        var circleCounts = [Int: Int]()
        for mark in ink.strokes where mark.kind == .circle { circleCounts[mark.group, default: 0] += 1 }
        guard circleCounts.values.contains(where: { $0 >= 4 }) else { return false }
        request(for: board, ready: ready)
        return solution != nil
    }

    func request(for board: NativeBoardSnapshot, ready: @escaping () -> Void) {
        let values = zip(board.values, board.fixed).map { $1 ? $0 : 0 }
        if givens == values { return }
        active?.cancel()
        reasoningReady = nil
        active = nil
        givens = nil
        solution = nil
        guard let request = Request() else { return }
        active = request
        givens = values
        queue.async { [weak self] in
            var result = HodokuCountResult()
            let status = hodoku_count_solutions_v1(values, values.count, nil, 0, 1, HODOKU_DEFAULT_MAX_TRIES, request.token, &result)
            let proved = status == 0 && result.termination == HODOKU_EXHAUSTED && result.count == 1
            let solution: [UInt8]? = proved ? withUnsafeBytes(of: result.solution) { Array($0) } : nil
            DispatchQueue.main.async { [weak self] in
                guard let self = self, self.active === request else { return }
                self.active = nil
                self.solution = solution
                let reasoningReady = self.reasoningReady
                self.reasoningReady = nil
                ready()
                reasoningReady?(solution)
            }
        }
    }

    func whenResolvedForReasoning(_ callback: @escaping ([UInt8]?) -> Void) {
        if active == nil { callback(solution) }
        else { reasoningReady = callback }
    }

    func stopWaitingForReasoning() { reasoningReady = nil }
}
