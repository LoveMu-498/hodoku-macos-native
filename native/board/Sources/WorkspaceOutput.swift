// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit

final class WorkspacePrintView: NSView {
    private let paint: (CGContext, CGRect) -> Void
    override var isFlipped: Bool { true }
    init(board: BoardFrame, title: String = "HoDoKu", rating: String? = nil) {
        var printedBoard = board
        printedBoard.colorMode = .print
        let header = board.visual.fonts["bigFont"]!.resolve()
        let caption = board.visual.fonts["smallFont"]!.resolve()
        let titleAttributes: [NSAttributedString.Key: Any] = [.font: header, .foregroundColor: NSColor.black]
        let ratingAttributes: [NSAttributedString.Key: Any] = [.font: caption, .foregroundColor: NSColor.black]
        let heading = title as NSString
        let headingSize = heading.size(withAttributes: titleAttributes)
        let ratingHeight = rating.map { ($0 as NSString).size(withAttributes: ratingAttributes).height } ?? 0
        let boardY = ceil(headingSize.height + ratingHeight) + 12
        paint = { cg, rect in
            let labelFrame = CGRect(x: 10, y: 0, width: rect.width - 20, height: headingSize.height)
            heading.draw(with: labelFrame, options: [.truncatesLastVisibleLine], attributes: titleAttributes)
            if let rating = rating {
                (rating as NSString).draw(at: CGPoint(x: 10, y: headingSize.height + 2), withAttributes: ratingAttributes)
            }
            let area = CGRect(x: rect.minX, y: rect.minY + boardY, width: rect.width, height: rect.height - boardY)
            BoardPainter.draw(printedBoard, drag: nil, in: cg, bounds: area)
        }
        super.init(frame: CGRect(x: 0, y: 0, width: 600, height: 600 + boardY))
    }
    init(replay: NativeReplayFrame) {
        paint = { cg, rect in ReplayExchangePainter.draw(replay, in: rect, context: cg) }
        super.init(frame: CGRect(x: 0, y: 0, width: 600, height: 600))
    }
    required init?(coder: NSCoder) { return nil }
    override func draw(_ dirtyRect: NSRect) {
        if let cg = NSGraphicsContext.current?.cgContext { paint(cg, bounds) }
    }
    func printPage(_ window: NSWindow) {
        let info = NSPrintInfo.shared.copy() as! NSPrintInfo
        info.horizontalPagination = .fit
        info.verticalPagination = .fit
        info.isHorizontallyCentered = true
        let operation = NSPrintOperation(view: self, printInfo: info)
        operation.jobTitle = "HoDoKu 棋盘"
        operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
    }
}

/// Keeps the selected file available until the system service finishes.
final class WorkspaceSharing: NSObject, NSSharingServicePickerDelegate, NSSharingServiceDelegate {
    static let shared = WorkspaceSharing()
    private var picker: NSSharingServicePicker?
    private var service: NSSharingService?
    private var file: URL?
    private var temporaryFolder: URL?
    private var report: ((String) -> Void)?
    private var onShared: (() -> Void)?

    private let temporaryRoot: URL
    private let available: (URL) -> Bool
    private let present: (NSSharingServicePicker, NSView) -> Void

    init(temporaryRoot: URL = FileManager.default.temporaryDirectory,
         available: @escaping (URL) -> Bool = { !NSSharingService.sharingServices(forItems: [$0]).isEmpty },
         present: @escaping (NSSharingServicePicker, NSView) -> Void = { chooser, view in
             let anchor = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1)
             chooser.show(relativeTo: anchor, of: view, preferredEdge: .maxY)
         }) {
        self.temporaryRoot = temporaryRoot
        self.available = available
        self.present = present
    }

    func show(_ url: URL, in view: NSView, onShared: (() -> Void)? = nil, report: @escaping (String) -> Void) {
        guard file == nil else { report("已有一个分享正在进行。文件已保存到 " + url.path); return }
        guard available(url) else {
            report("系统没有可用的分享服务。文件已保存到 " + url.path)
            return
        }
        open(url, temporaryFolder: nil, in: view, onShared: onShared, report: report)
    }

    func share(_ data: Data, named filename: String, in view: NSView, topPoint: NSPoint? = nil,
               onShared: (() -> Void)? = nil, report: @escaping (String) -> Void) throws {
        guard file == nil else { report("已有一个分享正在进行。"); return }
        let folder = temporaryRoot.appendingPathComponent("HoDoKu Share " + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        let safeName = filename.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        let url = folder.appendingPathComponent(safeName, isDirectory: false)
        var opened = false
        defer { if !opened { discard(folder) } }
        try data.write(to: url, options: .withoutOverwriting)
        guard available(url) else { report("系统没有可用的分享服务。"); return }
        opened = true
        open(url, temporaryFolder: folder, in: view, topPoint: topPoint, onShared: onShared, report: report)
    }

    private func open(_ url: URL, temporaryFolder: URL?, in view: NSView, topPoint: NSPoint? = nil,
                      onShared: (() -> Void)?, report: @escaping (String) -> Void) {
        file = url
        self.temporaryFolder = temporaryFolder
        self.report = report
        self.onShared = onShared
        let chooser = NSSharingServicePicker(items: [url])
        picker = chooser
        chooser.delegate = self
        if let topPoint {
            let anchor = CGRect(origin: topPoint, size: CGSize(width: 1, height: 1))
            chooser.show(relativeTo: anchor, of: view, preferredEdge: view.isFlipped ? .maxY : .minY)
        } else {
            present(chooser, view)
        }
    }
    func sharingServicePicker(_ sharingServicePicker: NSSharingServicePicker, didChoose service: NSSharingService?) {
        guard sharingServicePicker === picker else { return }
        if let service = service { self.service = service } else { finish() }
    }
    func sharingServicePicker(_ sharingServicePicker: NSSharingServicePicker, delegateFor sharingService: NSSharingService) -> NSSharingServiceDelegate? { sharingServicePicker === picker ? self : nil }
    func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) {
        guard service === sharingService else { return }
        let completed = onShared
        finish()
        completed?()
    }
    func sharingService(_ sharingService: NSSharingService, didFailToShareItems items: [Any], error: Error) {
        guard service === sharingService else { return }
        let reason = error as NSError
        if reason.domain == NSCocoaErrorDomain && reason.code == NSUserCancelledError {
            finish()
            return
        }
        let notify = report
        let message: String
        if temporaryFolder == nil, let file {
            message = "分享未完成。文件已保存到 " + file.path + "。" + error.localizedDescription
        } else { message = "分享未完成。" }
        finish()
        notify?(message)
    }
    private func finish() {
        if let folder = temporaryFolder { discard(folder) }
        temporaryFolder = nil
        service = nil
        picker = nil
        file = nil
        report = nil
        onShared = nil
    }
    private func discard(_ folder: URL) { try? FileManager.default.removeItem(at: folder) }
}
