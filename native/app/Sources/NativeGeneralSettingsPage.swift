// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

struct NativeGeneralSettingsPage: View {
    @Binding var preferences: NativeWorkspacePreferences

    private var general: NativeGeneralOptions { preferences.general ?? NativeGeneralOptions() }
    private func option<T>(_ path: WritableKeyPath<NativeGeneralOptions, T>) -> Binding<T> {
        Binding(get: { general[keyPath: path] }, set: { value in
            var next = general
            next[keyPath: path] = value
            preferences.general = next
        })
    }
    private func mouse(_ path: WritableKeyPath<NativeMouseOptions, Bool>) -> Binding<Bool> {
        Binding(get: { (preferences.mouse ?? NativeMouseOptions())[keyPath: path] }, set: { value in
            var next = preferences.mouse ?? NativeMouseOptions()
            next[keyPath: path] = value
            preferences.mouse = next
        })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            section("窗口与外观") {
                Picker("外观", selection: $preferences.appearance) {
                    Text("跟随系统").tag("SYSTEM")
                    Text("浅色").tag("LIGHT")
                    Text("深色").tag("DARK")
                }.pickerStyle(SegmentedPickerStyle())
                SettingsColumns {
                    Picker("语言", selection: option(\.language)) {
                        Text("跟随系统").tag("")
                        Text(verbatim: "简体中文").tag("zh")
                        Text(verbatim: "English").tag("en")
                        Text(verbatim: "Deutsch").tag("de")
                        if !["", "zh", "en", "de"].contains(general.language) {
                            Text(verbatim: general.locale.localizedString(forIdentifier: general.language) ?? general.language).tag(general.language)
                        }
                    }
                    Toggle("恢复上次的窗口布局", isOn: option(\.saveWindowLayout))
                    WholeNumberSetting("题目历史上限", value: $preferences.historyLimit, minimum: 0, unit: "道", commitWhenFinished: true)
                    Toggle("使用系统界面字号", isOn: option(\.useDefaultFontSize))
                    if !general.useDefaultFontSize {
                        WholeNumberSetting("界面字号", value: option(\.customFontSize), minimum: 1, unit: "磅")
                    }
                }
            }
            section("棋盘显示") {
                SettingsColumns {
                    Toggle("显示全部候选数", isOn: mouse(\.showCandidates)).accessibilityIdentifier("settings-show-candidates")
                    Toggle("标出违反数独规则的数字和候选", isOn: option(\.showWrongValues))
                    Toggle("标出与答案的偏差", isOn: mouse(\.showDeviations))
                    Toggle("用 ColorKu 色点显示数字", isOn: option(\.showColorKu))
                    Toggle("分别描绘九宫的边框", isOn: Binding(get: { general.drawMode == 0 }, set: { option(\.drawMode).wrappedValue = $0 ? 0 : 1 }))
                    Toggle("允许为已填数字的格子着色", isOn: option(\.colorValues))
                }
            }
            section("鼠标与选择") {
                SettingsColumns {
                    Toggle("单击填数", isOn: mouse(\.singleClickMode))
                    Toggle("按住 Shift 选择区域", isOn: mouse(\.useShiftForRegionSelect))
                    Toggle("选中单元格时仅显示边框", isOn: option(\.onlySmallCursors))
                    Toggle("闲置后隐藏单格选择标记", isOn: option(\.deleteCursorDisplay))
                    if general.deleteCursorDisplay {
                        WholeNumberSetting("停留时间", value: option(\.deleteCursorDisplayLength), minimum: 0, unit: "毫秒")
                    }
                    Toggle("录题时删除后移到下一格", isOn: mouse(\.editModeAutoAdvance))
                }
            }
            section("筛选与反馈") {
                SettingsColumns {
                    Toggle("选择已填数字时自动高亮同数", isOn: mouse(\.autoHighlighting))
                    Toggle("在已填数字上显示筛选标记", isOn: mouse(\.highlightingGivens))
                    Toggle("只标记匹配的候选数", isOn: mouse(\.onlySmallFilters))
                    Toggle("多数字筛选匹配任一选中数字", isOn: mouse(\.useOrInsteadOfAndForFilter))
                    Toggle("解出数独时显示提示", isOn: option(\.showSudokuSolved))
                    Toggle("播放操作音效", isOn: mouse(\.operationSoundsEnabled))
                }
            }
            Button("恢复本页默认值") {
                var next = preferences
                next.general = NativeGeneralOptions()
                next.mouse = NativeMouseOptions()
                next.appearance = "SYSTEM"
                next.historyLimit = 50
                preferences = next
            }
        }
    }

    private func section<Content: View>(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        GroupBox(label: Text(title).font(.headline)) {
            VStack(alignment: .leading, spacing: 7, content: content)
                .frame(maxWidth: .infinity, alignment: .leading).padding(5)
        }
    }

}

private struct WholeNumberSetting: View {
    let title: LocalizedStringKey
    @Binding var value: Int
    let minimum: Int
    let unit: LocalizedStringKey
    let commitWhenFinished: Bool
    @State private var editing: String?

    init(_ title: LocalizedStringKey, value: Binding<Int>, minimum: Int, unit: LocalizedStringKey, commitWhenFinished: Bool = false) {
        self.title = title
        _value = value
        self.minimum = minimum
        self.unit = unit
        self.commitWhenFinished = commitWhenFinished
    }

    private func valid(_ text: String?) -> Int? {
        guard let text, let n = Int(text), (minimum...Int(Int32.max)).contains(n) else { return nil }
        return n
    }

    private func finish() {
        if let n = valid(editing), value != n { value = n }
        editing = nil
    }

    var body: some View {
        HStack {
            Text(title)
            Spacer(minLength: 8)
            TextField(title, text: Binding(get: { editing ?? String(value) }, set: {
                editing = $0
                if !commitWhenFinished, let number = valid($0) { value = number }
            }), onEditingChanged: { if !$0 { finish() } }, onCommit: finish)
                .multilineTextAlignment(.trailing).frame(width: 72)
            Stepper(title, value: $value, in: minimum...Int(Int32.max)).labelsHidden()
            Text(unit).foregroundColor(.secondary)
        }
    }
}
