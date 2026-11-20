// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import Combine
import SwiftUI

private struct Workbench: View {
    @ObservedObject var workspace: NativeDesktopWorkspace
    @ObservedObject var board: NativeBoardModel
    @ObservedObject var counter: SolutionCounter
    let chooseFile: () -> Void
    let newGame: () -> Void
    let saveExport: (NativeBoardExport) -> Void
    let hintWindow: NativeHintWindowController

    private var loading: BoardLoad? {
        if workspace.generating { return .generating }
        if workspace.opening { return .opening }
        return nil
    }
    private var modalOpen: Bool { workspace.quitFailure != nil || workspace.commandDialogOpen }

    var body: some View {
        VStack(spacing: 0) {
            if !board.writable && !board.reviewing && loading == nil {
                VStack(spacing: 12) {
                    HStack {
                        Button("新题", action: newGame)
                        Button("打开文件…", action: chooseFile)
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                CandidateBoardView(model: board, boardChanged: { _ in
                    counter.invalidate()
                    workspace.didEditBoard()
                }, cancelSolutionCount: counter.isSearching ? counter.cancel : nil,
                   showOperationToast: !modalOpen && loading == nil, loadingPuzzle: loading != nil, saveExport: saveExport,
                   hintWindow: hintWindow)
                    .disabled(loading != nil)
                    .allowsHitTesting(loading == nil)
                    .accessibilityHidden(loading != nil)
            }
            if let message = workspace.message, loading == nil {
                Divider()
                HStack {
                    Text(message)
                    Spacer()
                    if workspace.canRetryOpen { Button("重试打开", action: workspace.retryOpening) }
                    Button("关闭") { workspace.notice(nil) }
                }.padding(8)
            }
        }
        .disabled(modalOpen)
        .accessibilityHidden(modalOpen)
        .overlay(Group {
            if !modalOpen, let loading {
                BoardLoadFeedback(load: loading, options: board.generalOptions,
                                  cancel: loading == .generating ? workspace.cancelNewGame : workspace.cancelOpening)
                    .id(loading).padding(12)
            } else if !modalOpen, !board.writable && !board.reviewing, let message = board.operationMessage {
                NativeOperationToast(message: message, tone: board.operationMessageTone, identifier: board.operationMessageID)
                    .frame(maxWidth: 440, alignment: .trailing)
                    .padding(12).allowsHitTesting(false)
            }
        }, alignment: .topTrailing)
        .overlay(Group { if modalOpen { WorkspaceModalBackdrop() } })
        .environment(\.locale, board.generalOptions.locale)
        .font(board.generalOptions.useDefaultFontSize ? .body : .system(size: CGFloat(board.generalOptions.customFontSize)))
        .onChange(of: board.reviewing, perform: workspace.reviewingChanged)
        .onReceive(counter.$message) { message in
            if message == nil || counter.isSearching { board.clearOperationMessage(identifier: "solution-count-result") }
        }
        .onReceive(workspace.$preferences) { prefs in
            NSApp.appearance = prefs.appearance == "LIGHT" ? NSAppearance(named: .aqua)
                : prefs.appearance == "DARK" ? NSAppearance(named: .darkAqua) : nil
        }
    }
}

private enum BoardLoad: Hashable {
    case generating, opening

    var message: String { self == .generating ? "正在生成新题" : "正在打开文件" }
}

private struct BoardLoadFeedback: View {
    let load: BoardLoad
    let options: NativeGeneralOptions
    let cancel: () -> Void
    @State private var pending: DispatchWorkItem?
    @State private var visible = false

    var body: some View {
        Group {
            if visible {
                NativeOperationToast(message: options.localized(load.message), tone: .neutral,
                                     identifier: "native-board-loading", cancel: cancel)
            } else {
                Color.clear.frame(width: 1, height: 1)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text(verbatim: options.localized(load.message)))
                    .allowsHitTesting(false)
            }
        }
        .onAppear {
            let task = DispatchWorkItem { visible = true }
            pending = task
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: task)
        }
        .onDisappear {
            pending?.cancel()
            pending = nil
        }
    }
}

final class CandidateDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuItemValidation {
    let workspace = NativeDesktopWorkspace()
    private var board: NativeBoardModel { workspace.board }
    private let counter = SolutionCounter()
    private var window: NSWindow?
    private var boardToolbar: BoardWindowToolbar?
    private var menuLanguage: AnyCancellable?
    private var outsideFullScreen: NSRect?
    private let hintWindow = NativeHintWindowController()
    func windowWillEnterFullScreen(_ notification: Notification) { outsideFullScreen = window?.frame }
    func windowDidExitFullScreen(_ notification: Notification) {
        outsideFullScreen = nil
        hintWindow.scheduleExpansion()
    }
    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        guard outsideFullScreen == nil else { return frameSize }
        return hintWindow.constrainedSize(frameSize, for: sender)
    }
    func windowDidResize(_ notification: Notification) { hintWindow.scheduleExpansion() }
    func windowDidEndLiveResize(_ notification: Notification) { hintWindow.scheduleExpansion() }
    func windowDidChangeScreen(_ notification: Notification) { hintWindow.scheduleExpansion() }
    func windowDidEndSheet(_ notification: Notification) { hintWindow.scheduleExpansion() }
    private var queuedOpen: (URL, (Bool) -> Void)?
    private var waitingForQuit = false
    private var solving = false
    private var quitPanel: QuitFailurePanel?
    private var commandDialog: NSPanel?
    private weak var responderBeforeQuit: NSResponder?
    private let fileTypes = ["xml","bak","hsol","txt","ss","hrep","hdkreplay","hodoku-settings"]
    private var namedFile: (id: String, url: URL, format: NativePuzzleFormat, bytes: Data)?

    func applicationDidFinishLaunching(_ notification: Notification) {
        counter.didFinish = { [weak self] in self?.showCountResult($0) }
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(self, selector: #selector(sleeping), name: NSWorkspace.willSleepNotification, object: nil)
        center.addObserver(self, selector: #selector(awake), name: NSWorkspace.didWakeNotification, object: nil)
        menuLanguage = workspace.$preferences.map { $0.general?.language ?? "" }.removeDuplicates().sink { [weak self] language in
            self?.buildMenus(language: language)
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 740),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        self.window = window
        hintWindow.window = window
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.title = "HoDoKu 原生试用版"
        window.contentMinSize = NSSize(width: 480, height: 480)
        window.contentView = NSHostingView(rootView: Workbench(workspace: workspace, board: board, counter: counter,
                                                               chooseFile: { [weak self] in self?.chooseFile() },
                                                               newGame: { [weak self] in self?.newGame() },
                                                               saveExport: { [weak self] in self?.saveExport($0) },
                                                               hintWindow: hintWindow))
        boardToolbar = BoardWindowToolbar(window: window, workspace: workspace) { [weak self] command in
            self?.performToolbarCommand(command)
        }
        var args: [String] = []
        var tokens = CommandLine.arguments.dropFirst().makeIterator()
        while let token = tokens.next() {
            if token.hasPrefix("-psn_") { continue }
            if token.hasPrefix("-NS") || token.hasPrefix("-Apple") { _ = tokens.next(); continue }
            args.append(token)
        }
        if let queued = queuedOpen {
            queuedOpen = nil
            workspace.start(explicit: queued.0, finished: queued.1)
        } else if args.count > 1 {
            workspace.start(rejectedBatch: true)
        } else { workspace.start(explicit: args.first.map { URL(fileURLWithPath: $0) }) }
        let layoutFile = WorkspaceFile("window-layout-v1.json", store: board.store)
        let layout = (try? layoutFile.read()).flatMap { try? JSONDecoder().decode(NativeWindowLayout.self, from: $0) }
        workspace.saveWindowLayout = { [weak self, weak window] in
            guard let window else { return }
            try layoutFile.write(NativeWindowLayout(window: window, normalFrame: self?.outsideFullScreen))
        }
        if let id = ProcessInfo.processInfo.environment["HODOKU_NATIVE_TEST_DISPLAY_ID"] {
            guard let screen = NSScreen.screens.first(where: {
                ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.stringValue == id
            }) else { NSApp.terminate(nil); return }
            let area = screen.visibleFrame
            let size = NSSize(width: min(window.frame.width, area.width), height: min(window.frame.height, area.height))
            window.setFrame(NSRect(x: area.midX - size.width / 2, y: area.midY - size.height / 2, width: size.width, height: size.height), display: false)
            window.orderFront(nil)
        } else {
            if let saved = layout, board.generalOptions.saveWindowLayout {
                window.setFrame(saved.visibleFrame(for: window), display: false)
                window.toolbar?.isVisible = saved.toolbarVisible
            } else { window.center() }
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            if board.generalOptions.saveWindowLayout && layout?.fullScreen == true { window.toggleFullScreen(nil) }
        }

    }

    func showCountResult(_ outcome: CountOutcome) {
        let id = "solution-count-result", message = board.generalOptions.localized(outcome.message)
        switch outcome {
        case .invalid: board.showOperationFeedback(message, sound: .unavailable, identifier: id)
        case .engineFailure: board.showOperationFeedback(message, sound: .failure, identifier: id)
        case .exhausted(0): board.showOperationFeedback(message, sound: .noResults, identifier: id)
        default: board.showOperationMessage(message, identifier: id)
        }
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        guard filenames.count == 1, let path = filenames.first, !waitingForQuit else { sender.reply(toOpenOrPrint: .failure); return }
        let url = URL(fileURLWithPath: path)
        guard window?.attachedSheet == nil else { sender.reply(toOpenOrPrint: .failure); return }
        let reply: (Bool) -> Void = { sender.reply(toOpenOrPrint: $0 ? .success : .failure) }
        if window == nil {
            queuedOpen?.1(false)
            queuedOpen = (url, reply)
        } else { open(url, finished: reply) }
    }

    private func open(_ url: URL, finished: @escaping (Bool) -> Void = { _ in }) {
        workspace.open(url) { [weak self] ok in
            if ok { self?.counter.invalidate() }
            finished(ok)
        }
    }

    func buildMenus(language: String? = nil) {
        var options = board.generalOptions
        if let language { options.language = language }
        let local = options.localized
        let bar = NSMenu()
        func menu(_ name: String, in parent: NSMenu) -> NSMenu {
            let item = NSMenuItem()
            item.title = local(name)
            parent.addItem(item)
            let group = NSMenu(title: local(name))
            item.submenu = group
            return group
        }
        @discardableResult func item(_ group: NSMenu, _ title: String, _ action: Selector, _ key: String = "", modifiers: NSEvent.ModifierFlags = .command, target: AnyObject? = nil) -> NSMenuItem {
            let i = group.addItem(withTitle: local(title), action: action, keyEquivalent: key)
            i.keyEquivalentModifierMask = modifiers
            i.target = target
            return i
        }
        let app = menu("HoDoKu", in: bar)
        item(app, "关于 HoDoKu", #selector(NSApplication.orderFrontStandardAboutPanel(_:)))
        app.addItem(.separator())
        item(app, "设置…", #selector(settings), ",", target: self)
        let preferencesFiles = menu("设置文件", in: app)
        item(preferencesFiles, "打开设置文件…", #selector(openPreferences), target: self)
        item(preferencesFiles, "导出原生设置…", #selector(exportSettings), target: self)
        item(app, MenuOption.sounds.rawValue, #selector(toggleOption(_:)), target: self).representedObject = MenuOption.sounds.rawValue
        app.addItem(.separator())
        item(app, "隐藏 HoDoKu", #selector(NSApplication.hide(_:)), "h")
        item(app, "退出 HoDoKu", #selector(NSApplication.terminate(_:)), "q")

        let file = menu("文件", in: bar)
        item(file, "新题", #selector(newGame), "n", target: self)
        item(file, "新建空白题", #selector(newBlank), "n", modifiers: [.command,.option], target: self)
        item(file, "打开…", #selector(chooseFile), "o", target: self)
        item(file, "导入题目字符串…", #selector(importLine), "i", target: self)
        item(file, "从剪贴板开题", #selector(pastePuzzle), target: self)
        file.addItem(.separator())
        item(file, "关闭窗口", #selector(NSWindow.performClose(_:)), "w")
        item(file, "保存", #selector(save), "s", target: self)
        item(file, "题目另存为…", #selector(savePuzzleAs), "s", modifiers: [.command,.shift], target: self)
        item(file, "导出题目字符串…", #selector(exportLine), "e", target: self)
        item(file, "分享棋盘…", #selector(shareBoard), target: self)
        file.addItem(.separator())
        item(file, "页面设置…", #selector(pageSetup), target: self)
        item(file, "打印棋盘…", #selector(printBoard), "p", target: self)

        let edit = menu("编辑", in: bar)
        item(edit, "撤销", Selector(("undo:")), "z")
        item(edit, "重做", Selector(("redo:")), "z", modifiers: [.command,.shift])
        item(edit, "重做棋盘操作", #selector(redoBoard), "y", target: self)
        edit.addItem(.separator())
        item(edit, "剪切", #selector(NSText.cut(_:)), "x")
        item(edit, "复制", #selector(NSText.copy(_:)), "c")
        item(edit, "粘贴", #selector(NSText.paste(_:)), "v")
        item(edit, "全选", #selector(NSText.selectAll(_:)), "a")
        edit.addItem(.separator())
        item(edit, "复制给定数", #selector(copyPuzzle), "g", target: self)
        item(edit, "复制候选与提示", #selector(copyStep), "c", modifiers: [.command,.option], target: self)
        let copyFormats = menu("复制棋盘为", in: edit)
        let clipboardFormats: [(String, NativePuzzleFormat)] = [
            ("当前数字", .filledValues), ("普通候选数", .pencilMarks),
            ("HoDoKu 库格式", .library), ("Simple Sudoku", .simpleSudoku)
        ]
        for (title, format) in clipboardFormats {
            item(copyFormats, title, #selector(copyBoardFormat(_:)), target: self).representedObject = format.rawValue
        }
        item(edit, "重置普通候选数…", #selector(resetCandidates), target: self)

        let puzzle = menu("题目", in: bar)
        let mode = menu("新题模式", in: puzzle)
        for (title, value) in [("普通", "PLAYING"), ("学习", "LEARNING"), ("练习", "PRACTISING")] {
            item(mode, title, #selector(selectMode(_:)), target: self).representedObject = value
        }
        let levels = menu("新题难度", in: puzzle)
        for level in 1...5 {
            item(levels, NativeBoardAppearance.levelNames[level], #selector(selectDifficulty(_:)), target: self).tag = level
        }
        item(puzzle, "题目历史…", #selector(history), target: self)
        puzzle.addItem(.separator())
        item(puzzle, "修改题目给定数…", #selector(editGivens), target: self)
        item(puzzle, "重新开始当前题…", #selector(restartGame), "r", target: self)
        item(puzzle, "开始作答", #selector(startEnteredGame), "\r", target: self)
        puzzle.addItem(.separator())
        item(puzzle, "添加保存点…", #selector(addPoint), "s", modifiers: [.command,.option], target: self)
        item(puzzle, "恢复保存点…", #selector(restorePoint), "o", modifiers: [.command,.option], target: self)

        let solve = menu("解题", in: bar)
        let f12 = String(Unicode.Scalar(NSF12FunctionKey)!)
        item(solve, "分析当前线索", #selector(analyzeClues), target: self)
        item(solve, "当前思路", #selector(showReasoning), f12, modifiers: .shift, target: self)
        item(solve, "解题路径", #selector(showPath), "o", modifiers: [.command,.shift], target: self)
        item(solve, "选择技巧", #selector(showSteps), "a", modifiers: [.command,.shift], target: self)
        let legacyTechniques = item(solve, "选择技巧", #selector(showSteps), f12, modifiers: [.command,.option], target: self)
        legacyTechniques.isHidden = true
        legacyTechniques.allowsKeyEquivalentWhenHidden = true
        solve.addItem(.separator())
        item(solve, "开始提示", #selector(startHint), f12, modifiers: .option, target: self)
        item(solve, "继续提示", #selector(nextHint), f12, modifiers: .command, target: self)
        item(solve, "显示完整提示", #selector(fullHint), f12, modifiers: [], target: self)
        solve.addItem(.separator())
        item(solve, "检查解数", #selector(countSolutions), "m", target: self)
        item(solve, "填入全部单数", #selector(fillSingles), String(Unicode.Scalar(NSF11FunctionKey)!), modifiers: [], target: self)
        item(solve, "求解当前题…", #selector(solvePuzzle), target: self)
        item(solve, "解题摘要", #selector(analysis), "u", modifiers: [.command,.shift], target: self)

        let replay = menu("回放", in: bar)
        item(replay, "播放本次作答", #selector(replays), target: self)
        item(replay, "回放库", #selector(openReplayLibrary), target: self)
        item(replay, "打开回放…", #selector(openReplay), target: self)

        let view = menu("视图", in: bar)
        item(view, "返回棋盘", #selector(returnToBoard), "0", modifiers: [.command,.shift], target: self)
        item(view, "显示提示面板", #selector(toggleHintPanel), target: self)
        item(view, "冻结画面", #selector(toggleFreeze), target: self)
        let boardTools = menu("棋盘工具", in: view)
        for (index, tool) in BoardTool.allCases.enumerated() {
            item(boardTools, tool.title, #selector(selectBoardTool(_:)), target: self).tag = index
        }
        view.addItem(.separator())
        let appearance = menu("外观", in: view)
        for (title, value) in [("跟随系统", "SYSTEM"), ("浅色", "LIGHT"), ("深色", "DARK")] {
            item(appearance, title, #selector(selectAppearance(_:)), target: self).representedObject = value
        }
        for option in MenuOption.allCases where option != .sounds {
            item(view, option.rawValue, #selector(toggleOption(_:)), target: self).representedObject = option.rawValue
        }
        view.addItem(.separator())
        item(view, "显示或隐藏工具栏", #selector(toggleToolbar), target: self)
        item(view, "自定工具栏…", #selector(NSWindow.runToolbarCustomizationPalette(_:)))
        item(view, "重置视图", #selector(resetView), target: self)

        let windows = menu("窗口", in: bar)
        item(windows, "最小化", #selector(NSWindow.performMiniaturize(_:)), "m", modifiers: [.command,.option])
        item(windows, "缩放窗口", #selector(NSWindow.performZoom(_:)))
        item(windows, "切换全屏", #selector(fullScreen), "f", modifiers: [.command,.shift], target: self)
        let help = menu("帮助", in: bar)
        item(help, "键盘快捷键", #selector(showShortcuts), target: self)
        help.addItem(.separator())
        for (title, address) in [
            ("原版用户手册", "https://hodoku.sourceforge.net/en/docs.php"),
            ("原版解题指南", "https://hodoku.sourceforge.net/en/techniques.php"),
            ("原版 HoDoKu 主页", "https://hodoku.sourceforge.net/en/index.php"),
            ("原版社区", "https://sourceforge.net/p/hodoku/discussion/907403/"),
            ("原版问题与建议", "https://sourceforge.net/p/hodoku/bugs-and-feature-requests/")
        ] {
            item(help, title, #selector(openHelpLink(_:)), target: self).representedObject = address
        }
        NSApp.mainMenu = bar
        NSApp.windowsMenu = windows
        NSApp.helpMenu = help
    }

    private func performToolbarCommand(_ command: BoardWindowToolbar.Command) {
        switch command {
        case .newGame: newGame()
        case .open: chooseFile()
        case .undo: board.history(redo: false)
        case .redo: board.history(redo: true)
        case .hint:
            if board.choosingTechnique {
                board.closeTechniqueChooser()
                board.setHintDrawerCollapsed(false)
                if !board.isHintDrawerAvailable { board.openHint() }
            } else if board.hintDrawerCollapsed { board.setHintDrawerCollapsed(false) }
            else if board.isHintDrawerAvailable { board.closeHint() }
            else { board.openHint() }
        case .count: countSolutions()
        case .replays: replays()
        case .analyze: analyzeClues()
        case .reasoning: showReasoning()
        case .path: showPath()
        case .techniques: showSteps()
        case .share: shareBoard()
        case .save: save()
        case .history: history()
        case .freeze: toggleFreeze()
        case .summary: analysis()
        }
    }

    private func act(_ task: () throws -> Void) {
        do { try task() } catch { workspace.reportFailure(error) }
    }

    private enum MenuOption: String, CaseIterable {
        case candidates = "显示全部候选数"
        case highlight = "选择已填数字时自动高亮同数"
        case conflicts = "标出违反数独规则的数字和候选"
        case deviations = "标出与答案的偏差"
        case colorKu = "用 ColorKu 色点显示数字"
        case sounds = "播放操作音效"
    }

    private func checked(_ option: MenuOption) -> Bool {
        switch option {
        case .candidates: return board.mouseOptions.showCandidates
        case .highlight: return board.mouseOptions.autoHighlighting
        case .conflicts: return board.generalOptions.showWrongValues
        case .deviations: return board.mouseOptions.showDeviations
        case .colorKu: return board.generalOptions.showColorKu
        case .sounds: return board.mouseOptions.operationSoundsEnabled
        }
    }

    private func setPreferences(_ change: (inout NativeWorkspacePreferences) -> Void) {
        var preferences = workspace.preferences
        change(&preferences)
        act { try workspace.updatePreferences(preferences) }
    }

    @objc private func toggleOption(_ item: NSMenuItem) {
        guard let value = item.representedObject as? String, let option = MenuOption(rawValue: value) else { return }
        let enabled = !checked(option)
        setPreferences { preferences in
            var mouse = board.mouseOptions
            var general = board.generalOptions
            switch option {
            case .candidates: mouse.showCandidates = enabled
            case .highlight: mouse.autoHighlighting = enabled
            case .conflicts: general.showWrongValues = enabled
            case .deviations: mouse.showDeviations = enabled
            case .colorKu: general.showColorKu = enabled
            case .sounds: mouse.operationSoundsEnabled = enabled
            }
            preferences.mouse = mouse
            preferences.general = general
        }
    }

    @objc private func selectMode(_ item: NSMenuItem) {
        guard let mode = item.representedObject as? String, mode != workspace.preferences.mode else { return }
        let options = board.generalOptions
        let title = String(format: options.localized("将新题模式设为「%@」？"), item.title)
        let message = mode != "PLAYING" && workspace.preferences.training.isEmpty
            ? "此设置用于之后的新题。请先在设置中选择训练技巧，否则出普通题。"
            : "此设置用于之后的新题，当前作答继续保留。"
        presentCommand("workspace-mode", title: title, message: message, action: "切换模式") { _ in
            var preferences = self.workspace.preferences
            preferences.mode = mode
            try self.workspace.updatePreferences(preferences)
        }
    }
    @objc private func selectDifficulty(_ item: NSMenuItem) { setPreferences { $0.difficulty = item.tag } }
    @objc private func selectAppearance(_ item: NSMenuItem) {
        guard let appearance = item.representedObject as? String else { return }
        setPreferences { $0.appearance = appearance }
    }
    @objc private func selectBoardTool(_ item: NSMenuItem) {
        guard BoardTool.allCases.indices.contains(item.tag) else { return }
        returnToBoard()
        board.chooseTool(BoardTool.allCases[item.tag])
    }
    @objc private func startHint() { returnToBoard(); board.setHintDrawerCollapsed(false); board.openHint() }
    @objc private func nextHint() { returnToBoard(); board.setHintDrawerCollapsed(false); board.moveHint(1) }
    @objc private func fullHint() { startHint(); board.moveHint(100) }
    @objc private func analyzeClues() {
        returnToBoard()
        if board.choosingTechnique { board.closeTechniqueChooser() }
        board.analyzeHint()
    }
    @objc private func shareBoard() {
        returnToBoard()
        guard let view = window?.contentView else { return }
        NativeBoardShareMenu.showFromTop(model: board, in: view) { [weak self] export in
            self?.saveExport(export)
        }
    }
    @objc private func showReasoning() { returnToBoard(); board.openCurrentReasoning() }
    @objc private func toggleHintPanel() { returnToBoard(); performToolbarCommand(.hint) }
    @objc private func toggleFreeze() { returnToBoard(); board.toggleFreeze() }
    @objc private func toggleToolbar() { window?.toggleToolbarShown(nil) }
    @objc private func resetView() {
        guard let window, let area = window.screen?.visibleFrame else { return }
        returnToBoard()
        board.closeHint()
        board.closeTechniqueChooser()
        window.toolbar?.isVisible = true
        let preferred = window.frameRect(forContentRect: NSRect(x: 0, y: 0, width: 900, height: 740)).size
        let width = min(preferred.width, area.width)
        let height = min(preferred.height, area.height)
        window.setFrame(NSRect(x: area.midX - width / 2, y: area.midY - height / 2, width: width, height: height), display: true)
    }

    private func showCommandDialog(_ dialog: NSPanel) {
        guard let window, window.attachedSheet == nil, !workspace.commandDialogOpen, !waitingForQuit else { return }
        let responder = window.firstResponder
        commandDialog = dialog
        workspace.commandDialogOpen = true
        window.beginSheet(dialog) { [weak self, weak dialog, weak window, weak responder] _ in
            guard let self, let dialog, self.commandDialog === dialog else { return }
            dialog.orderOut(nil)
            self.commandDialog = nil
            self.workspace.commandDialogOpen = false
            if let responder, let window {
                let stillAttached = (responder as? NSView).map { $0.window === window } ?? true
                if stillAttached && window.makeFirstResponder(responder) { return }
            }
            self.board.focusOnBoardReturn = true
        }
    }

    private func presentCommand(_ id: String, title: String, message: String, input: WorkspaceCommandDialog.Input = .none,
                                action: String, dismiss: String = "取消",
                                perform: @escaping (WorkspaceCommandDialog) throws -> Void) {
        let dialog = WorkspaceCommandDialog(options: board.generalOptions, id: id, title: title, message: message,
                                            input: input, action: action, dismiss: dismiss)
        dialog.submit = { [weak self] dialog in
            do { try perform(dialog); dialog.complete() }
            catch { self?.reportCommandFailure(error, in: dialog) }
        }
        showCommandDialog(dialog)
    }

    private func reportCommandFailure(_ error: Error, in dialog: WorkspaceCommandDialog) {
        dialog.showError(error)
        board.playOperationSound(.failure)
    }

    private func confirm(_ title: String, message: String, button: String, perform: @escaping () -> Void) {
        presentCommand("workspace-confirm", title: title, message: message, action: button) { _ in perform() }
    }

    @objc private func resetCandidates() {
        confirm("重置普通候选数？", message: "将按当前数字恢复普通候选，可撤销。个人笔记会保留。", button: "重置") { [weak self] in
            self?.returnToBoard()
            self?.board.resetOrdinaryCandidates()
        }
    }

    @objc private func solvePuzzle() {
        confirm("填入当前题的答案？", message: "只有确认唯一解后才会填数，可撤销。", button: "求解") { [weak self] in
            self?.solveCurrentBoard()
        }
    }

    private func solveCurrentBoard() {
        guard !solving else { return }
        returnToBoard()
        board.finishPointer()
        let source = board.progress.current.board
        let attempt = board.recorder.document.id
        solving = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let solution = NativePuzzleHSOL.validation(source.values, source.candidates).1
            DispatchQueue.main.async {
                guard let self else { return }
                self.solving = false
                guard self.board.canEdit, self.board.frozen == nil, !self.waitingForQuit,
                      self.board.recorder.document.id == attempt, self.board.progress.current.board == source else { return }
                if let solution { self.board.applyUniqueSolution(solution) }
                else {
                    self.board.showOperationFeedback(self.board.generalOptions.localized("无法确认当前盘面有唯一解。"), sound: .failure)
                }
            }
        }
    }

    @objc private func openHelpLink(_ item: NSMenuItem) {
        guard let address = item.representedObject as? String, let url = URL(string: address) else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func showShortcuts() {
        let options = board.generalOptions
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = options.localized("键盘快捷键")
        alert.informativeText = [
            "M 填数　T 标色　P 涂鸦　L 自由链　S 选框",
            "⌥F12 开始提示　⌘F12 继续提示　F12 完整提示",
            "` 分析或下一档　⇧` 上一档　⌥` 重新匹配",
            "Tab 当前思路　⇧⌘O 解题路径　⇧⌘A 选择技巧",
            "回车 应用预览。填数时可填单数或切换筛选候选。",
            "H 预览提示　Q 查看上一步　F11 填入全部单数",
            "按住 V 看行、⇧V 看列、⌥V 看宫。滚动切换编号。"
        ].map(options.localized).joined(separator: "\n")
        alert.addButton(withTitle: options.localized("关闭"))
        alert.beginSheetModal(for: window)
    }
    @objc private func newGame() { act { try workspace.newGame(); counter.invalidate() } }
    @objc private func chooseFile() {
        openPanel(fileTypes)
    }
    @objc private func openReplay() { openPanel(["hrep", "hdkreplay"]) }
    @objc private func openPreferences() { openPanel(["hodoku-settings"]) }
    private func openPanel(_ types: [String]) {
        guard let window = window else { return }
        let panel = NSOpenPanel()
        panel.allowedFileTypes = types
        panel.beginSheetModal(for: window) { if $0 == .OK, let url = panel.url { self.open(url) } }
    }
    @objc private func save() {
        act {
            try board.saveCurrent()
            if let named = namedFile, named.id == board.recorder.document.id {
                let data = try NativePuzzleFiles.encode(board.progress, as: named.format, step: board.reading, useZero: board.solverConfig.useZero)
                try board.store.checkExportLocation(named.url)
                try WorkspaceNamedExport.replace(named.url, expected: named.bytes, with: data)
                namedFile = (named.id, named.url, named.format, data)
            }
            board.playOperationSound(.save)
        }
    }
    private func destination(_ ext: String, name: String, write: @escaping (URL) throws -> Void) {
        guard let window = window else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name + "." + ext
        panel.allowedFileTypes = [ext]
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            self.act {
                try write(url)
                self.board.playOperationSound(.save)
            }
        }
    }
    @objc private func savePuzzleAs() { saveExport(.puzzle(.hsol)) }

    private func saveExport(_ export: NativeBoardExport) {
        guard board.canEdit, !workspace.opening, !workspace.generating, window?.attachedSheet == nil else { return }
        switch export {
        case .puzzle(let format): exportPuzzle(format)
        case .png: exportBoardImage()
        }
    }

    private func exportPuzzle(_ format: NativePuzzleFormat) {
        let game = board.progress, step = board.reading, id = board.recorder.document.id, zero = board.solverConfig.useZero
        destination(format.fileExtension, name: game.extra?.name ?? "HoDoKu 题目") { url in
            let data = try NativePuzzleFiles.encode(game, as: format, step: step, useZero: zero)
            try self.board.replayLibrary.export(data, to: url)
            if self.board.recorder.document.id == id { self.namedFile = (id, url, format, data) }
        }
    }
    @objc private func exportSettings() {
        destination("hodoku-settings", name: "HoDoKu 设置") { url in
            try self.board.replayLibrary.export(self.workspace.preferencesData(), to: url)
        }
    }
    @objc private func pastePuzzle(_ sender: Any?) {
        guard !workspace.opening, !workspace.generating, !workspace.commandDialogOpen else { return }
        act {
            guard let text = NSPasteboard.general.string(forType: .string) else { throw NativePuzzleError.grid }
            workspace.pastePuzzle(text)
            counter.invalidate()
        }
    }
    @objc private func copyPuzzle() {
        act { try board.copyPuzzle(.clues) }
    }
    @objc private func copyStep() {
        act { try board.copyPuzzle(.pencilMarksWithStep) }
    }
    @objc private func copyBoardFormat(_ item: NSMenuItem) {
        guard let value = item.representedObject as? String, let format = NativePuzzleFormat(rawValue: value) else { return }
        act { try board.copyPuzzle(format) }
    }
    @objc private func returnToBoard() {
        board.focusOnBoardReturn = true
    }
    @objc private func redoBoard() { board.history(redo: true) }
    @objc private func importLine() {
        let dialog = WorkspaceCommandDialog(options: board.generalOptions, id: "workspace-import",
                                            title: "导入题目字符串",
                                            message: "粘贴题目字符串以开始新作答。当前作答会保存在回放库。",
                                            input: .text(label: "题目字符串", id: "workspace-import-text", value: "", editable: true),
                                            action: "打开题目")
        dialog.submit = { [weak self] dialog in
            guard let self else { return }
            let text = dialog.text
            dialog.setValidating(true)
            self.workspace.pastePuzzle(text, onError: { [weak self, weak dialog] error in
                guard let dialog else { return }
                dialog.setValidating(false)
                self?.reportCommandFailure(error, in: dialog)
            }) { [weak self, weak dialog] opened in
                guard opened else { return }
                self?.counter.invalidate()
                dialog?.complete()
            }
        }
        dialog.onCancel = { [weak self] in self?.workspace.cancelOpening() }
        showCommandDialog(dialog)
    }

    @objc private func exportLine() {
        act {
            let data = try NativePuzzleFiles.encode(board.progress, as: .filledValues, useZero: board.solverConfig.useZero)
            presentCommand("workspace-export", title: "导出题目字符串",
                           message: "含给定数和已填数字。标注与候选数不会写入字符串。",
                           input: .text(label: "题目字符串", id: "workspace-export-text",
                                        value: String(decoding: data, as: UTF8.self), editable: false),
                           action: "复制题目", dismiss: "关闭") { _ in
                try self.board.copyPuzzle(.filledValues)
            }
        }
    }
    @objc private func fullScreen() { window?.toggleFullScreen(nil) }
    @objc private func showPath() { returnToBoard(); board.openSolutionPath() }
    @objc private func showSteps() { returnToBoard(); board.openTechniqueChooser() }
    @objc private func countSolutions() {
        returnToBoard()
        let snapshot = board.progress.current.board
        counter.check(values: snapshot.values, candidates: snapshot.candidates)
    }
    @objc private func fillSingles() { returnToBoard(); board.fillSingles() }
    @objc private func newBlank() {
        openClueEditor(String(repeating: "0", count: 81))
    }
    @objc private func editGivens() {
        let clues = NativeDesktopWorkspace.clues(board.progress.current.board)
        confirm("修改题目给定数？", message: "将打开仅含给定数的新作答。当前作答会保存在回放库。", button: "修改给定数") { [weak self] in
            self?.openClueEditor(clues)
        }
    }
    private func openClueEditor(_ clues: String) {
        act {
            var game = try NativePuzzleFiles.readText(clues)
            game.current.board.fixed = Array(repeating: false, count: 81)
            var context = NativeGameContext()
            context.editingClues = true
            game.extra = context
            try board.installGame(game)
            returnToBoard()
        }
    }
    @objc private func startEnteredGame() {
        guard board.progress.extra?.editingClues == true else { return }
        workspace.pastePuzzle(board.progress.current.board.values.map(String.init).joined(), feedback: false)
    }
    @objc private func restartGame() {
        let clues = NativeDesktopWorkspace.clues(board.progress.current.board)
        confirm("从给定数重新开始？", message: "当前作答会保存在回放库。", button: "重新开始") { [weak self] in
            self?.workspace.pastePuzzle(clues, feedback: false)
        }
    }
    @objc private func printBoard() {
        guard let window = window else { return }
        let status = NativeBoardStatus(model: board)
        let rating = [status.grade, status.score.map { "\($0) 分" }].compactMap { $0 }.joined(separator: "　")
        WorkspacePrintView(board: board.frame, title: board.progress.extra?.name ?? "HoDoKu", rating: rating.isEmpty ? nil : rating).printPage(window)
    }
    @objc private func pageSetup() { NSApp.runPageLayout(nil) }
    private func exportBoardImage() {
        let frame = board.frame
        destination("png", name: "HoDoKu") { url in
            try self.board.replayLibrary.export(BoardPainter.png(frame), to: url)
        }
    }
    @objc private func settings() {
        guard let window, window.attachedSheet == nil, !workspace.opening, !workspace.generating else { return }
        let size = NativeSettingsPanel.dialogSize(in: window.contentLayoutRect.size)
        showCommandDialog(NativeSettingsPanel(workspace: workspace, size: size))
    }
    @objc private func analysis() { returnToBoard(); board.showingBoardSummary = true }

    @objc private func history() {
        let entries = workspace.preferences.history
        let options = board.generalOptions
        let dates = DateFormatter()
        dates.locale = options.locale
        dates.dateStyle = .short
        let titles = entries.enumerated().map { index, entry in
            let status = options.localized(entry.isCompleted ? "已完成" : "进行中")
            let date = dates.string(from: Date(timeIntervalSince1970: Double(entry.lastStartedAt) / 1000))
            let level = NativeBoardAppearance.levelNames.indices.contains(entry.level) && entry.level > 0
                ? options.localized(NativeBoardAppearance.levelNames[entry.level]) : ""
            return ["\(index + 1).", status, level, date, String(entry.clues.prefix(18)) + "…"].filter { !$0.isEmpty }.joined(separator: "  ")
        }
        presentCommand("workspace-history", title: "题目历史",
                       message: entries.isEmpty ? "还没有题目历史。" : "打开所选题目会开始新作答。当前作答会保存在回放库。",
                       input: .choices(label: "历史题目", id: "workspace-history-choice", titles: titles),
                       action: "打开题目", dismiss: entries.isEmpty ? "关闭" : "取消") { dialog in
            guard entries.indices.contains(dialog.choice) else { return }
            let entry = entries[dialog.choice]
            var game = try NativePuzzleFiles.readText(entry.puzzleForOpen)
            var context = game.extra ?? NativeGameContext()
            context.difficulty = entry.level
            context.score = entry.score
            game.extra = context
            try self.board.installGame(game)
            self.counter.invalidate()
            self.returnToBoard()
        }
    }

    @objc private func addPoint() {
        presentCommand("workspace-point-add-dialog", title: "添加保存点",
                       message: "为当前盘面和批注创建一个命名保存点。",
                       input: .field(label: "保存点名称", id: "workspace-point-name"), action: "添加保存点") { dialog in
            try self.board.addGameSavePoint(dialog.text)
            self.board.playOperationSound(.save)
        }
    }

    @objc private func restorePoint() {
        let context = board.progress.extra
        let points = (context?.savePoints ?? []).map { ($0.name, $0.progress) }
        let legacy = (context?.legacy?.savePoints ?? []).enumerated().map { index, point in
            (point.name ?? "\(self.board.generalOptions.localized("保存点")) \(index + 1)", point.progress)
        }
        let all = points + legacy
        let titles = all.enumerated().map { "\($0.offset + 1). \($0.element.0)" }
        presentCommand("workspace-point-restore", title: "恢复保存点",
                       message: all.isEmpty ? "这次作答还没有保存点。" : "当前盘面和批注将切换到所选保存点。",
                       input: .choices(label: "保存点", id: "workspace-point-choice", titles: titles),
                       action: "恢复保存点", dismiss: all.isEmpty ? "关闭" : "取消") { dialog in
            guard all.indices.contains(dialog.choice) else { return }
            try self.board.restoreGameSavePoint(all[dialog.choice].1)
            self.counter.invalidate()
            self.returnToBoard()
        }
    }
    @objc private func replays() { act { try board.beginReview() } }
    @objc private func openReplayLibrary() {
        act {
            if !board.reviewing { try board.beginReview() }
            board.showingReplayLibrary = true
        }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard !waitingForQuit, !workspace.opening, !workspace.generating, !workspace.commandDialogOpen, window?.attachedSheet == nil else { return false }
        let field = window?.firstResponder as? NSTextView
        switch menuItem.action {
        case #selector(toggleOption(_:)):
            guard let value = menuItem.representedObject as? String, let option = MenuOption(rawValue: value) else { return false }
            menuItem.state = checked(option) ? .on : .off
            return true
        case #selector(selectMode(_:)):
            menuItem.state = (menuItem.representedObject as? String) == workspace.preferences.mode ? .on : .off
            return true
        case #selector(selectDifficulty(_:)):
            let preferences = workspace.preferences
            menuItem.state = menuItem.tag == preferences.difficulty ? .on : .off
            return menuItem.tag >= board.solverConfig.requestedLevel(1, mode: preferences.mode, training: preferences.training)
        case #selector(selectAppearance(_:)):
            menuItem.state = (menuItem.representedObject as? String) == workspace.preferences.appearance ? .on : .off
            return true
        case #selector(selectBoardTool(_:)):
            guard BoardTool.allCases.indices.contains(menuItem.tag) else { return false }
            menuItem.state = BoardTool.allCases[menuItem.tag] == board.tool ? .on : .off
            return board.canEdit && board.frozen == nil
        case #selector(toggleFreeze):
            menuItem.state = board.frozen == nil ? .off : .on
            return board.canEdit
        case #selector(toggleHintPanel):
            menuItem.state = board.isHintDrawerAvailable && !board.hintDrawerCollapsed ? .on : .off
            return board.canEdit && board.frozen == nil
        case #selector(toggleToolbar):
            menuItem.state = window?.toolbar?.isVisible == true ? .on : .off
            return window?.toolbar != nil
        case #selector(resetView): return window?.styleMask.contains(.fullScreen) == false
        case #selector(openReplayLibrary): return board.writable || board.reviewing
        case #selector(solvePuzzle):
            return board.canEdit && board.frozen == nil && !solving && board.progress.current.board.values.contains(0)
        case #selector(editGivens), #selector(resetCandidates):
            return board.canEdit && board.frozen == nil
        case #selector(startHint), #selector(nextHint), #selector(fullHint), #selector(analyzeClues),
             #selector(showReasoning), #selector(showPath), #selector(showSteps):
            return board.canEdit && board.frozen == nil && field?.isEditable != true
        case #selector(newGame), #selector(newBlank), #selector(pastePuzzle(_:)), #selector(importLine), #selector(history):
            return !board.reviewing
        case #selector(startEnteredGame): return board.canEdit && board.progress.extra?.editingClues == true
        case #selector(redoBoard): return field == nil && board.canEdit && board.canRedo
        case #selector(countSolutions), #selector(fillSingles), #selector(restartGame),
             #selector(copyStep), #selector(exportLine):
            return board.canEdit && field?.isEditable != true
        case #selector(addPoint), #selector(restorePoint):
            return board.canEdit && board.frozen == nil
        case #selector(save), #selector(savePuzzleAs), #selector(copyPuzzle), #selector(copyBoardFormat(_:)),
             #selector(printBoard), #selector(shareBoard),
             #selector(analysis), #selector(replays): return board.canEdit
        default: return true
        }
    }
    @objc private func sleeping() { board.setReplayPause("sleep", true) }
    @objc private func awake() { board.setReplayPause("sleep", false) }
    func applicationDidResignActive(_ notification: Notification) { board.setReplayPause("inactive", true) }
    func applicationDidBecomeActive(_ notification: Notification) { board.setReplayPause("inactive", false) }
    func windowShouldClose(_ sender: NSWindow) -> Bool { NSApp.terminate(nil); return false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !workspace.opening, !workspace.commandDialogOpen else { return .terminateCancel }
        if waitingForQuit { quitPanel?.orderFront(nil); return .terminateLater }
        let previousResponder = window?.firstResponder
        if workspace.beginQuit() { counter.invalidate(); return .terminateNow }
        guard let window, let failure = workspace.quitFailure else {
            workspace.cancelQuit()
            return .terminateCancel
        }
        waitingForQuit = true
        responderBeforeQuit = previousResponder
        let panel = QuitFailurePanel(failure: failure, board: board) { [weak self] choice in
            self?.respond(choice)
        }
        showQuitFailureToast()
        quitPanel = panel
        window.makeKeyAndOrderFront(nil)
        let didEnd: (NSApplication.ModalResponse) -> Void = { [weak self, weak panel, weak window] response in
            guard let self, let panel, self.quitPanel === panel else { return }
            panel.orderOut(nil)
            self.quitPanel = nil
            self.waitingForQuit = false
            self.board.clearOperationMessage(identifier: QuitFailurePanel.toastID)
            let shouldTerminate = response == .OK
            if shouldTerminate { self.counter.invalidate() }
            else {
                self.workspace.cancelQuit()
                if let responder = self.responderBeforeQuit { window?.makeFirstResponder(responder) }
            }
            self.responderBeforeQuit = nil
            NSApp.reply(toApplicationShouldTerminate: shouldTerminate)
        }
        if window.attachedSheet == nil { window.beginSheet(panel, completionHandler: didEnd) }
        else { window.beginCriticalSheet(panel, completionHandler: didEnd) }
        return .terminateLater
    }
    private func respond(_ choice: QuitChoice) {
        guard waitingForQuit, let panel = quitPanel, let parent = panel.sheetParent else { return }
        switch choice {
        case .retry:
            if workspace.retryQuit() { parent.endSheet(panel, returnCode: .OK) }
            else if let failure = workspace.quitFailure {
                panel.updateFailure(failure)
                showQuitFailureToast()
            }
        case .cancel: parent.endSheet(panel, returnCode: .cancel)
        case .discard: parent.endSheet(panel, returnCode: .OK)
        }
    }

    private func showQuitFailureToast() {
        board.showOperationFeedback(board.generalOptions.localized("退出前保存失败"), sound: .failure,
                                    identifier: QuitFailurePanel.toastID)
    }
}

#if !WORKBENCH_KEY_CHECKS
@main
enum CandidateApplication {
    static func main() {
        let app = NSApplication.shared
        let delegate = CandidateDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) { app.run() }
    }
}

#endif
