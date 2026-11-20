// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit

enum WorkspaceSharingChecks {
    static func run() throws {
        guard let root = ProcessInfo.processInfo.environment["HODOKU_NATIVE_DATA_DIR"] else {
            throw WorkspaceProblem("Missing private profile")
        }
        let url = URL(fileURLWithPath: root).appendingPathComponent(UUID().uuidString + ".hrep")
        print("Owned local sharing fixture: \(url.path); remove after checks")
        let encoded = try Data(contentsOf: URL(fileURLWithPath: "docs/replay-protocol/fixtures/m2/all-content.hrep.b64"))
        guard let bytes = Data(base64Encoded: encoded, options: .ignoreUnknownCharacters) else {
            throw WorkspaceProblem("Invalid fixture")
        }
        try bytes.write(to: url, options: .withoutOverwriting)
        defer { try? FileManager.default.removeItem(at: url) }
        let host = NSView()
        var enabled = false
        var messages: [String] = []
        var pickers: [NSSharingServicePicker] = []
        var replayShares = 0
        let sharing = WorkspaceSharing(available: { _ in enabled }, present: { chooser, _ in pickers.append(chooser) })
        func show() { sharing.show(url, in: host, onShared: { replayShares += 1 }) { messages.append($0) } }
        show()
        guard pickers.isEmpty, messages.last?.contains(url.path) == true else { throw WorkspaceProblem("No services") }
        enabled = true
        show()
        show()
        guard pickers.count == 1, messages.last?.contains("正在进行") == true else { throw WorkspaceProblem("Concurrent picker") }
        sharing.sharingServicePicker(pickers[0], didChoose: nil)
        show()
        guard pickers.count == 2 else { throw WorkspaceProblem("Cancel did not release file") }
        let service = NSSharingService(title: "Local callback", image: NSImage(), alternateImage: nil, handler: {})
        sharing.sharingServicePicker(pickers[1], didChoose: service)
        sharing.sharingService(service, didFailToShareItems: [url], error: WorkspaceProblem("test failure"))
        guard messages.last?.contains("test failure") == true, messages.last?.contains(url.path) == true else {
            throw WorkspaceProblem("Missing failure recovery")
        }
        show()
        guard pickers.count == 3 else { throw WorkspaceProblem("Failed service blocked retry") }
        sharing.sharingServicePicker(pickers[2], didChoose: service)
        sharing.sharingServicePicker(pickers[0], didChoose: nil)
        show()
        guard pickers.count == 3, replayShares == 0 else { throw WorkspaceProblem("Late picker canceled or confirmed another share") }
        sharing.sharingService(service, didShareItems: [url])
        sharing.sharingService(service, didShareItems: [url])
        show()
        guard pickers.count == 4, replayShares == 1, try Data(contentsOf: url) == bytes else {
            throw WorkspaceProblem("Share changed export or confirmed more than once")
        }
        sharing.sharingServicePicker(pickers[3], didChoose: nil)
        print("PASS AppKit sharing delegate: no services, cancel, occupied picker, failure, retry, late picker, service confirmation and original replay bytes")

        let tempRoot = url.deletingLastPathComponent().appendingPathComponent("board-share-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        let model = NativeBoardModel(directory: tempRoot, loadSaved: false)
        let game = model.progress
        var cues: [NativeOperationSound] = []
        model.mouseOptions.operationSoundsEnabled = true
        model.didPlayOperationSound = { cues.append($0) }
        var staged: URL?
        var boardPicker: NSSharingServicePicker?
        let boardShare = WorkspaceSharing(temporaryRoot: tempRoot, available: { file in
            staged = file
            return enabled
        }, present: { chooser, _ in boardPicker = chooser })
        func share(_ bytes: Data, _ name: String) throws {
            try boardShare.share(bytes, named: name, in: host, onShared: {
                model.playOperationSound(.share)
            }) { messages.append($0) }
        }
        func empty() throws -> Bool { try FileManager.default.contentsOfDirectory(atPath: tempRoot.path).isEmpty }
        for format in NativePuzzleFormat.allCases {
            let data = try NativePuzzleFiles.encode(game, as: format)
            let filename = format.title + "." + format.fileExtension
            try share(data, filename)
            guard let chooser = boardPicker, let file = staged, file.lastPathComponent == filename,
                  try Data(contentsOf: file) == data else { throw WorkspaceProblem("Wrong shared puzzle file: " + filename) }
            let access = try FileManager.default.attributesOfItem(atPath: file.deletingLastPathComponent().path)[.posixPermissions] as? Int
            guard access == 0o700 else { throw WorkspaceProblem("Share temporary directory is not private") }
            try share(data, "Blocked.txt")
            guard staged == file, messages.last == "已有一个分享正在进行。" else { throw WorkspaceProblem("Concurrent board share") }
            boardShare.sharingServicePicker(chooser, didChoose: nil)
            guard try empty() else { throw WorkspaceProblem("Canceled board share left a file") }
        }
        let png = try BoardPainter.png(model.frame)
        enabled = false
        boardPicker = nil
        try share(png, "HoDoKu.png")
        guard boardPicker == nil, messages.last == "系统没有可用的分享服务。", try empty() else {
            throw WorkspaceProblem("Unavailable service left a file")
        }
        enabled = true
        try share(png, "HoDoKu.png")
        guard let picker = boardPicker, let file = staged, file.pathExtension == "png", try Data(contentsOf: file) == png else {
            throw WorkspaceProblem("Wrong shared PNG file")
        }
        boardShare.sharingServicePicker(picker, didChoose: service)
        boardShare.sharingService(service, didFailToShareItems: [file], error: WorkspaceProblem("test failure"))
        guard messages.last == "分享未完成。", cues.isEmpty, try empty() else {
            throw WorkspaceProblem("Failed share left a file or played success")
        }
        try share(png, "HoDoKu.png")
        guard let canceled = boardPicker, let canceledFile = staged else { throw WorkspaceProblem("No picker for cancellation") }
        let messageCount = messages.count
        boardShare.sharingServicePicker(canceled, didChoose: service)
        boardShare.sharingService(service, didFailToShareItems: [canceledFile], error: CocoaError(.userCancelled))
        guard cues.isEmpty, messages.count == messageCount, try empty() else {
            throw WorkspaceProblem("User cancellation did not finish silently")
        }
        try share(png, "HoDoKu.png")
        guard let retry = boardPicker, let retryFile = staged else { throw WorkspaceProblem("Failed share blocked retry") }
        boardShare.sharingServicePicker(retry, didChoose: service)
        boardShare.sharingService(service, didShareItems: [retryFile])
        guard try empty(), game == model.progress, cues == [.share] else {
            throw WorkspaceProblem("Successful share changed progress, left a file or missed its sound")
        }
        print("PASS board sharing: nine exact puzzle formats and PNG, private files, cancellation, failure, retry, success cue and cleanup")
    }
}
