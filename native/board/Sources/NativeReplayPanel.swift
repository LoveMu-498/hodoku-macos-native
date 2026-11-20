import AppKit
import Combine
import SwiftUI

private struct RecordedBoard: NSViewRepresentable {
    var frame: NativeReplayFrame
    func makeNSView(context: Context) -> ReplayCanvas { ReplayCanvas() }
    func updateNSView(_ view: ReplayCanvas, context: Context) {
        if view.record != frame {
            view.record = frame
            view.needsDisplay = true
        }
    }
}

private final class ReplayCanvas: NSView {
    var record: NativeReplayFrame?
    override var isFlipped: Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityIdentifier("replay-canvas")
        setAccessibilityLabel("历史棋盘")
    }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirtyRect: NSRect) {
        guard let f = record, let cg = NSGraphicsContext.current?.cgContext else { return }
        ReplayExchangePainter.draw(f, in: bounds, context: cg)
    }
}

struct NativeReplayPanel: View {
    @ObservedObject var model: NativeBoardModel
    @State private var player: NativeReplayPlayer
    @State private var selected: ReplayLibraryEntry?
    @State private var externalName: String?
    private var live: Bool { selected == nil && externalName == nil }
    @State private var entries: [ReplayLibraryEntry] = []
    @State private var error: String?
    @State private var loading = false
    @State private var choosingBranch = false
    @State private var bookmarkName = ""
    @State private var naming = false
    private let ticks = Timer.publish(every: 0.10, on: .main, in: .common).autoconnect()

    init(model: NativeBoardModel) {
        self.model = model
        _player = State(initialValue: NativeReplayPlayer(document: model.openedReplay?.document ?? model.recorder.document))
        _externalName = State(initialValue: model.openedReplay?.name)
    }

    var body: some View {
        VStack(spacing: 6) {
            HStack {
                Button("返回作答", action: model.endReview).accessibilityIdentifier("replay-close")
                Button("回放库") { model.showingReplayLibrary.toggle() }.accessibilityIdentifier("replay-library")
                    .popover(isPresented: $model.showingReplayLibrary) { shelf }
                Menu("文件") {
                    Button("打开回放…", action: openFile)
                    Button("分享回放…") { exportFile(.share) }
                    Button("打印本帧…") {
                        if let frame = player.frame, let window = NSApp.keyWindow { WorkspacePrintView(replay: frame).printPage(window) }
                    }
                }.fixedSize()
                Spacer()
                if player.document.originalBytes != nil {
                    Button("原样另存…") { exportFile(.original) }
                    if player.document.format == .javaV3 {
                        Menu("导出…") {
                            Button("FRAME 0.2…") { exportFile(.frame) }
                            Button("旧 Windows V3 副本…") { exportFile(.windows) }
                        }.fixedSize()
                    }
                } else {
                    Menu("导出…") {
                        Button("FRAME 0.2…") { exportFile(.frame) }
                        Button("Java V3…") { exportFile(.java) }
                        Button("旧 Windows V3 副本…") { exportFile(.windows) }
                    }.fixedSize()
                }
            }
            if let f = player.frame {
                HStack {
                    Text(selected?.name ?? externalName ?? "本次作答").font(.headline).lineLimit(1)
                    Spacer()
                    Text("\(player.index + 1) / \(player.document.frames.count)").accessibilityIdentifier("replay-position")
                }
                Divider()
                GeometryReader { geometry in
                    if geometry.size.width >= 650 {
                        HStack(spacing: 10) {
                            RecordedBoard(frame: f)
                            details(f).frame(width: min(360, geometry.size.width * 0.36))
                        }
                    } else {
                        VStack(spacing: 5) {
                            RecordedBoard(frame: f)
                            details(f).frame(height: max(65, geometry.size.height * 0.28))
                        }
                    }
                }
                Divider()
                HStack {
                    Text(clock(player.cursorMillis)).font(.system(.body, design: .monospaced))
                    Slider(value: Binding(get: { Double(player.cursorMillis) }, set: { player.seek(Int64($0)) }),
                           in: 0...max(1, Double(player.durationMillis)))
                        .accessibilityLabel("回放时间").disabled(player.durationMillis == 0)
                    Text(clock(player.durationMillis)).font(.system(.body, design: .monospaced))
                }
                HStack {
                    Button("上个操作") { player.stepOperation(-1) }.disabled(player.index == 0)
                    Button("上一帧") { player.stepFrame(-1) }.disabled(player.index == 0).accessibilityIdentifier("replay-prev")
                    Button(player.playing ? "暂停" : "播放") {
                        player.setPlaying(!player.playing, nowNanos: DispatchTime.now().uptimeNanoseconds)
                    }.accessibilityIdentifier("replay-play")
                    Button("下一帧") { player.stepFrame(1) }.disabled(player.index + 1 >= player.document.frames.count)
                        .accessibilityIdentifier("replay-next")
                    Button("下个操作") { player.stepOperation(1) }.disabled(player.index + 1 >= player.document.frames.count)
                    Spacer()
                }
                HStack {
                    Button((selected?.pinned ?? (live ? model.recorder.document.pinned : player.document.pinned)) ? "取消钉住" : "钉住", action: pin)
                    Button("添加保存点") { player.setPlaying(false, nowNanos: DispatchTime.now().uptimeNanoseconds); naming = true }.popover(isPresented: $naming) {
                        HStack {
                            TextField("保存点名称", text: $bookmarkName)
                            Button("保存", action: bookmark).disabled(bookmarkName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }.padding().frame(width: 260)
                    }
                    Menu("保存点") {
                        ForEach(Array((selected?.bookmarks ?? (live ? model.recorder.document.bookmarks : player.document.bookmarks)).enumerated()), id: \.offset) { _, mark in
                            Button(mark.name) { player.showFrame(mark.frameIndex) }
                        }
                    }.fixedSize().disabled((selected?.bookmarks ?? (live ? model.recorder.document.bookmarks : player.document.bookmarks)).isEmpty)
                    Spacer()
                    Button("从此帧开新局") { player.setPlaying(false, nowNanos: DispatchTime.now().uptimeNanoseconds); choosingBranch = true }.accessibilityIdentifier("replay-branch")
                        .alert(isPresented: $choosingBranch) {
                            Alert(title: Text("从第 \(player.index + 1) 帧开新局？"),
                                  message: Text("新局从所选盘面单独计时和保存。已有作答会存入回放库。"),
                                  primaryButton: .default(Text("开新局"), action: branch), secondaryButton: .cancel())
                        }
                }
            }
            if loading { ProgressView("正在打开回放…") }
            if let message = error {
                HStack { Text(message); Spacer(); Button("关闭") { error = nil } }
            }
        }.padding(10).disabled(loading)
        .background(ReplayKeyboardScope { code in
            guard !naming, !choosingBranch, !model.showingReplayLibrary, !loading else { return false }
            switch code {
            case 53: model.focusOnBoardReturn = true; model.endReview()
            case 123: player.stepFrame(-1)
            case 124: player.stepFrame(1)
            case 115: player.showFrame(0)
            case 119: player.showFrame(player.document.frames.count - 1)
            case 36, 49, 76: player.setPlaying(!player.playing, nowNanos: DispatchTime.now().uptimeNanoseconds)
            default: return false
            }
            return true
        })
        .onAppear { refresh() }
        .onReceive(ticks) { _ in if player.playing { player.tick(nowNanos: DispatchTime.now().uptimeNanoseconds) } }
    }

    private func details(_ frame: NativeReplayFrame) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                if frame.label != frame.text || frame.text.isEmpty { Text(frame.label).font(.headline) }
                ForEach(frame.notices, id: \.self) { Text($0).font(.callout).bold() }
                if !frame.text.isEmpty { Text(frame.text).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("replay-text") }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.accessibilityIdentifier("replay-details")
    }

    private var shelf: some View {
        ScrollView {
            VStack(alignment: .leading) {
                Button("本次作答") {
                    selected = nil
                    externalName = nil
                    player = NativeReplayPlayer(document: model.recorder.document)
                    model.showingReplayLibrary = false
                }.disabled(!model.writable)
                ForEach(entries) { entry in
                    Button(action: {
                        load { try model.replayLibrary.load(entry) } selected: { _ in entry }
                    }) {
                        HStack {
                            if entry.pinned { Image(systemName: "pin.fill").accessibilityLabel("已钉住") }
                            VStack(alignment: .leading) {
                                Text(entry.name)
                                Text(DateFormatter.localizedString(from: entry.date, dateStyle: .short, timeStyle: .medium))
                                    .font(.caption).foregroundColor(.secondary)
                            }
                        }
                    }.accessibilityIdentifier("replay-entry-" + entry.id)
                }
            }.padding().frame(maxWidth: .infinity, alignment: .leading)
        }.frame(width: 310, height: 220)
    }

    private func clock(_ ms: Int64) -> String { String(format: "%lld:%02lld", ms / 60_000, ms / 1000 % 60) }
    private func refresh() {
        do { entries = try model.replayLibrary.entries() } catch { self.error = error.localizedDescription }
    }
    private func load(named name: String? = nil, _ read: @escaping () throws -> NativeReplayDocument,
                      selected entry: @escaping (NativeReplayDocument) throws -> ReplayLibraryEntry?) {
        loading = true
        model.showingReplayLibrary = false
        player.setPlaying(false, nowNanos: DispatchTime.now().uptimeNanoseconds)
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { let doc = try read(); return (doc, try entry(doc)) }
            DispatchQueue.main.async {
                loading = false
                switch result {
                case let .success((doc, row)):
                    player = NativeReplayPlayer(document: doc)
                    selected = row
                    externalName = name
                    error = nil
                    refresh()
                case let .failure(problem): error = problem.localizedDescription
                }
            }
        }
    }
    private func openFile() {
        guard let owner = NSApp.mainWindow else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.beginSheetModal(for: owner) { response in
            guard response == .OK, let url = panel.url else { return }
            load(named: url.lastPathComponent) { try NativeReplayLibrary.read(url) } selected: { _ in nil }
        }
    }
    private func modify(_ edit: (inout ReplayLibraryEntry) -> Void) {
        do {
            let row = try selected ?? model.replayLibrary.put(player.document, named: externalName ?? "作答快照")
            selected = try model.replayLibrary.change(row.id, edit)
            error = nil
            refresh()
        } catch { self.error = error.localizedDescription }
    }
    private func pin() {
        if !live { modify { $0.pinned.toggle() }; return }
        do { try model.editReplayMetadata { $0.pinned.toggle() }; error = nil }
        catch { self.error = error.localizedDescription }
    }
    private func bookmark() {
        let name = bookmarkName.trimmingCharacters(in: .whitespacesAndNewlines)
        let marks = selected?.bookmarks ?? (live ? model.recorder.document.bookmarks : player.document.bookmarks)
        guard name.utf16.count <= 1000, marks.count < 10_000 else {
            error = "保存点名称最多 1000 个字符，每份回放最多 10000 个保存点。"
            return
        }
        let mark = NativeReplayBookmark(name: name, frameIndex: player.index)
        if !live { modify { $0.bookmarks.append(mark) } }
        else {
            do { try model.editReplayMetadata { $0.bookmarks.append(mark) }; error = nil }
            catch { self.error = error.localizedDescription }
        }
        if error == nil { bookmarkName = ""; naming = false }
    }
    private func branch() {
        do { try model.branch(from: live ? model.recorder.document : player.document, at: player.index, archived: selected) }
        catch { self.error = error.localizedDescription }
    }
    private enum Export { case original, frame, java, windows, share }
    private func exportFile(_ kind: Export) {
        guard let owner = NSApp.mainWindow, let anchor = owner.contentView else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "回放副本.hrep"
        panel.message = kind == .windows ? "旧版 Windows 再次保存时可能丢失 Mac 证明、保存点和来源。请使用新的文件名。" : "请选择新的文件名以保留原件。"
        panel.beginSheetModal(for: owner) { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                let bytes: Data
                switch kind {
                case .original:
                    guard let data = player.document.originalBytes else { throw BoardFileError.invalid }
                    bytes = data
                case .share: bytes = try player.document.originalBytes ?? ReplayExchange.encode(player.document)
                case .windows: bytes = try ReplayJavaCodec.encodeWindows(live ? model.recorder.document : player.document)
                case .frame: bytes = try ReplayExchange.encode(player.document)
                case .java: bytes = try ReplayJavaCodec.encode(live ? model.recorder.document : player.document)
                }
                try model.replayLibrary.export(bytes, to: url)
                if kind == .share {
                    WorkspaceSharing.shared.show(url, in: anchor, onShared: { [weak model = model] in
                        model?.playOperationSound(.share)
                    }) { self.error = $0 }
                } else {
                    model.playOperationSound(.save)
                }
            } catch { self.error = error.localizedDescription }
        }
    }
}


// The player owns navigation only while its window owns the keyboard. A field
// editor, button, popover or modal sheet continues through AppKit normally.
struct ReplayKeyboardScope: NSViewRepresentable {
    var handle: (UInt16) -> Bool
    final class RoutingView: NSView {
        var handle: ((UInt16) -> Bool)?
        private var monitor: Any?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor = monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self = self, let host = self.window, event.window === host, host.isKeyWindow,
                      self.route(event, in: host) else { return event }
                return nil
            }
        }
        func route(_ event: NSEvent, in host: NSWindow) -> Bool {
            guard event.type == .keyDown, host.attachedSheet == nil,
                  NSApp.modalWindow == nil, !isHiddenOrHasHiddenAncestor,
                  let responder = host.firstResponder, !(responder is NSTextView),
                  event.keyCode == 53 || event.modifierFlags.intersection([.command,.control,.option,.shift]).isEmpty
            else { return false }
            if [36,49,76].contains(event.keyCode) && (responder is NSButton || (responder as? NSView)?.accessibilityRole() == .button) { return false }
            return handle?(event.keyCode) == true
        }
        deinit { if let monitor = monitor { NSEvent.removeMonitor(monitor) } }
    }
    func makeNSView(context: Context) -> RoutingView { RoutingView() }
    func updateNSView(_ view: RoutingView, context: Context) { view.handle = handle }
}
