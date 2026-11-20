import CryptoKit
import Darwin
import Foundation

struct NativeBoardSnapshot: Codable, Equatable {
    var values: [UInt8]
    var fixed: [Bool]
    var candidates: [UInt16]
    var userCandidates: [UInt16]

    static let blank = Self(values: Array(repeating: 0, count: 81), fixed: Array(repeating: false, count: 81),
                            candidates: Array(repeating: 0, count: 81), userCandidates: Array(repeating: 0, count: 81))

    static let example: Self = {
        let puzzle = "530070000600195000098000060800060003400803001700020006060000280000419005000080079"
        let values = puzzle.utf8.map { $0 - 48 }
        var board = Self(
            values: values, fixed: values.map { $0 != 0 },
            candidates: Array(repeating: 0, count: 81),
            userCandidates: Array(repeating: 0, count: 81))
        for i in 0..<81 where values[i] == 0 { board.candidates[i] = board.legalMask(at: i) }
        return board
    }()

    static func bit(_ digit: UInt8) -> UInt16 { 1 << (digit - 1) }

    private static let peers: [[Int]] = (0..<81).map { cell in
        (0..<81).filter { other in
            other != cell
                && (other / 9 == cell / 9 || other % 9 == cell % 9
                    || (other / 27 == cell / 27 && other % 9 / 3 == cell % 9 / 3))
        }
    }

    func legalMask(at cell: Int) -> UInt16 {
        var mask: UInt16 = 511
        for index in Self.peers[cell] where values[index] != 0 {
            mask &= ~Self.bit(values[index])
        }
        return mask
    }

    func validate() throws {
        guard values.count == 81, fixed.count == 81, candidates.count == 81,
            userCandidates.count == 81
        else { throw BoardFileError.invalid }
        for i in 0..<81 {
            guard values[i] <= 9, !fixed[i] || values[i] != 0,
                candidates[i] <= 511, userCandidates[i] <= 511,
                values[i] == 0 || candidates[i] == 0
            else { throw BoardFileError.invalid }
        }
    }

    mutating func setValue(_ digit: UInt8, at cell: Int) {
        guard values.indices.contains(cell), !fixed[cell], digit <= 9, digit != values[cell] else { return }
        let previous = values[cell]
        if previous != 0 {
            values[cell] = 0
            candidates[cell] = legalMask(at: cell)
            let bit = Self.bit(previous)
            for peer in Self.peers[cell] where values[peer] == 0 {
                candidates[peer] |= legalMask(at: peer) & bit
            }
        }
        if digit != 0 {
            values[cell] = digit
            candidates[cell] = 0
            userCandidates[cell] = 0
            let bit = Self.bit(digit)
            for peer in Self.peers[cell] {
                candidates[peer] &= ~bit
                userCandidates[peer] &= ~bit
            }
        }
    }
}

struct BoardMark: Codable, Hashable {
    var cell: Int
    var digit: Int
    var color: Int
    var light: Bool?
    var swatch: Int { color * 2 + (light == true ? 1 : 0) }
}

struct BoardPage: Codable, Equatable {
    var board = NativeBoardSnapshot.example
    var marks: [BoardMark] = []
    var ink = InkToolState()
    var chains = ChainToolState()
    var boxes = BoxToolState()
}

struct AnnotationHistory<Value: Codable & Equatable>: Codable, Equatable {
    var undo: [Value] = []
    var redo: [Value] = []
    mutating func record(_ before: Value) {
        undo.append(before)
        redo.removeAll()
    }
    mutating func restore(_ current: inout Value, redo forward: Bool) {
        if forward, let next = redo.popLast() {
            undo.append(current)
            current = next
        }
        if !forward, let next = undo.popLast() {
            redo.append(current)
            current = next
        }
    }
}

struct BoardProgress: Codable, Equatable {
    var version = 3
    var current = BoardPage()
    var boardUndo: [NativeBoardSnapshot] = []
    var boardRedo: [NativeBoardSnapshot] = []
    var markUndo: [[BoardMark]] = []
    var markRedo: [[BoardMark]] = []

    var inkHistory = AnnotationHistory<InkToolState>()
    var chainHistory = AnnotationHistory<ChainToolState>()
    var boxHistory = AnnotationHistory<BoxToolState>()
    var extra: NativeGameContext?

    mutating func resizeCandidateMarks(to width: CGFloat) -> Bool {
        var changed = current.ink.resizeCandidateMarks(to: width)
        // Undo and redo restore marks at the currently chosen width.
        for i in inkHistory.undo.indices {
            if inkHistory.undo[i].resizeCandidateMarks(to: width) { changed = true }
        }
        for i in inkHistory.redo.indices {
            if inkHistory.redo[i].resizeCandidateMarks(to: width) { changed = true }
        }
        return changed
    }

    func validate() throws {
        try current.ink.validate()
        try current.chains.validate()
        try current.boxes.validate()
        for ink in inkHistory.undo + inkHistory.redo { try ink.validate() }
        for chain in chainHistory.undo + chainHistory.redo { try chain.validate() }
        for box in boxHistory.undo + boxHistory.redo { try box.validate() }
        guard version == 3 else { throw BoardFileError.version }
        if let cell = extra?.activeCell, !(0..<81).contains(cell) { throw BoardFileError.invalid }
        for point in extra?.savePoints ?? [] { try point.progress.validate() }
        try current.board.validate()
        for board in boardUndo + boardRedo { try board.validate() }
        for marks in [current.marks] + markUndo + markRedo {
            var keys = Set<Int>()
            for mark in marks {
                guard (0..<81).contains(mark.cell), (0...9).contains(mark.digit),
                    (0..<6).contains(mark.color), keys.insert(mark.cell * 10 + mark.digit).inserted
                else { throw BoardFileError.invalid }
            }
        }
    }
}

// Phase 1 persisted teal and purple as indices 0 and 1. Preserve those colors
// and both histories while starting the six-group native format in its own file.
private struct PreviousProgress: Decodable {
    struct Page: Decodable {
        let board: NativeBoardSnapshot
        let marks: [BoardMark]
    }
    let current: Page
    let boardUndo, boardRedo: [NativeBoardSnapshot]
    let markUndo, markRedo: [[BoardMark]]

    func upgrade() throws -> BoardProgress {
        func groups(_ marks: [BoardMark]) throws -> [BoardMark] {
            try marks.map { old in
                guard (0...1).contains(old.color) else { throw BoardFileError.invalid }
                return BoardMark(cell: old.cell, digit: old.digit, color: old.color == 0 ? 3 : 1)
            }
        }
        var result = BoardProgress()
        result.current.board = current.board
        result.current.marks = try groups(current.marks)
        result.boardUndo = boardUndo
        result.boardRedo = boardRedo
        result.markUndo = try markUndo.map(groups)
        result.markRedo = try markRedo.map(groups)
        return result
    }
}

enum BoardFileError: LocalizedError {
    case invalid, version, concurrentChange, unsafeLocation
    var errorDescription: String? {
        switch self {
        case .invalid: return "原生进度文件损坏。请保留原件，在恢复副本后重试。"
        case .version: return "此进度由更新版本保存。请用对应版本打开。"
        case .concurrentChange: return "进度文件已在其他窗口或应用中更改。请重新打开后再编辑。"
        case .unsafeLocation: return "请选择原生进度的独立目录。"
        }
    }
}

/// Compare the bytes last read while holding the candidate directory lock. Concurrent
/// launches may read the same position, but cannot silently replace each other's edits.
final class NativeBoardStore {
    let directory: URL
    private let protectedJavaRoots: [URL]
    var file: URL { directory.appendingPathComponent("board-v3.json") }
    var backupFile: URL { file.appendingPathExtension("bak") }
    private(set) var restoredFromBackup = false
    private var phaseTwoFile: URL { directory.appendingPathComponent("board-v2.json") }
    private(set) var restoredRecording: NativeReplayDocument?
    private var savedProgress: BoardProgress?
    var hasSavedProgress: Bool { savedProgress != nil }
    private enum Keys: String, CodingKey { case recording }
    private struct Save: Encodable {
        let progress: BoardProgress
        let recording: NativeReplayDocument?
        func encode(to encoder: Encoder) throws {
            try progress.encode(to: encoder)
            var container = encoder.container(keyedBy: Keys.self)
            try container.encodeIfPresent(recording, forKey: .recording)
        }
    }
    private var previousFile: URL { directory.appendingPathComponent("board-v1.json") }
    private struct Observed {
        var primary: Data?
        var primaryDamaged = false
        var backupRead = false
        var backup: Data?
        var backupDamaged = false
        var migrationSource: URL?
        var migrationBytes: Data?
    }
    private var observed: Observed?
    private var validatedBackupDigest: String?
    var sessionDigest: String? {
        let bytes = restoredFromBackup ? observed?.backup : observed?.primary ?? observed?.migrationBytes
        return bytes.map(NativeReplayLibrary.digest)
    }
    private struct Header: Decodable { let version: Int }
    private struct Timeline: Decodable { let recording: NativeReplayDocument? }


    init(directory: URL? = nil, supportRoot: URL? = nil, legacyRoot: URL? = nil) {
        let environment = ProcessInfo.processInfo.environment["HODOKU_NATIVE_DATA_DIR"]
        let support = supportRoot ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let configured = ProcessInfo.processInfo.environment["HODOKU_LEGACY_DATA_DIR"].map { URL(fileURLWithPath: $0) }
        protectedJavaRoots = [support.appendingPathComponent("HoDoKu", isDirectory: true), configured, legacyRoot].compactMap { $0 }
        self.directory =
            directory ?? environment.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? support.appendingPathComponent("HoDoKu Native Candidate", isDirectory: true)
    }

    func checkDirectory() throws {
        let path = resolvedDirectory(directory).path.lowercased()
        for root in protectedJavaRoots {
            let legacy = resolvedDirectory(root).path.lowercased()
            if path == "/" || legacy == "/" || path == legacy || path.hasPrefix(legacy + "/") || legacy.hasPrefix(path + "/") {
                throw BoardFileError.unsafeLocation
            }
        }
    }

    func checkLocation() throws {
        try checkDirectory()
        if [file, backupFile, phaseTwoFile, previousFile].contains(where: {
                (try? FileManager.default.destinationOfSymbolicLink(atPath: $0.path)) != nil
            })
        {
            throw BoardFileError.unsafeLocation
        }
    }

    // realpath can resolve an existing symlink prefix before a first save
    // creates the last components of a new candidate directory.
    private func resolvedDirectory(_ url: URL) -> URL {
        var prefix = url.standardizedFileURL
        var missing: [String] = []
        while prefix.path != "/" && !FileManager.default.fileExists(atPath: prefix.path) {
            missing.append(prefix.lastPathComponent)
            prefix.deleteLastPathComponent()
        }
        return missing.reversed().reduce(prefix.resolvingSymlinksInPath()) { $0.appendingPathComponent($1) }
    }

    func checkExportLocation(_ url: URL) throws {
        let parent = resolvedDirectory(url.deletingLastPathComponent()).path.lowercased()
        for locked in [directory] + protectedJavaRoots {
            let path = resolvedDirectory(locked).path.lowercased()
            if path == "/" || parent == path || parent.hasPrefix(path + "/") { throw BoardFileError.unsafeLocation }
        }
    }

    private func bytes(at url: URL) throws -> Data? {
        do { return try Data(contentsOf: url) } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        }
    }

    private static func decode(_ data: Data, version: Int) throws -> (BoardProgress, NativeReplayDocument?) {
        let decoder = JSONDecoder()
        guard let header = try? decoder.decode(Header.self, from: data) else { throw BoardFileError.invalid }
        if header.version > version { throw BoardFileError.version }
        guard header.version == version else { throw BoardFileError.invalid }
        do {
            let recording = version == 3 ? try decoder.decode(Timeline.self, from: data).recording : nil
            var progress = version == 1
                ? try decoder.decode(PreviousProgress.self, from: data).upgrade()
                : try decoder.decode(BoardProgress.self, from: data)
            progress.version = 3
            try progress.validate()
            try checkRecording(recording, progress)
            return (progress, recording)
        } catch { throw BoardFileError.invalid }
    }

    private static func checkRecording(_ document: NativeReplayDocument?, _ progress: BoardProgress) throws {
        guard let doc = document else { return }
        try doc.validateNativeRecording()
        guard doc.frames.last?.board == progress.current.board else { throw BoardFileError.invalid }
    }

    private func locked<T>(_ mode: Int32, _ action: () throws -> T) throws -> T {
        try checkLocation()
        let fd = open(directory.path, O_RDONLY | O_DIRECTORY)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(fd) }
        guard flock(fd, mode) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { flock(fd, LOCK_UN) }
        try checkLocation()
        return try action()
    }

    private func read(allowDamaged: Bool) throws -> BoardProgress {
        try checkLocation()
        var primary: Data?
        var primaryReadError: Error?
        do { primary = try bytes(at: file) }
        catch { primaryReadError = error }
        var captured = Observed(primary: primary)
        var state: (BoardProgress, NativeReplayDocument?)?
        var recovered = false
        if let data = primary {
            do { state = try Self.decode(data, version: 3) }
            catch BoardFileError.invalid { captured.primaryDamaged = true }
        }
        if state == nil {
            captured.backupRead = true
            captured.backup = try bytes(at: backupFile)
            if let data = captured.backup {
                do {
                    state = try Self.decode(data, version: 3)
                    recovered = true
                } catch BoardFileError.invalid { captured.backupDamaged = true }
            }
        }
        if state == nil, let failure = primaryReadError { throw failure }
        // Older native formats are migration sources only when the current generation is absent.
        if primary == nil && captured.backup == nil {
            for (oldFile, version) in [(phaseTwoFile, 2), (previousFile, 1)] {
                guard let data = try bytes(at: oldFile) else { continue }
                captured.migrationSource = oldFile
                captured.migrationBytes = data
                do { state = try Self.decode(data, version: version) }
                catch BoardFileError.invalid where allowDamaged { }
                break
            }
        } else if state == nil && !allowDamaged {
            throw BoardFileError.invalid
        }

        observed = captured
        restoredFromBackup = recovered
        restoredRecording = state?.1
        savedProgress = state?.0
        return state?.0 ?? BoardProgress()
    }

    private func readDirectory(allowDamaged: Bool) throws -> BoardProgress {
        // A first launch and explicit file inspection must not create a profile.
        try checkLocation()
        if FileManager.default.fileExists(atPath: directory.path) {
            return try locked(LOCK_SH) { try read(allowDamaged: allowDamaged) }
        }
        return try read(allowDamaged: allowDamaged)
    }

    func load() throws -> BoardProgress {
        try readDirectory(allowDamaged: false)
    }

    /// A settled, unmodified game can confirm its durable generation without
    /// rewriting the primary or rotating its known-good backup.
    func verifyCurrent() throws {
        guard savedProgress != nil, let expected = observed else { return }
        try locked(LOCK_SH) { _ = try verifiedPrimary(expected) }
    }

    private func verifiedPrimary(_ expected: Observed) throws -> Data? {
        let current = try bytes(at: file)
        guard current == expected.primary else { throw BoardFileError.concurrentChange }
        if expected.backupRead, try bytes(at: backupFile) != expected.backup { throw BoardFileError.concurrentChange }
        if let source = expected.migrationSource, try bytes(at: source) != expected.migrationBytes { throw BoardFileError.concurrentChange }
        return current
    }

    /// Call only after an explicit input has been independently decoded. Register the bytes
    /// we may replace, without touching disk or acknowledging another writer's intervening save.
    @discardableResult
    func prepareExplicitReplacement() throws -> BoardProgress? {
        if observed == nil { _ = try readDirectory(allowDamaged: true) }
        return savedProgress
    }

    private func preserveDamaged(_ data: Data, from url: URL) throws {
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let archive = directory.appendingPathComponent(url.lastPathComponent + ".damaged-" + digest)
        if (try? FileManager.default.destinationOfSymbolicLink(atPath: archive.path)) != nil {
            throw BoardFileError.unsafeLocation
        }
        if let previous = try bytes(at: archive) {
            guard previous == data else { throw BoardFileError.concurrentChange }
        } else {
            let staging = directory.appendingPathComponent(".recover-" + UUID().uuidString)
            try data.write(to: staging, options: .atomic)
            defer { try? FileManager.default.removeItem(at: staging) }
            // Publish complete bytes exclusively; a failed copy cannot poison the retry path.
            try FileManager.default.linkItem(at: staging, to: archive)
        }
    }

    func save(_ progress: BoardProgress, recording: NativeReplayDocument? = nil) throws {
        try checkLocation()
        try progress.validate()
        try Self.checkRecording(recording, progress)
        let data = try JSONEncoder().encode(Save(progress: progress, recording: recording))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try locked(LOCK_EX) {
            let expected = observed ?? Observed(primary: nil, backupRead: true)
            let current = try verifiedPrimary(expected)
            if expected.backupDamaged, let damaged = expected.backup {
                try preserveDamaged(damaged, from: backupFile)
            }
            if let previous = current {
                if expected.primaryDamaged {
                    try preserveDamaged(previous, from: file)
                } else {
                    // Only a previously validated primary may be promoted to backup.
                    // Protect a newer program's backup as well as its primary.
                    if let backup = try bytes(at: backupFile), NativeReplayLibrary.digest(backup) != validatedBackupDigest {
                        do { _ = try Self.decode(backup, version: 3) }
                        catch BoardFileError.invalid { try preserveDamaged(backup, from: backupFile) }
                    }
                    try previous.write(to: backupFile, options: .atomic)
                    validatedBackupDigest = NativeReplayLibrary.digest(previous)
                }
            }
            // If this replacement fails, the primary still has its previous contents.
            // The promoted backup (if any) is already valid and retrying is idempotent.
            try data.write(to: file, options: .atomic)
            observed = Observed(primary: data)
            restoredRecording = recording
            savedProgress = progress
            restoredFromBackup = false
        }
    }
}
