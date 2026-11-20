// SPDX-License-Identifier: GPL-3.0-or-later
import Darwin
import Foundation

/// Optimistic concurrency is per independent save target. Serialize its final comparison
/// and atomic replacement with the same directory flock used by NativeBoardStore.
final class WorkspaceFile {
    let url: URL
    private let store: NativeBoardStore
    private var observed: Data?
    private var loaded = false
    init(_ name: String, store: NativeBoardStore) {
        self.store = store
        url = store.directory.appendingPathComponent(name)
    }
    private func bytes(_ file: URL) throws -> Data? {
        if (try? FileManager.default.destinationOfSymbolicLink(atPath: file.path)) != nil { throw BoardFileError.unsafeLocation }
        do { return try Data(contentsOf: file) }
        catch let e as CocoaError where e.code == .fileReadNoSuchFile { return nil }
    }
    func read() throws -> Data? {
        try store.checkDirectory()
        let value = try bytes(url)
        observed = value
        loaded = true
        return value
    }
    func write(_ data: Data) throws {
        try store.checkDirectory()
        try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
        let fd = open(store.directory.path, O_RDONLY | O_DIRECTORY)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        defer { close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw POSIXError(.EIO) }
        defer { flock(fd, LOCK_UN) }
        let current = try bytes(url)
        guard loaded ? current == observed : current == nil else { throw BoardFileError.concurrentChange }
        if current != data { try data.write(to: url, options: .atomic) }
        observed = data
        loaded = true
    }
    func write<T: Encodable>(_ item: T) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try write(encoder.encode(item))
    }
}

struct NativeWorkspacePreferences: Codable, Equatable {
    var version = 1
    var difficulty = 1
    var mode = "PLAYING"
    var appearance = "SYSTEM"
    var historyLimit = 50
    var history: [NativePuzzleHistoryEntry] = []
    var training: Set<String> = []
    var solverEdits: NativeSolverOverrides?
    var legacyXML: Data?
    var generatorPatterns: NativePatternSettings?
    var visual: NativeBoardAppearance?

    func resolvedVisual() throws -> NativeBoardAppearance {
        if let visual = visual { return visual }
        if let xml = legacyXML, let options = try LegacySessionXML.objects(xml).first { return try NativeBoardAppearance(options) }
        return NativeBoardAppearance()
    }

    func resolvedPatterns() throws -> NativePatternSettings {
        if let patterns = generatorPatterns { return patterns }
        if let xml = legacyXML, let options = try LegacySessionXML.objects(xml).first { return try NativePatternSettings(options) }
        return NativePatternSettings()
    }

    var general: NativeGeneralOptions?
    func resolvedGeneralOptions() throws -> NativeGeneralOptions {
        if let general { return general }
        if let xml = legacyXML, let options = try LegacySessionXML.objects(xml).first { return try NativeGeneralOptions(options) }
        return NativeGeneralOptions()
    }

    var mouse: NativeMouseOptions?

    func resolvedMouseOptions() throws -> NativeMouseOptions {
        if let mouse = mouse { return mouse }
        if let xml = legacyXML, let options = try LegacySessionXML.objects(xml).first { return try NativeMouseOptions(options) }
        return NativeMouseOptions()
    }

    func validate() throws {
        try general?.validate()
        guard version == 1 else { throw BoardFileError.version }
        guard (1...5).contains(difficulty), ["PLAYING", "PRACTISING", "LEARNING"].contains(mode),
              ["SYSTEM", "LIGHT", "DARK"].contains(appearance), historyLimit >= 0 else { throw BoardFileError.invalid }
        try solverEdits?.validate()
        try generatorPatterns?.validate()
        try visual?.validate()
        for entry in history { _ = try NativePuzzleHistoryEntry.parse(entry.encode()) }
    }

    static func importJava(_ url: URL) throws -> Self {
        let info = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard info.isRegularFile == true, let size = info.fileSize, (1...LegacySettingsFile.maxSize).contains(size) else {
            throw WorkspaceProblem("设置文件为空、过大或不可读。")
        }
        return try LegacySettingsFile(Data(contentsOf: url)).preferences
    }

    func exportJava() throws -> Data { try LegacySettingsFile.export(self) }
}
