// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import SwiftUI

enum NativeBoardExport: Equatable {
    case puzzle(NativePuzzleFormat)
    case png
}

struct NativeBoardShareMenu: View {
    let model: NativeBoardModel
    let save: ((NativeBoardExport) -> Void)?
    @StateObject private var anchor = Anchor()

    var body: some View {
        Button(action: showFormats) {
            Image(systemName: "square.and.arrow.up")
                .frame(width: 23, height: 25)
                .accessibilityHidden(true)
        }
        .fixedSize()
        .accessibilityLabel("分享棋盘")
        .accessibilityIdentifier("native-board-share")
        .help("选择格式以共享，按住 Option 选择以存储文件")
        .background(AnchorView(anchor: anchor).allowsHitTesting(false).accessibilityHidden(true))
    }

    private func showFormats() {
        guard let view = anchor.view else { return }
        Self.showFormats(model: model, in: view, topPoint: nil, save: save)
    }

    static func showFromTop(model: NativeBoardModel, in view: NSView, save: @escaping (NativeBoardExport) -> Void) {
        let top = view.isFlipped ? view.bounds.minY : view.bounds.maxY
        let event = NSApp.currentEvent
        let x: CGFloat
        if let event, event.window === view.window,
           [.leftMouseUp, .leftMouseDown].contains(event.type) {
            x = view.convert(event.locationInWindow, from: nil).x
        } else {
            x = view.bounds.maxX - 16
        }
        let point = NSPoint(x: min(max(view.bounds.minX, x), view.bounds.maxX), y: top)
        showFormats(model: model, in: view, topPoint: point, save: save)
    }

    private static func showFormats(model: NativeBoardModel, in view: NSView, topPoint: NSPoint?,
                                    save: ((NativeBoardExport) -> Void)?) {
        guard model.canEdit, view.window != nil else { return }
        let formats = Formats(options: model.generalOptions, canSave: save != nil)
        let modifiers = NSApp.currentEvent?.modifierFlags ?? NSEvent.modifierFlags
        let alternate = save != nil && modifiers.contains(.option)
        if let topPoint {
            let firstRow = formats.menu.items.first { $0.isAlternate == alternate }
            let origin = NSPoint(x: max(view.bounds.minX, topPoint.x - formats.menu.size.width), y: topPoint.y)
            formats.menu.popUp(positioning: firstRow, at: origin, in: view)
        } else {
            let lastRow = formats.menu.items.last { $0.isAlternate == alternate }
            // Align the bottom row above the status bar.
            let origin = NSPoint(x: view.bounds.maxX - formats.menu.size.width, y: view.bounds.maxY + 48)
            formats.menu.popUp(positioning: lastRow, at: origin, in: view)
        }
        if let selection = formats.selection {
            select(selection.export, model: model, in: view, topPoint: topPoint,
                   saveToFile: selection.saveToFile ? save : nil)
        }
    }

    func select(_ item: NativeBoardExport, saveToFile: Bool) {
        Self.select(item, model: model, in: anchor.view, topPoint: nil, saveToFile: saveToFile ? save : nil)
    }

    private static func select(_ item: NativeBoardExport, model: NativeBoardModel, in view: NSView?,
                               topPoint: NSPoint?, saveToFile: ((NativeBoardExport) -> Void)?) {
        DispatchQueue.main.async { [weak view] in
            guard model.canEdit else { return }
            if let saveToFile {
                saveToFile(item)
                return
            }
            guard let view, view.window != nil else { return }
            do {
                let bytes: Data, name: String
                switch item {
                case .puzzle(let format):
                    bytes = try NativePuzzleFiles.encode(model.progress, as: format, step: model.reading,
                                                         useZero: model.solverConfig.useZero)
                    name = model.generalOptions.localized(format.title) + "." + format.fileExtension
                case .png:
                    bytes = try BoardPainter.png(model.frame)
                    name = "HoDoKu.png"
                }
                try WorkspaceSharing.shared.share(bytes, named: name, in: view, topPoint: topPoint, onShared: { [weak model = model] in
                    model?.playOperationSound(.share)
                }) { message in
                    model.showOperationFeedback(model.generalOptions.localized(message), sound: .failure)
                }
            } catch {
                model.showOperationFeedback(model.generalOptions.localized(error.localizedDescription), sound: .failure)
            }
        }
    }

    final class Formats: NSObject {
        let menu = NSMenu()
        private(set) var selection: (export: NativeBoardExport, saveToFile: Bool)?

        init(options: NativeGeneralOptions, canSave: Bool) {
            super.init()
            menu.identifier = NSUserInterfaceItemIdentifier("native-board-share-menu")
            menu.autoenablesItems = false
            for format in NativePuzzleFormat.allCases {
                add(.puzzle(format), title: options.localized(format.title + "…"), id: format.rawValue, canSave: canSave)
            }
            menu.addItem(.separator())
            add(.png, title: options.localized("棋盘图片（PNG）…"), id: "png", canSave: canSave)
        }

        private func add(_ export: NativeBoardExport, title: String, id: String, canSave: Bool) {
            func item(title: String, saveToFile: Bool) -> NSMenuItem {
                let item = NSMenuItem(title: title, action: #selector(choose(_:)), keyEquivalent: "")
                item.identifier = NSUserInterfaceItemIdentifier("native-board-share-" + id)
                item.target = self
                item.representedObject = export
                item.keyEquivalentModifierMask = saveToFile ? .option : []
                item.isAlternate = saveToFile
                return item
            }
            menu.addItem(item(title: title, saveToFile: false))
            if canSave {
                let fileTitle = title.hasSuffix("…") ? String(title.dropLast()).trimmingCharacters(in: .whitespaces) : title
                menu.addItem(item(title: fileTitle, saveToFile: true))
            }
        }

        @objc private func choose(_ item: NSMenuItem) {
            guard let export = item.representedObject as? NativeBoardExport else { return }
            selection = (export, item.isAlternate)
        }
    }

    private final class Anchor: ObservableObject {
        weak var view: NSView?
    }

    private struct AnchorView: NSViewRepresentable {
        let anchor: Anchor
        func makeNSView(context: Context) -> NSView {
            let view = NSView()
            anchor.view = view
            return view
        }
        func updateNSView(_ view: NSView, context: Context) {}
    }
}
