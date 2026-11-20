// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import Combine

/// AppKit owns presentation, overflow, and the user's saved item order.
/// The board and workspace remain the owners of the actions and their state.
@MainActor
final class BoardWindowToolbar: NSObject, NSToolbarDelegate, NSToolbarItemValidation {
    enum Command: String, CaseIterable {
        case newGame = "native-new", open = "native-open"
        case undo = "native-undo", redo = "native-redo"
        case hint = "native-hint-open", count = "native-count", replays = "native-replays"

        case analyze = "native-analysis", reasoning = "native-current-reasoning"
        case path = "native-solution-path", techniques = "native-techniques"
        case share = "native-share-board", save = "native-save"
        case history = "native-puzzle-history", freeze = "native-freeze-board", summary = "native-solve-summary"

        var identifier: NSToolbarItem.Identifier { .init(rawValue) }
        var title: String {
            switch self {
            case .newGame: return "新题"
            case .open: return "打开"
            case .undo: return "撤销"
            case .redo: return "重做"
            case .hint: return "提示"
            case .count: return "检查解数"
            case .replays: return "回放"
            case .analyze: return "分析当前线索"
            case .reasoning: return "当前思路"
            case .path: return "解题路径"
            case .techniques: return "选择技巧"
            case .share: return "分享棋盘"
            case .save: return "保存"
            case .history: return "题目历史"
            case .freeze: return "冻结画面"
            case .summary: return "解题摘要"
            }
        }
        var shortcut: String? {
            switch self {
            case .analyze: return "~"
            case .reasoning: return "Tab"
            case .path: return "⇧⌘O"
            case .techniques: return "⇧⌘A"
            case .save: return "⌘S"
            case .summary: return "⇧⌘U"
            default: return nil
            }
        }

        func toolTip(_ title: String) -> String {
            shortcut.map { "\(title) (\($0))" } ?? title
        }

        var symbol: String {
            switch self {
            case .newGame: return "plus"
            case .open: return "folder"
            case .undo: return "arrow.uturn.backward"
            case .redo: return "arrow.uturn.forward"
            case .hint: return "lightbulb"
            case .count: return "number"
            case .replays: return "play.rectangle"
            case .analyze: return "magnifyingglass"
            case .reasoning: return "scope"
            case .path: return "point.topleft.down.to.point.bottomright.curvepath"
            case .techniques: return "list.bullet"
            case .share: return "square.and.arrow.up"
            case .save: return "square.and.arrow.down"
            case .history: return "clock.arrow.circlepath"
            case .freeze: return "pause.circle"
            case .summary: return "chart.bar"
            }
        }

        func image(label: String) -> NSImage? {
            guard self == .path else { return NSImage(systemSymbolName: symbol, accessibilityDescription: label) }
            let image = NSImage(size: NSSize(width: 20, height: 20), flipped: true) { _ in
                NSColor.labelColor.set()
                let route = NSBezierPath()
                route.move(to: NSPoint(x: 4, y: 14))
                route.curve(to: NSPoint(x: 11.8, y: 6), controlPoint1: NSPoint(x: 4, y: 8),
                            controlPoint2: NSPoint(x: 7, y: 6))
                route.lineWidth = 1.5
                route.lineCapStyle = .round
                route.stroke()
                NSBezierPath(ovalIn: NSRect(x: 2.3, y: 13.5, width: 3.4, height: 3.4)).fill()
                let target = NSBezierPath(ovalIn: NSRect(x: 11.8, y: 2.6, width: 6.8, height: 6.8))
                target.lineWidth = 1.5
                target.stroke()
                NSBezierPath(ovalIn: NSRect(x: 14.3, y: 5.1, width: 1.8, height: 1.8)).fill()
                return true
            }
            image.isTemplate = true
            image.accessibilityDescription = label
            return image
        }
    }

    static let toolsID = NSToolbarItem.Identifier("native-board-tools")
    private let toolbar = NSToolbar(identifier: "HoDoKu.BoardToolbar")
    private weak var window: NSWindow?
    private let workspace: NativeDesktopWorkspace
    private var board: NativeBoardModel { workspace.board }
    private let perform: (Command) -> Void
    private var changes: AnyCancellable?
    private var refreshPending = false

    init(window: NSWindow, workspace: NativeDesktopWorkspace, perform: @escaping (Command) -> Void) {
        self.window = window
        self.workspace = workspace
        self.perform = perform
        super.init()
        toolbar.delegate = self
        toolbar.allowsUserCustomization = true
        toolbar.autosavesConfiguration = true
        if #available(macOS 13, *) { toolbar.centeredItemIdentifiers = [Self.toolsID] }
        else { toolbar.centeredItemIdentifier = Self.toolsID }
        window.titleVisibility = .hidden
        window.toolbarStyle = .unified
        window.toolbar = toolbar
        changes = workspace.objectWillChange.merge(with: board.objectWillChange).sink { [weak self] in
            guard let self = self, !self.refreshPending else { return }
            self.refreshPending = true
            DispatchQueue.main.async { [weak self] in
                self?.refreshPending = false
                self?.synchronizeItems()
            }
        }
        synchronizeItems()
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Command.newGame.identifier, Command.open.identifier, .flexibleSpace, Self.toolsID,
         .flexibleSpace, Command.undo.identifier, Command.redo.identifier, .space, Command.hint.identifier,
         Command.count.identifier, Command.replays.identifier]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        Command.allCases.map(\.identifier) + [Self.toolsID, .space, .flexibleSpace]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        if id == Self.toolsID {
            let tools = BoardTool.allCases
            let labels = tools.map { board.generalOptions.localized($0.title) }
            let group = NSToolbarItemGroup(itemIdentifier: id, images: tools.map(toolImage), selectionMode: .selectOne,
                                           labels: labels, target: self, action: #selector(chooseTool(_:)))
            group.label = board.generalOptions.localized("棋盘工具")
            group.paletteLabel = group.label
            group.controlRepresentation = .automatic
            group.visibilityPriority = .high
            group.selectedIndex = tools.firstIndex(of: board.tool) ?? 0
            for (item, label) in zip(group.subitems, labels) { item.toolTip = label }
            return group
        }
        guard let command = Command(rawValue: id.rawValue) else { return nil }
        let item = NSToolbarItem(itemIdentifier: id)
        item.label = board.generalOptions.localized(command.title)
        item.paletteLabel = item.label
        item.toolTip = command.toolTip(item.label)
        item.image = command.image(label: item.label)
        item.target = self
        item.action = #selector(invoke(_:))
        if command == .hint { item.visibilityPriority = .high }
        if command == .count || command == .replays { item.visibilityPriority = .low }
        return item
    }

    private func toolImage(_ tool: BoardTool) -> NSImage {
        let symbol: String
        switch tool {
        case .play: symbol = "number.square"
        case .color: symbol = "paintpalette"
        case .ink: symbol = "pencil.tip"
        case .chain: symbol = "link"
        case .boxes: symbol = "viewfinder"
        }
        return NSImage(systemSymbolName: symbol, accessibilityDescription: board.generalOptions.localized(tool.title))
            ?? NSImage(named: NSImage.actionTemplateName)!
    }

    private var commandsAvailable: Bool {
        window?.attachedSheet == nil && !toolbar.customizationPaletteIsRunning
            && !workspace.commandDialogOpen && !workspace.opening && !workspace.generating && workspace.quitFailure == nil
    }

    private var boardAvailable: Bool {
        commandsAvailable && board.canEdit
            && (window?.firstResponder as? NSTextView)?.isEditable != true
    }

    private func enabled(_ command: Command) -> Bool {
        guard commandsAvailable else { return false }
        switch command {
        case .open: return true
        case .newGame: return !board.reviewing
        case .hint, .analyze, .reasoning, .path, .techniques: return boardAvailable && board.frozen == nil
        case .undo: return boardAvailable && board.canUndo
        case .redo: return boardAvailable && board.canRedo
        case .count, .replays, .share, .save, .summary, .freeze: return boardAvailable
        case .history: return !board.reviewing
        }
    }

    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        if item.itemIdentifier == Self.toolsID || (item.target === self && item.action == #selector(chooseTool(_:))) {
            return boardAvailable && board.frozen == nil
        }
        return Command(rawValue: item.itemIdentifier.rawValue).map(enabled) ?? false
    }

    private func synchronizeItems() {
        for item in toolbar.items {
            if let command = Command(rawValue: item.itemIdentifier.rawValue) {
                let label = board.generalOptions.localized(command.title)
                if item.label != label {
                    item.label = label
                    item.paletteLabel = label
                    item.toolTip = command.toolTip(label)
                    item.image = command.image(label: label)
                }
            }
            if let group = item as? NSToolbarItemGroup, item.itemIdentifier == Self.toolsID {
                group.label = board.generalOptions.localized("棋盘工具")
                group.paletteLabel = group.label
                for (tool, subitem) in zip(BoardTool.allCases, group.subitems) {
                    let label = board.generalOptions.localized(tool.title)
                    if subitem.label != label { subitem.label = label; subitem.toolTip = label }
                }
                if let active = BoardTool.allCases.firstIndex(of: board.tool), group.selectedIndex != active {
                    group.selectedIndex = active
                }
            } else if item.itemIdentifier == Command.hint.identifier {
                let open = !board.choosingTechnique && board.isHintDrawerAvailable && !board.hintDrawerCollapsed
                let description = board.generalOptions.localized(open ? "关闭提示" : "打开提示")
                if item.toolTip != description {
                    item.toolTip = description
                    item.image = NSImage(systemSymbolName: open ? "lightbulb.fill" : Command.hint.symbol,
                                         accessibilityDescription: description)
                }
            }
        }
        toolbar.validateVisibleItems()
    }

    @objc private func invoke(_ item: NSToolbarItem) {
        guard let command = Command(rawValue: item.itemIdentifier.rawValue), enabled(command) else { return }
        perform(command)
    }

    @objc private func chooseTool(_ group: NSToolbarItemGroup) {
        guard boardAvailable, board.frozen == nil, BoardTool.allCases.indices.contains(group.selectedIndex) else { return }
        board.chooseTool(BoardTool.allCases[group.selectedIndex])
    }
}
