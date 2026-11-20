// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import SwiftUI

struct NativeGeneratorSettingsPage: View {
    @Binding var preferences: NativeWorkspacePreferences
    let config: NativeSolverConfig
    let showTraining: () -> Void
    @State private var checking: BlockOperation?
    @State private var notice: String?

    private var library: NativePatternSettings { preferences.generatorPatterns ?? NativePatternSettings() }
    private var selected: NativeCluePattern? {
        let index = library.selection
        return library.patterns.indices.contains(index) ? library.patterns[index] : nil
    }

    private func edit(_ change: (inout NativePatternSettings) -> Void) {
        cancelCheck()
        var value = library
        change(&value)
        preferences.generatorPatterns = value
        notice = nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            GroupBox(label: Text("新题").font(.headline)) {
                VStack(alignment: .leading, spacing: 10) {
                    SettingsColumns {
                        Picker("模式", selection: $preferences.mode) {
                            Text("普通").tag("PLAYING")
                            Text("学习").tag("LEARNING")
                            Text("练习").tag("PRACTISING")
                        }.accessibilityIdentifier("settings-game-mode")
                        Picker("难度", selection: $preferences.difficulty) {
                            ForEach(1...5, id: \.self) { level in
                                Text(LocalizedStringKey(NativeBoardAppearance.levelNames[level])).tag(level)
                                    .disabled(level < config.requestedLevel(1, mode: preferences.mode, training: preferences.training))
                            }
                        }
                    }
                    if preferences.mode != "PLAYING" {
                        Button(action: showTraining) {
                            Label(preferences.training.isEmpty ? "选择训练技巧" : "训练技巧（\(preferences.training.count)）", systemImage: "graduationcap")
                        }
                        if preferences.training.isEmpty {
                            Text("尚未选择训练技巧，新题将按普通模式生成。").font(.caption).foregroundColor(.secondary)
                        }
                    }
                }.padding(6).frame(maxWidth: .infinity, alignment: .leading)
            }

            GroupBox(label: Text("给定数图案").font(.headline)) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Picker("当前图案", selection: Binding(get: { library.selection }, set: { index in edit { $0.selection = index } })) {
                            Text("随机布局").tag(-1)
                            ForEach(library.patterns.indices, id: \.self) { i in
                                Text(library.patterns[i].name).tag(i)
                            }
                        }.accessibilityIdentifier("settings-pattern-picker")
                        Button("新建") {
                            edit {
                                $0.patterns.append(NativeCluePattern(name: "图案 \($0.patterns.count + 1)"))
                                $0.selection = $0.patterns.count - 1
                            }
                        }.accessibilityIdentifier("settings-pattern-new")
                    }
                    if let pattern = selected {
                        TextField("图案名称", text: Binding(get: { selected?.name ?? "" }, set: { name in
                            edit { if $0.patterns.indices.contains($0.selection) { $0.patterns[$0.selection].name = name } }
                        }))
                        HStack(alignment: .top, spacing: 14) {
                            patternGrid(pattern)
                            VStack(alignment: .leading, spacing: 8) {
                                Text("\(pattern.givens) 个给定数").font(.headline)
                                Label(pattern.valid ? "可用于出题" : "尚未通过检查",
                                      systemImage: pattern.valid ? "checkmark.circle" : "circle.dashed")
                                    .font(.caption).fixedSize(horizontal: false, vertical: true)
                                if checking != nil {
                                    ProgressView().controlSize(.small)
                                    Button("取消检查", action: cancelCheck)
                                } else {
                                    Button("检查图案", action: check)
                                        .disabled(pattern.givens < 17)
                                        .accessibilityIdentifier("settings-pattern-check")
                                }
                                if !pattern.valid {
                                    Text(pattern.givens < 17 ? "至少选中 17 格。" : "检查通过后，新题会采用这个布局。")
                                        .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }
                    Divider()
                    HStack {
                        Button("导入图案…", action: load)
                        Button("导出图案…", action: export).disabled(library.patterns.isEmpty)
                    }
                    if let notice = notice { Text(notice).foregroundColor(.secondary) }
                }.padding(6).frame(maxWidth: .infinity, alignment: .leading)
            }
            Button("恢复默认图案") { edit { $0 = NativePatternSettings() } }
                .disabled(library.patterns.isEmpty)
        }.onDisappear(perform: cancelCheck)
    }

    private func patternGrid(_ pattern: NativeCluePattern) -> some View {
        VStack(spacing: 1) {
            ForEach(0..<9) { row in
                HStack(spacing: 1) {
                    ForEach(0..<9) { col in
                        let cell = row * 9 + col
                        Button {
                            edit { $0.patterns[$0.selection].toggle(cell) }
                        } label: {
                            ZStack {
                                Rectangle().fill(pattern.cells[cell] ? Color.accentColor : Color(NSColor.textBackgroundColor))
                                if pattern.cells[cell] { Circle().fill(Color.white).frame(width: 5, height: 5) }
                            }.frame(width: 20, height: 20)
                        }.buttonStyle(PlainButtonStyle())
                        .accessibilityLabel("第 \(row + 1) 行第 \(col + 1) 列")
                        .accessibilityValue(pattern.cells[cell] ? "给定数" : "空格")
                        .padding(.trailing, col == 2 || col == 5 ? 1 : 0)
                    }
                }.padding(.bottom, row == 2 || row == 5 ? 1 : 0)
            }
        }.padding(1).background(Color(NSColor.separatorColor))
    }

    private func cancelCheck() {
        checking?.cancel()
        checking = nil
    }

    private func check() {
        guard let pattern = selected else { return }
        cancelCheck()
        let index = library.selection
        let operation = BlockOperation()
        notice = nil
        checking = operation
        operation.addExecutionBlock { [weak operation] in
            guard let operation = operation else { return }
            let result = Result { try NativeLiveGenerator.checkPattern(pattern, cancelled: { operation.isCancelled }) }
            DispatchQueue.main.async {
                guard !operation.isCancelled, checking === operation, library.selection == index, selected == pattern else { return }
                checking = nil
                switch result {
                case .success: edit { $0.patterns[index].valid = true }
                case .failure(let error):
                    if case NativeGenerationError.patternRejected = error { edit { $0.patterns[index].valid = false } }
                    notice = error.localizedDescription
                }
            }
        }
        DispatchQueue.global(qos: .userInitiated).async { operation.start() }
    }

    private func load() {
        let panel = NSOpenPanel()
        panel.allowedFileTypes = ["hpat"]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let attributes = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard attributes.isRegularFile == true, (1...LegacySettingsFile.maxSize).contains(attributes.fileSize ?? 0) else {
                throw WorkspaceProblem("图案文件为空、过大或不可读。")
            }
            let imported = try NativePatternSettings(file: Data(contentsOf: url))
            edit { $0 = imported }
        } catch { notice = error.localizedDescription }
    }

    private func export() {
        let panel = NSSavePanel()
        panel.allowedFileTypes = ["hpat"]
        panel.nameFieldStringValue = "HoDoKu 图案.hpat"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try library.fileData().write(to: url, options: .atomic); notice = nil }
        catch { notice = error.localizedDescription }
    }
}
