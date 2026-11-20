import Foundation
import HodokuEngine

private struct JavaRecording: Decodable {
    struct Arguments: Decodable {
        let values: [UInt8]
        let candidates: [UInt16]
        let bound: Int32
        let budget: Int32
        let cancelled: Bool

        init(from decoder: Decoder) throws {
            var args = try decoder.unkeyedContainer()
            values = try args.decode(String.self).utf8.map { $0 == 46 ? 0 : $0 - 48 }
            let hex = Array(try args.decode(String.self).utf8)
            candidates = stride(from: 0, to: hex.count, by: 3).map { start in
                UInt16(String(decoding: hex[start..<(start+3)], as: UTF8.self), radix: 16)!
            }
            bound = try args.decode(Int32.self)
            budget = try args.decode(Int32.self)
            cancelled = try args.decode(Bool.self)
        }
    }
    let args: Arguments
    let ok: String?
    let error_type: String?

    func actual() -> String {
        let request = CountCancellation()!
        if args.cancelled { request.cancel() }
        var result = HodokuCountResult()
        let status = args.values.withUnsafeBufferPointer { values in
            args.candidates.withUnsafeBufferPointer { masks in
                hodoku_count_solutions_v1(values.baseAddress, values.count,
                    masks.isEmpty ? nil : masks.baseAddress, masks.count,
                    args.bound, args.budget, request.pointer, &result)
            }
        }
        guard status == 0 else { return status == 1 ? "INVALID" : "INTERNAL_ERROR" }
        let names = ["EXHAUSTED", "SOLUTION_BOUND", "LIMIT", "CANCELLED"]
        let solution = withUnsafeBytes(of: result.solution) { bytes in
            bytes.allSatisfy { $0 == 0 } ? "" : bytes.map(String.init).joined()
        }
        return [names[Int(result.termination)], String(result.count), String(result.tries), solution].joined(separator: "|")
    }
}

private func compareRecordings(at path: String) throws {
    let lines = try String(contentsOfFile: path, encoding: .utf8).split(separator: "\n")
    var matches = 0, corrections = 0
    for (index, line) in lines.enumerated() {
        let sample = try JSONDecoder().decode(JavaRecording.self, from: Data(line.utf8))
        let result = sample.actual()
        let digits = sample.args.values
        if digits.allSatisfy({ $0 == 0 }) && sample.ok == "EXHAUSTED|0|0|" {
            precondition(result.hasPrefix("SOLUTION_BOUND|2|") && result.hasSuffix("|"))
            corrections += 1
        } else if digits.starts(with: [3,3,4]) && !digits.contains(0) && sample.ok?.hasPrefix("EXHAUSTED|1|") == true {
            precondition(result == "INVALID")
            corrections += 1
        } else {
            let expected = sample.error_type == "IllegalArgumentException" ? "INVALID" : sample.ok
            precondition(result == expected, "C ABI output differs at recording \(index + 1): \(result)")
            matches += 1
        }
    }
    precondition(matches > 0 && corrections == 2)
    print("PASS Swift ABI Java recordings: \(matches) exact/typed-error matches, \(corrections) documented corrections")
}

@main
enum CountChecks {
    static func main() throws {
        try compareRecordings(at: CommandLine.arguments[1])
        let unique = "..15............32...............2.9.5...3......7..8..27.....4.3...9.......6..5.."
        let multiple = "1..2..3...2.1.........3...1....1.2.3..1...4....2.4...........1.2.........1......."
        func digits(_ s: String) -> [UInt8] { s.utf8.map { $0 == 46 ? 0 : $0 - 48 } }
        let one = digits(unique)
        let many = digits(multiple)
        let empty = Array(repeating: UInt8(0), count: 81)
        let flag = CountCancellation()!
        func check(_ v: [UInt8], _ masks: [UInt16] = [], budget: Int32 = 1_000_000) -> CountOutcome {
            NativeCountEngine.count(values: v, candidates: masks, budget: budget, cancellation: flag)
        }
        precondition(check(one) == .exhausted(1))
        precondition(check(many) == .bound(2))
        precondition(check(many, budget: 29) == .limited(1))
        precondition(check(empty) == .bound(2))
        precondition(check(one, Array(repeating: 0, count: 81)) == .exhausted(0))
        precondition(check([1, 2]) == .invalid)
        var duplicate = one
        duplicate[0] = 1
        precondition(check(duplicate) == .invalid)
        flag.cancel()
        precondition(check(one) == .cancelled)

        let counter = SolutionCounter()
        counter.check(values: many, candidates: [])
        counter.check(values: one, candidates: [])
        let deadline = Date(timeIntervalSinceNow: 3)
        while counter.isSearching && Date() < deadline {
            _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
        }
        precondition(counter.message == CountOutcome.exhausted(1).message)
        counter.check(values: many, candidates: [])
        counter.invalidate()
        _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
        precondition(counter.message == nil && !counter.isSearching)
        print("PASS Swift C ABI, ordinary candidate masks, termination states, replacement and stale results")
    }
}
