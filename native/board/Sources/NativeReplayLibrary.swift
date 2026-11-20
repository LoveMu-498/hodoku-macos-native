import CryptoKit
import Darwin
import Foundation

struct ReplayLibraryEntry: Identifiable, Codable {
    let id: String
    var name: String
    let imported: Bool
    let date: Date
    var pinned = false
    var bookmarks: [NativeReplayBookmark] = []
}

// Recordings and imported originals are immutable. Only the small library index changes.
final class NativeReplayLibrary {
    private let store: NativeBoardStore
    private var directory: URL { store.directory.appendingPathComponent("Replays", isDirectory: true) }
    private var index: URL { directory.appendingPathComponent("library.json") }
    init(store: NativeBoardStore) { self.store = store }

    static func digest(_ bytes: Data) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    private func check(_ url: URL) throws {
        try store.checkLocation()
        for path in [directory, index, url] where (try? FileManager.default.destinationOfSymbolicLink(atPath: path.path)) != nil {
            throw BoardFileError.unsafeLocation
        }
    }

    func entries() throws -> [ReplayLibraryEntry] {
        try check(index)
        do {
            let rows = try JSONDecoder().decode([ReplayLibraryEntry].self, from: Data(contentsOf: index))
            guard Set(rows.map(\.id)).count == rows.count, rows.allSatisfy({ $0.id.count == 64 && $0.id.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } }) else { throw BoardFileError.invalid }
            return rows.sorted { $0.pinned == $1.pinned ? $0.date > $1.date : $0.pinned }
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile { return [] }
    }

    private func locked<T>(_ action: () throws -> T) throws -> T {
        try check(index)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fd = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        defer { close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw POSIXError(.EIO) }
        defer { flock(fd, LOCK_UN) }
        return try action()
    }

    private func update(_ change: (inout [ReplayLibraryEntry]) throws -> Void) throws {
        try locked {
            var rows = try entries()
            try change(&rows)
            try JSONEncoder().encode(rows).write(to: index, options: .atomic)
        }
    }

    private func stage(_ document: NativeReplayDocument, named name: String, rows: inout [ReplayLibraryEntry],
                       created: inout [URL]) throws -> ReplayLibraryEntry {
        let bytes: Data
        if let raw = document.originalBytes { bytes = raw }
        else {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            bytes = try encoder.encode(document)
        }
        let key = Self.digest(bytes)
        let file = directory.appendingPathComponent(key)
        var entry = ReplayLibraryEntry(id: key, name: name, imported: document.originalBytes != nil, date: Date(),
                                       pinned: document.pinned, bookmarks: document.bookmarks)
        try check(file)
        if FileManager.default.fileExists(atPath: file.path) {
            guard try Data(contentsOf: file) == bytes else { throw BoardFileError.invalid }
        } else {
            try bytes.write(to: file, options: .atomic)
            created.append(file)
        }
        if let previous = rows.first(where: { $0.id == key }) { entry = previous }
        else { rows.append(entry) }
        return entry
    }

    func put(_ document: NativeReplayDocument, named name: String) throws -> ReplayLibraryEntry {
        try locked {
            var rows = try entries(), created: [URL] = []
            do {
                let entry = try stage(document, named: name, rows: &rows, created: &created)
                try JSONEncoder().encode(rows).write(to: index, options: .atomic)
                return entry
            } catch {
                for file in created { try FileManager.default.removeItem(at: file) }
                throw error
            }
        }
    }

    func archiveBranch(source: NativeReplayDocument, archived: ReplayLibraryEntry?, outgoing: NativeReplayDocument?,
                       save: (String) throws -> Void) throws {
        try locked {
            var rows = try entries(), created: [URL] = []
            let previous = FileManager.default.fileExists(atPath: index.path) ? try Data(contentsOf: index) : nil
            var published = false
            do {
                var ended = outgoing
                if ended?.endedAt == 0 { ended?.endedAt = Int64(Date().timeIntervalSince1970 * 1000) }
                let key: String
                if let archived = archived {
                    guard rows.contains(where: { $0.id == archived.id }) else { throw BoardFileError.invalid }
                    let file = directory.appendingPathComponent(archived.id)
                    try check(file)
                    guard try Self.digest(Data(contentsOf: file)) == archived.id else { throw BoardFileError.invalid }
                    key = archived.id
                } else if source == outgoing, let ended = ended {
                    key = try stage(ended, named: "先前的作答", rows: &rows, created: &created).id
                } else {
                    key = try stage(source, named: "来源回放", rows: &rows, created: &created).id
                }
                if let ended = ended, archived != nil || source != outgoing {
                    _ = try stage(ended, named: "先前的作答", rows: &rows, created: &created)
                }
                // Always publish the immutable sources before switching the durable active game.
                try JSONEncoder().encode(rows).write(to: index, options: .atomic)
                published = true
                try save(key)
            } catch {
                if published {
                    if let previous = previous { try previous.write(to: index, options: .atomic) }
                    else { try FileManager.default.removeItem(at: index) }
                }
                for file in created { try FileManager.default.removeItem(at: file) }
                throw error
            }
        }
    }

    static func read(_ url: URL) throws -> NativeReplayDocument {
        let info = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard info.isRegularFile == true, let size = info.fileSize, size <= 128 * 1024 * 1024 else {
            throw ReplayExchangeError("文件大小或类型无效")
        }
        // Hold a private copy. Replacing or editing the external file cannot change an open replay.
        return try decode(Data(contentsOf: url))
    }

    static func decode(_ bytes: Data) throws -> NativeReplayDocument {
        guard bytes.count >= 8, Array(bytes.prefix(4)) == Array("HRPL".utf8) else { throw ReplayExchangeError("文件头无效") }
        switch Array(bytes[4..<8]) {
        case [0, 0, 0, 3]: return try ReplayJavaCodec.decode(bytes)
        case [0, 0, 0, 4]: return try ReplayExchange.decode(bytes)
        default: throw ReplayExchangeError("未支持的回放版本")
        }
    }

    func load(_ entry: ReplayLibraryEntry) throws -> NativeReplayDocument {
        guard let saved = try entries().first(where: { $0.id == entry.id }) else { throw BoardFileError.invalid }
        let file = directory.appendingPathComponent(saved.id)
        try check(file)
        let bytes = try Data(contentsOf: file)
        guard Self.digest(bytes) == saved.id else { throw BoardFileError.invalid }
        var doc = saved.imported ? try Self.decode(bytes) : try JSONDecoder().decode(NativeReplayDocument.self, from: bytes)
        if !saved.imported { try doc.validateNativeRecording() }
        guard saved.bookmarks.allSatisfy({ doc.frames.indices.contains($0.frameIndex) }) else { throw BoardFileError.invalid }
        doc.bookmarks = saved.bookmarks
        doc.pinned = saved.pinned
        return doc
    }

    func change(_ id: String, _ edit: (inout ReplayLibraryEntry) -> Void) throws -> ReplayLibraryEntry {
        var updated: ReplayLibraryEntry?
        try update { rows in
            guard let i = rows.firstIndex(where: { $0.id == id }) else { throw BoardFileError.invalid }
            edit(&rows[i])
            updated = rows[i]
        }
        guard let entry = updated else { throw BoardFileError.invalid }
        return entry
    }

    func export(_ bytes: Data, to url: URL) throws {
        try store.checkExportLocation(url)
        // Link the completed temporary file into place atomically. link(2) refuses any existing name.
        let parent = url.deletingLastPathComponent()
        let temp = parent.appendingPathComponent(".hodoku-export-" + UUID().uuidString)
        try bytes.write(to: temp, options: .withoutOverwriting)
        defer { try? FileManager.default.removeItem(at: temp) }
        try FileManager.default.linkItem(at: temp, to: url)
    }
}
