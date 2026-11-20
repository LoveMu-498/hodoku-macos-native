// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Holds immutable engine results. A window's request token, reading position and
/// right to apply a step remain in the board model, even when a result is reused.
final class NativePreparedHints {
    private enum Request: Equatable {
        case ordinary
        case scope(NativeHintMatchInput, firstOnly: Bool)
    }

    private struct Key: Equatable {
        let board: NativeBoardSnapshot
        let config: NativeSolverConfig
        let request: Request
    }

    private enum Value {
        case path(NativeLogicalPath)
        case steps([NativeHintStep])

        var estimatedBytes: Int? {
            switch self {
            case .path(let path):
                guard path.ending != .cancelled else { return nil }
                return path.steps.reduce(64) { $0 + $1.estimatedPreparedBytes }
            case .steps(let steps):
                return steps.reduce(64) { $0 + $1.estimatedPreparedBytes }
            }
        }
    }

    private final class Flight {
        let key: Key
        let cancellation = BlockOperation()
        var result: Result<Value, Error>?
        var finished = false

        init(_ key: Key) { self.key = key }
    }

    private let condition = NSCondition()
    private let byteLimit: Int
    private var generation: UInt64 = 0
    private var entries = [(key: Key, value: Value, bytes: Int)]()
    private var retainedBytes = 0
    private var flights = [Flight]()
    private var preparation: BlockOperation?
    // An inconclusive prefix is remembered only to avoid repeating idle work. It
    // is never returned to a foreground caller as a negative search result.
    private var attempted: Key?
    private var counts = [String: Int]()
    static let defaultByteLimit = 4 * 1_024 * 1_024
    init(byteLimit: Int = NativePreparedHints.defaultByteLimit) { self.byteLimit = byteLimit }
    var stats: [String: Int] {
        condition.lock()
        defer { condition.unlock() }
        return counts.merging(["entries": entries.count, "estimatedBytes": retainedBytes]) { _, new in new }
    }

    func invalidate() {
        condition.lock()
        preparation?.cancel()
        attempted = nil
        generation &+= 1
        for flight in flights { flight.cancellation.cancel() }
        entries.removeAll()
        retainedBytes = 0
        condition.broadcast()
        condition.unlock()
    }

    func cancelPreparation() {
        condition.lock()
        preparation?.cancel()
        condition.unlock()
    }

    private func cached(_ key: Key) -> Value? {
        if let entry = entries.last(where: { $0.key == key }) { return entry.value }
        if case .scope(let scope, firstOnly: true) = key.request {
            let full = Key(board: key.board, config: key.config, request: .scope(scope, firstOnly: false))
            if case .steps(let steps)? = entries.last(where: { $0.key == full })?.value {
                return .steps(Array(steps.prefix(1)))
            }
        }
        return nil
    }

    private func store(_ value: Value, for key: Key, bytes: Int) {
        guard bytes <= byteLimit else { counts["oversize", default: 0] += 1; return }
        if let index = entries.firstIndex(where: { $0.key == key }) { retainedBytes -= entries.remove(at: index).bytes }
        while entries.count >= 8 || retainedBytes + bytes > byteLimit {
            retainedBytes -= entries.removeFirst().bytes
            counts["evicted", default: 0] += 1
        }
        entries.append((key, value, bytes))
        retainedBytes += bytes
        counts["stored", default: 0] += 1
    }

    /// A cancelled owner releases any other live caller to retry under its own
    /// cancellation token. A job interrupted between Rust families is never a miss.
    private func foreground(_ key: Key, cancelled: () -> Bool,
                            compute: (() -> Bool) throws -> Value) throws -> Value {
        condition.lock()
        let initialGeneration = generation
        condition.unlock()
        while !cancelled() {
            condition.lock()
            guard generation == initialGeneration else { condition.unlock(); break }
            preparation?.cancel()
            if let value = cached(key) {
                counts["hit", default: 0] += 1
                condition.unlock()
                NativeSearchDiagnostics.record("hint.cache.hit")
                return value
            }
            if let flight = flights.first(where: { $0.key == key && !$0.cancellation.isCancelled }) {
                counts["joined", default: 0] += 1
                while !flight.finished && !flight.cancellation.isCancelled && !cancelled() {
                    _ = condition.wait(until: Date(timeIntervalSinceNow: 0.02))
                }
                let result = generation == initialGeneration ? flight.result : nil
                condition.unlock()
                if !cancelled(), let result { return try result.get() }
                continue
            }

            let flight = Flight(key)
            flights.append(flight)
            counts["miss", default: 0] += 1
            condition.unlock()

            let result = withoutActuallyEscaping(cancelled) { callerCancelled in
                Result { try compute { flight.cancellation.isCancelled || callerCancelled() } }
            }
            let estimate = (try? result.get())?.estimatedBytes
            condition.lock()
            let current = !flight.cancellation.isCancelled && !cancelled()
            if current {
                flight.result = result
                if case .success(let value) = result, let estimate { store(value, for: key, bytes: estimate) }
            }
            flight.finished = true
            flights.removeAll { $0 === flight }
            condition.broadcast()
            condition.unlock()
            NativeSearchDiagnostics.record("hint.cache.miss")
            if !current { break }
            return try result.get()
        }
        switch key.request {
        case .scope: return .steps([])
        case .ordinary:
            return .path(NativeLogicalPath(ending: .cancelled, difficulty: 0, score: 0, steps: [], missing: nil))
        }
    }

    func steps(_ scope: NativeHintMatchInput, on board: NativeBoardSnapshot, config: NativeSolverConfig,
               firstOnly: Bool, cancelled: () -> Bool) throws -> [NativeHintStep] {
        let key = Key(board: board, config: config, request: .scope(scope, firstOnly: firstOnly))
        let value = try foreground(key, cancelled: cancelled) { stop in
            .steps(try scope.steps(on: board, config: config, firstOnly: firstOnly, cancelled: stop))
        }
        guard case .steps(let steps) = value else { throw NativeHintError.engine }
        return steps
    }

    func ordinary(_ board: NativeBoardSnapshot, config: NativeSolverConfig,
                  cancelled: () -> Bool) throws -> NativeLogicalPath {
        let key = Key(board: board, config: config, request: .ordinary)
        let value = try foreground(key, cancelled: cancelled) { stop in
            .path(try NativeLogicalEngine.rate(board, config: config, firstOnly: true, cancelled: stop))
        }
        guard case .path(let path) = value else { throw NativeHintError.engine }
        return path
    }

    /// Called on a serial utility queue once the board has settled. Only a proved
    /// first choice from the exact foreground order can be published. Chain search,
    /// multi-digit filters, exhaustive lists and inconclusive prefixes stay on demand.
    func prepare(_ board: NativeBoardSnapshot, config: NativeSolverConfig, scope: NativeHintMatchInput?,
                 cancelled: () -> Bool = { false }) {
        if let scope {
            switch scope {
            case .chain: return
            case .digits(let digits) where digits.count != 1: return
            default: break
            }
        }
        let key = Key(board: board, config: config, request: scope.map { .scope($0, firstOnly: true) } ?? .ordinary)
        let task = BlockOperation()
        condition.lock()
        guard !cancelled(), attempted != key, cached(key) == nil, preparation == nil, flights.isEmpty else {
            condition.unlock()
            return
        }
        preparation = task
        counts["warmStarted", default: 0] += 1
        condition.unlock()

        // Single-family work has a hard structural bound in addition to this deadline.
        let deadline = DispatchTime.now() + .milliseconds(40)
        func stop() -> Bool { task.isCancelled || cancelled() || DispatchTime.now() >= deadline }
        var prepared: Value?
        if let scope {
            if let steps = try? scope.steps(on: board, config: config, firstOnly: true,
                                            preparingSingles: true, cancelled: stop), !steps.isEmpty {
                prepared = .steps(steps)
            }
        } else {
            // Preserve wire()'s stable rule order, including custom solver settings.
            let ordered = config.rules.enumerated().filter { $0.element.enabled }.sorted {
                ($0.element.index, $0.offset) < ($1.element.index, $1.offset)
            }
            let leading = ordered.prefix(while: { NativeFineHints.singles.contains($0.element.kind) }).prefix(3)
            if !leading.isEmpty {
                var prefix = config
                prefix.rules = leading.map(\.element)
                if let path = try? NativeLogicalEngine.rate(board, config: prefix, firstOnly: true, cancelled: stop),
                   path.ending == .firstStep {
                    prepared = .path(path)
                }
            }
        }
        let estimate = prepared?.estimatedBytes
        condition.lock()
        let accepted = !stop() && (estimate.map { $0 <= byteLimit } ?? false)
        if !task.isCancelled && !cancelled() { attempted = key }
        if accepted, let prepared, let estimate {
            store(prepared, for: key, bytes: estimate)
            counts["warmStored", default: 0] += 1
        }
        counts["warmFinished", default: 0] += 1
        preparation = nil
        condition.unlock()
        NativeSearchDiagnostics.record("hint.prepare", counts: ["stored": accepted ? 1 : 0])
    }
}

extension NativeHintStep {
    var estimatedPreparedBytes: Int {
        MemoryLayout<Self>.stride + deletions.count * MemoryLayout<UInt16>.stride
            + premises.count * MemoryLayout<Int>.stride + (logical?.estimatedPreparedBytes ?? 0)
    }
}

private extension NativeLogicalStep {
    /// Approximate retained proof storage for eviction. Includes variable-size
    /// arrays and nested chain/ALS payloads; allocator RSS is measured separately.
    var estimatedPreparedBytes: Int {
        let atoms = deletes.count + fins.count + endoFins.count + potential.count
            + cannibalistic.count + potentialCannibalistic.count
        let ints = indices.count + bases.count + covers.count + entity.count
            + colors.count * 3
        var bytes = MemoryLayout<Self>.stride + values.count + ints * MemoryLayout<Int>.stride
        bytes += atoms * MemoryLayout<Candidate>.stride + kind.utf8.count + trainingKey.utf8.count
        bytes += subtype?.utf8.count ?? 0
        for chain in chains { bytes += 32 + chain.count * MemoryLayout<Int32>.stride }
        for groups in [alsCells, alsDigits, restricted] {
            for cells in groups { bytes += 32 + cells.count * MemoryLayout<Int>.stride }
        }
        return bytes
    }
}
