// SPDX-License-Identifier: GPL-3.0-or-later
import Darwin
import Foundation

/// Diagnostic output is independent of progress, replay and preference files.
enum NativeSearchDiagnostics {
    static let verbose = ProcessInfo.processInfo.environment["HODOKU_HINT_TRACE"] == "1"
    private static let directory: URL? = {
        let environment = ProcessInfo.processInfo.environment
        if let path = environment["HODOKU_NATIVE_DATA_DIR"], !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true).appendingPathComponent("Diagnostics")
        }
        guard Bundle.main.bundleIdentifier == "org.hodoku.nativecandidate" else { return nil }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/HoDoKu Native")
    }()
    private static let queue = DispatchQueue(label: "org.hodoku.search-diagnostics", qos: .utility)
    private static let slots = DispatchSemaphore(value: 8)
    private static let fileLimit: UInt64 = 64 * 1024

    static func record(_ event: String, counts: [String: Int] = [:], elapsedMS: Double? = nil) {
        guard verbose || (elapsedMS ?? 0) >= 100, let directory = directory,
              slots.wait(timeout: .now()) == .success else { return }
        let time = Date().timeIntervalSince1970
        queue.async {
            defer { slots.signal() }
            var usage = rusage()
            guard getrusage(RUSAGE_SELF, &usage) == 0 else { return }
            func millis(_ t: timeval) -> Double { Double(t.tv_sec) * 1000 + Double(t.tv_usec) / 1000 }
            var fields: [String: Any] = ["event": event, "time": time, "pid": getpid(),
                "processCPUMs": millis(usage.ru_utime) + millis(usage.ru_stime),
                "peakRSSBytes": usage.ru_maxrss, "counts": counts]
            if let elapsedMS { fields["elapsedMs"] = elapsedMS }
            guard var data = try? JSONSerialization.data(withJSONObject: fields) else { return }
            data.append(10)
            guard data.count <= fileLimit else { return }
            append(data, in: directory)
        }
    }

    private static func append(_ data: Data, in directory: URL) {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            // Multiple isolated processes can share a diagnostics root. Never wait on another writer.
            let lock = open(directory.appendingPathComponent("hint-search.lock").path, O_CREAT | O_WRONLY | O_NOFOLLOW, 0o600)
            guard lock >= 0 else { return }
            defer { close(lock) }
            guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { return }
            let url = directory.appendingPathComponent("hint-search.jsonl")
            let backup = directory.appendingPathComponent("hint-search.previous.jsonl")
            let bytes = (try? fm.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.uint64Value ?? 0
            if bytes > fileLimit - UInt64(data.count), rename(url.path, backup.path) != 0 { return }
            let fd = open(url.path, O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW, 0o600)
            guard fd >= 0 else { return }
            let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            try file.write(contentsOf: data)
        } catch { /* Diagnostic I/O must never interrupt a search. */ }
    }
}
