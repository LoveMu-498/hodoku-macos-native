// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

#if !COMBINED_BOARD_CHECKS
@main
#endif
enum NativeStorageChecks {
    private struct Failure: Error, CustomStringConvertible { let description: String }

    private static func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw Failure(description: message) }
    }

    private static func position(_ digit: UInt8) -> BoardProgress {
        var progress = BoardProgress()
        progress.current.board.setValue(digit, at: 2)
        return progress
    }

    static func main() throws {
        let fm = FileManager.default
        guard let path = ProcessInfo.processInfo.environment["HODOKU_NATIVE_DATA_DIR"] else {
            throw BoardFileError.unsafeLocation
        }
        let root = URL(fileURLWithPath: path).appendingPathComponent("store-checks-" + UUID().uuidString)
        print("Temporary native storage fixtures: \(root.path); remove after tests")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        try normalAndRecovery(root.appendingPathComponent("recovery"))
        try explicitReplacement(root.appendingPathComponent("explicit"))
        try retry(root.appendingPathComponent("retry"))
        try protectedFiles(root.appendingPathComponent("protected"))
        try protectedJavaRoot(root.appendingPathComponent("custom-java"))
        try interruptedQuit(root.appendingPathComponent("crash"))
        try atomicSavePoint(root.appendingPathComponent("points"))
        try unchangedQuit(root.appendingPathComponent("unchanged"))
        try coldReplayBranch(root.appendingPathComponent("cold-branch"))
        print("PASS native storage: primary/backup, independent restart, corruption preservation, CAS, custom Java roots, future/symlink protection, interrupted quit reconciliation, unchanged quit, atomic savepoints, cold replay branching with and without prior attempts")
    }

    private static func coldReplayBranch(_ dir: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let fixture = URL(fileURLWithPath: "docs/replay-protocol/fixtures/m2/noncanonical.hrep.b64")
        guard let raw = try Data(base64Encoded: Data(contentsOf: fixture), options: .ignoreUnknownCharacters)
        else { throw BoardFileError.invalid }
        let source = dir.appendingPathComponent("historical.hrep")
        try raw.write(to: source)
        for exists in [false, true] {
            let profile = dir.appendingPathComponent(exists ? "with-attempt" : "first-launch")
            var oldID: String?
            var currentBytes: Data?
            if exists {
                let live = NativeBoardModel(directory: profile, automaticTimers: false)
                try live.installGame(position(1))
                oldID = live.recorder.document.id
                currentBytes = try Data(contentsOf: live.store.file)
            }
            let workspace = NativeDesktopWorkspace(directory: profile)
            var opened: Bool?
            workspace.start(explicit: source) { opened = $0 }
            let deadline = Date(timeIntervalSinceNow: 5)
            while opened == nil && Date() < deadline { RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01)) }
            let model = workspace.board
            guard opened == true, !model.writable, let replay = model.openedReplay?.document else { throw Failure(description: "explicit replay failed") }
            try check((try? Data(contentsOf: model.store.file)) == currentBytes && (try model.replayLibrary.entries()).isEmpty,
                      "viewing an external replay replaced or archived a game")
            let index = replay.frames.count - 1
            try model.branch(from: replay, at: index)
            let rows = try model.replayLibrary.entries()
            try check(rows.count == (exists ? 2 : 1) && rows.contains { $0.id == NativeReplayLibrary.digest(raw) },
                      "branch archived placeholder or failed to preserve the source")
            if let oldID = oldID {
                guard let old = rows.first(where: { !$0.imported }) else { throw Failure(description: "outgoing attempt missing") }
                try check(try model.replayLibrary.load(old).id == oldID && Data(contentsOf: model.store.backupFile) == currentBytes,
                          "branch lost the actual previous attempt")
            }
            let again = NativeBoardModel(directory: profile, automaticTimers: false)
            try check(try again.progress.current.board == replay.frames[index].board && again.recorder.document.id == model.recorder.document.id &&
                      again.recorder.document.sourceReplayID == replay.id && model.canEdit && Data(contentsOf: source) == raw,
                      "fork not independently restartable or replay original changed")
        }
    }

    private static func unchangedQuit(_ dir: URL) throws {
        let workspace = NativeDesktopWorkspace(directory: dir)
        workspace.start()
        let digits = "534678912672195348198342567859761423426853791713924856961537284287419635345286179"
        var solved = BoardProgress()
        solved.current.board.values = digits.utf8.map { $0 - 48 }
        solved.current.board.candidates = Array(repeating: 0, count: 81)
        try workspace.board.installGame(solved)
        try check(workspace.board.recorder.document.completed, "fixed-clock test puzzle is not solved")
        let url = workspace.board.store.file
        let bytes = try Data(contentsOf: url)
        let held = dir.appendingPathComponent("held-file")
        let fm = FileManager.default
        try fm.moveItem(at: url, to: held)
        try fm.createDirectory(at: url, withIntermediateDirectories: false)
        try check(!workspace.beginQuit(), "clean quit accepted when an unchanged solved game has no durable primary")
        try fm.removeItem(at: url)
        try fm.moveItem(at: held, to: url)
        try check(try workspace.retryQuit() && Data(contentsOf: url) == bytes && !fm.fileExists(atPath: workspace.board.store.backupFile.path),
                  "unchanged quit should verify restored primary without rotating the backup")
    }

    private static func protectedJavaRoot(_ dir: URL) throws {
        let fm = FileManager.default
        let java = dir.appendingPathComponent("Java profile")
        let alias = dir.appendingPathComponent("alias")
        let active = java.appendingPathComponent("last-session.xml")
        let bytes = Data("old Java session".utf8)
        try fm.createDirectory(at: java, withIntermediateDirectories: true)
        try bytes.write(to: active)
        try fm.createSymbolicLink(at: alias, withDestinationURL: java)
        let key = "HODOKU_LEGACY_DATA_DIR"
        let previous = ProcessInfo.processInfo.environment[key]
        setenv(key, java.path, 1)
        defer {
            if let previous = previous { setenv(key, previous, 1) } else { unsetenv(key) }
        }
        let source = NativeBoardStore(directory: dir.appendingPathComponent("Native"))
        do { try NativeBoardStore(directory: dir).save(position(4)); throw Failure(description: "overlapping native parent accepted") }
        catch BoardFileError.unsafeLocation { }
        for root in [java, alias, alias.appendingPathComponent("new/child")] {
            let invalid = NativeBoardStore(directory: root)
            do { try invalid.save(position(4)); throw Failure(description: "configured Java root writable") }
            catch BoardFileError.unsafeLocation { }
            do {
                try source.checkExportLocation(root.appendingPathComponent("copy.hsol"))
                throw Failure(description: "allowed export into custom Java tree")
            } catch BoardFileError.unsafeLocation { }
        }
        try check(try fm.contentsOfDirectory(atPath: java.path) == ["last-session.xml"] && Data(contentsOf: active) == bytes,
                  "custom Java root changed")
    }

    private static func interruptedQuit(_ dir: URL) throws {
        let app = NativeDesktopWorkspace(directory: dir)
        app.start()
        try app.board.installGame(BoardProgress())
        let initial = try Data(contentsOf: app.board.store.file)
        let fm = FileManager.default
        let held = dir.appendingPathComponent("held-primary")
        try fm.moveItem(at: app.board.store.file, to: held)
        try fm.createDirectory(at: app.board.store.file, withIntermediateDirectories: false)
        app.board.select(2)
        app.board.edit(4)
        try check(!app.beginQuit() && app.quitFailure != nil, "unwritable board did not block the clean quit")
        try fm.removeItem(at: app.board.store.file)
        try fm.moveItem(at: held, to: app.board.store.file)
        let checkpoint = try Data(contentsOf: dir.appendingPathComponent("quit-checkpoint.json"))
        let replay = try Data(contentsOf: dir.appendingPathComponent("active-replay.json"))
        let next = NativeDesktopWorkspace(directory: dir)
        next.start()
        try check(next.board.progress.current.board.values[2] == 4 && next.board.progress.boardUndo.count == 1 &&
                  next.board.selected == 2 && next.board.recorder.document == app.board.recorder.document,
                  "restart did not reconcile the independent newer quit replay with its full progress")
        try check(try Data(contentsOf: next.board.store.backupFile) == initial, "crash reconciliation lost the previous intact session")
        try check(try !next.board.recoverInterruptedQuit(checkpoint: checkpoint, replay: replay), "reapplied stale checkpoint")

        let document = next.board.recorder.document
        var staleProgress = next.board.progress
        staleProgress.current.marks = [BoardMark(cell: 1, digit: 0, color: 2)]
        let expected = next.board.store.sessionDigest
        let old = WorkspaceCheckpoint(clean: false, attempt: document.id, frames: document.frames.count,
                                      elapsed: document.elapsedMillis, progress: staleProgress, baseSessionSHA256: expected)
        let current = next.board.progress
        try next.board.addGameSavePoint("later")
        let encoder = JSONEncoder()
        try check(try !next.board.recoverInterruptedQuit(checkpoint: encoder.encode(old), replay: encoder.encode(document)) &&
                  next.board.progress.current == current.current && next.board.progress.extra?.savePoints?.count == 1,
                  "a stale annotation-only checkpoint overwrote changes after cancel")
        var wrong = document
        wrong.frames[0].id = UUID().uuidString
        let mismatch = WorkspaceCheckpoint(clean: false, attempt: wrong.id, frames: wrong.frames.count, elapsed: wrong.elapsedMillis)
        try check(try !next.board.recoverInterruptedQuit(checkpoint: encoder.encode(mismatch), replay: encoder.encode(wrong)),
                  "forked replay prefix accepted")
    }

    private static func atomicSavePoint(_ dir: URL) throws {
        let model = NativeBoardModel(directory: dir, automaticTimers: false)
        let original = BoardProgress()
        try model.installGame(original)
        var wrong = original
        wrong.current.board.values[0] = 1
        do { try model.restoreGameSavePoint(wrong); throw Failure(description: "different givens accepted") }
        catch BoardFileError.invalid { }
        try check(model.progress == original, "different-givens savepoint changed live board")
        model.chooseTool(.ink)
        let file = model.store.file
        let fm = FileManager.default
        let prior = try Data(contentsOf: file)
        try Data([6, 7]).write(to: file, options: .atomic)
        let recorder = model.recorder.document
        do { try model.restoreGameSavePoint(position(4)); throw Failure(description: "savepoint accepted despite CAS conflict") }
        catch BoardFileError.concurrentChange { }
        try check(model.progress == original && model.recorder.document == recorder && model.tool == .ink,
                  "failed savepoint changed board, active tool or replay")
        try prior.write(to: file, options: .atomic)
        try model.restoreGameSavePoint(position(4))
        try check(model.progress.current.board.values[2] == 4 && model.tool == .play && model.recorder.document.frames.count == 2,
                  "retried savepoint did not install committed board and reset tools")
        try check(try NativeBoardStore(directory: dir).load() == model.progress && fm.fileExists(atPath: file.path),
                  "committed savepoint was not restartable")
    }

    private static func normalAndRecovery(_ dir: URL) throws {
        let store = NativeBoardStore(directory: dir)
        let a = position(4), b = position(1), c = position(2)
        try store.save(a)
        let first = try Data(contentsOf: store.file)
        try store.save(b)
        let second = try Data(contentsOf: store.file)
        try check(try Data(contentsOf: store.backupFile) == first, "previous validated bytes promoted to backup")
        let fresh = NativeBoardStore(directory: dir)
        try check(try fresh.load() == b && !fresh.restoredFromBackup, "valid primary precedes backup")
        let broken = Data("{".utf8)
        try broken.write(to: store.file, options: .atomic)
        let recovered = NativeBoardStore(directory: dir)
        try check(try recovered.load() == a && recovered.restoredFromBackup, "corrupt primary falls back")
        try check(try Data(contentsOf: store.file) == broken && Data(contentsOf: store.backupFile) == first, "fallback read is read-only")
        // If a second process repairs either generation, reject even an explicit replacement
        // from a stale window. A reset of the cursor here would lose the other result.
        try second.write(to: store.backupFile, options: .atomic)
        try recovered.prepareExplicitReplacement()
        do { try recovered.save(c); throw Failure(description: "stale backup accepted") }
        catch BoardFileError.concurrentChange {}
        try first.write(to: store.backupFile, options: .atomic)
        try second.write(to: store.file, options: .atomic)
        do { try recovered.save(c); throw Failure(description: "new primary lost") }
        catch BoardFileError.concurrentChange {}
        try broken.write(to: store.file, options: .atomic)
        try recovered.save(c)
        try check(try NativeBoardStore(directory: dir).load() == c && !recovered.restoredFromBackup,
                  "repairs primary and restarts at new progress")
        try check(try Data(contentsOf: store.backupFile) == first, "corrupt primary never promoted")
        let copies = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("board-v3.json.damaged-") }
        try check(copies.count == 1 && (try Data(contentsOf: copies[0])) == broken, "original damaged primary preserved")
        try FileManager.default.removeItem(at: store.file)
        let missing = NativeBoardStore(directory: dir)
        try check(try missing.load() == a && missing.restoredFromBackup, "missing primary also falls back")
        try FileManager.default.createDirectory(at: store.file, withIntermediateDirectories: false)
        let unreadable = NativeBoardStore(directory: dir)
        try check(try unreadable.load() == a && unreadable.restoredFromBackup, "unreadable primary can still display valid backup")
        do { try unreadable.save(c); throw Failure(description: "unreadable primary replaced") }
        catch let e as Failure { throw e } catch {}
        try FileManager.default.removeItem(at: store.file)
        try unreadable.save(c)
        try check(try NativeBoardStore(directory: dir).load() == c, "repairing blocked location permits retry")
    }

    private static func explicitReplacement(_ dir: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = NativeBoardStore(directory: dir)
        let primary = Data([1,2]), backup = Data([3,4]), good = position(4)
        try primary.write(to: store.file)
        try backup.write(to: store.backupFile)
        do { _ = try store.load(); throw Failure(description: "invalid generations auto-opened") }
        catch BoardFileError.invalid {}
        try store.prepareExplicitReplacement()
        try check(try fm.contentsOfDirectory(atPath: dir.path).count == 2, "explicit preflight wrote data")
        try store.save(good)
        let reader = NativeBoardStore(directory: dir)
        try check(try reader.load() == good && !reader.restoredFromBackup, "explicit game owns new primary")
        try check(try Data(contentsOf: reader.backupFile) == backup, "invalid backup kept during explicit replacement")
        try reader.save(position(1))
        let copies = try fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.contains(".damaged-") }
        try check(Set(try copies.map { try Data(contentsOf: $0) }) == Set([primary, backup]), "both damaged generations remain after further saves")
        try check(try NativeBoardStore(directory: dir).load() == position(1), "new game independently editable")
    }

    private static func retry(_ dir: URL) throws {
        let fm = FileManager.default
        let store = NativeBoardStore(directory: dir)
        try store.save(position(4))
        let first = try Data(contentsOf: store.file)
        try fm.createDirectory(at: store.backupFile, withIntermediateDirectories: true)
        do { try store.save(position(2)); throw Failure(description: "blocked backup write accepted") }
        catch let error as Failure { throw error } catch {}
        try check(try Data(contentsOf: store.file) == first, "failed backup write altered primary")
        try fm.removeItem(at: store.backupFile)
        try store.save(position(2))
        try check(try Data(contentsOf: store.backupFile) == first && NativeBoardStore(directory: dir).load() == position(2),
                  "same in-memory store retries and restores")
        let damaged = Data([2, 7])
        try damaged.write(to: store.backupFile, options: .atomic)
        try store.save(position(1))
        let retained = dir.appendingPathComponent(store.backupFile.lastPathComponent + ".damaged-" + NativeReplayLibrary.digest(damaged))
        try check(try Data(contentsOf: retained) == damaged, "corrupt backup lost when rotating a healthy primary")
    }

    private static func protectedFiles(_ dir: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = NativeBoardStore(directory: dir)
        let future = Data("{\"version\":99}".utf8)
        try store.save(position(4))
        let good = try Data(contentsOf: store.file)
        try future.write(to: store.file, options: .atomic)
        try good.write(to: store.backupFile)
        let explicit = NativeBoardStore(directory: dir)
        do { try explicit.prepareExplicitReplacement(); throw Failure(description: "future primary replaced") }
        catch BoardFileError.version {}
        try check(try Data(contentsOf: store.file) == future, "future primary untouched")
        try good.write(to: store.file, options: .atomic)
        try future.write(to: store.backupFile, options: .atomic)
        _ = try explicit.load()
        do { try explicit.save(position(2)); throw Failure(description: "future backup replaced") }
        catch BoardFileError.version {}
        try check(try Data(contentsOf: store.backupFile) == future && Data(contentsOf: store.file) == good, "future backup untouched")
        let target = dir.appendingPathComponent("source.hrep")
        let original = Data([0x48,0x52])
        try original.write(to: target)
        try fm.removeItem(at: store.backupFile)
        try fm.createSymbolicLink(at: store.backupFile, withDestinationURL: target)
        do { try explicit.save(position(2)); throw Failure(description: "backup symlink followed") }
        catch BoardFileError.unsafeLocation {}
        try check(try Data(contentsOf: target) == original && Data(contentsOf: store.file) == good, "symlink target and primary unchanged")
    }
}
