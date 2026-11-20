// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import SwiftUI

enum NativeAppearanceSection { case levelsFonts, colors, colorku }

struct NativeAppearanceSettingsPage: View {
    let section: NativeAppearanceSection
    @Binding var preferences: NativeWorkspacePreferences
    private var visual: NativeBoardAppearance { preferences.visual ?? NativeBoardAppearance() }

    private func edit(_ change: (inout NativeBoardAppearance) -> Void) {
        var copy = visual
        change(&copy)
        if copy != visual { preferences.visual = copy }
    }
    private func colorBinding(_ value: UInt32, write: @escaping (UInt32) -> Void) -> Binding<Color> {
        Binding(get: { Color(NativeBoardAppearance.cgColor(value)) }, set: { next in
            guard let c = NSColor(next).usingColorSpace(.sRGB) else { return }
            func byte(_ component: CGFloat) -> UInt32 { UInt32((min(1, max(0, component)) * 255).rounded()) }
            let packed = byte(c.alphaComponent) << 24 | byte(c.redComponent) << 16 | byte(c.greenComponent) << 8 | byte(c.blueComponent)
            write(packed)
        })
    }
    private func swatch(_ title: String, _ key: String, _ index: Int = 0) -> some View {
        ColorPicker(LocalizedStringKey(title), selection: colorBinding(visual.colors[key]![index]) { value in
            edit { $0.colors[key]![index] = value }
        }).accessibilityLabel(title)
    }
    private func block<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(LocalizedStringKey(title)).font(.headline)
            VStack(alignment: .leading, spacing: 9) { content() }
                .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                .background(RoundedRectangle(cornerRadius: 9).fill(Color(NSColor.controlBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color(NSColor.separatorColor), lineWidth: 0.5))
        }
    }
    private func pairs(_ rows: [(String, String)]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), alignment: .leading)], alignment: .leading, spacing: 9) {
            ForEach(rows.indices, id: \.self) { i in swatch(rows[i].0, rows[i].1) }
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            switch section {
            case .colors: colors
            case .colorku: colorku
            case .levelsFonts: levelsFonts
            }
            Button(section == .colorku ? LocalizedStringKey("恢复默认色盘") : LocalizedStringKey("恢复本页默认值")) {
                edit { value in
                    switch section {
                    case .colors:
                        for (key, group) in NativeBoardAppearance.colorDefaults where key != "colorKuColors" { value.colors[key] = group }
                    case .colorku: value.colors["colorKuColors"] = NativeBoardAppearance.colorDefaults["colorKuColors"]
                    case .levelsFonts:
                        value.levels = NativeBoardAppearance.levelDefaults
                        value.factors = NativeBoardAppearance.factorDefaults
                        value.fonts = NativeBoardAppearance.fontDefaults
                    }
                }
            }.disabled(isDefault)
        }
    }
    private var isDefault: Bool {
        switch section {
        case .colors: return visual.colors.filter { $0.key != "colorKuColors" } == NativeBoardAppearance.colorDefaults.filter { $0.key != "colorKuColors" }
        case .colorku: return visual.colors["colorKuColors"] == NativeBoardAppearance.colorDefaults["colorKuColors"]
        case .levelsFonts: return visual.levels == NativeBoardAppearance.levelDefaults && visual.factors == NativeBoardAppearance.factorDefaults && visual.fonts == NativeBoardAppearance.fontDefaults
        }
    }
    private func columns(_ first: LocalizedStringKey, _ second: LocalizedStringKey) -> some View {
        HStack {
            Spacer()
            Text(first).frame(width: 42)
            Text(second).frame(width: 42)
        }.font(.caption).foregroundColor(.secondary)
    }
    private var colors: some View {
        Group {
            block("棋盘与数字") {
                pairs([("宫线","gridColor"),("格线","innerGridColor"),("格子背景","defaultCellColor"),("交替宫背景","alternateCellColor"),
                       ("题面数字","cellFixedValueColor"),("填入数字","cellValueColor"),("候选数","candidateColor"),
                       ("冲突","wrongValueColor"),("偏离解答","deviationColor"),("选区","aktCellColor")])
            }
            block("筛选") {
                pairs([("符合条件","possibleCellColor"),("已填格","possibleFixedCellColor"),("反向筛选","invalidCellColor")])
            }
            block("提示与推理") {
                columns("文字", "底色")
                ForEach(Array(zip(["依据","删除","鳍","内鳍","自食候选"], ["","Delete","Fin","EndoFin","Cannibalistic"])), id: \.0) { name, suffix in
                    HStack {
                        Text(LocalizedStringKey(name)); Spacer()
                        swatch(name + "文字", "hintCandidate" + suffix + "Color").labelsHidden()
                        swatch(name + "底色", "hintCandidate" + suffix + "BackColor").labelsHidden()
                    }.help("左侧为文字颜色，右侧为底色")
                }
                Divider()
                swatch("推理箭头", "arrowColor")
            }
            block("几乎锁定集（ALS）") {
                columns("文字", "底色")
                ForEach(0..<4) { i in
                    HStack {
                        Text("集合 \(i + 1)"); Spacer()
                        swatch("集合 \(i + 1) 文字","hintCandidateAlsColors", i).labelsHidden()
                        swatch("集合 \(i + 1) 底色","hintCandidateAlsBackColors", i).labelsHidden()
                    }.help("左侧为文字颜色，右侧为底色")
                }
            }
            block("标色组") {
                columns("主色", "副色")
                ForEach(0..<6) { i in
                    HStack {
                        Text("色组 \(i + 1)"); Spacer()
                        swatch("色组 \(i + 1) 主色","coloringColors", i * 2).labelsHidden()
                        swatch("色组 \(i + 1) 副色","coloringColors", i * 2 + 1).labelsHidden()
                    }.help("左侧为主色，右侧为副色")
                }
            }
        }
    }
    private var colorku: some View {
        Group {
            Toggle("用颜色表示数字", isOn: Binding(get: { preferences.general?.showColorKu ?? false }, set: { enabled in
                var options = preferences.general ?? NativeGeneralOptions()
                options.showColorKu = enabled
                preferences.general = options
            }))
            block("数字色盘") {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), alignment: .leading)], alignment: .leading, spacing: 12) {
                    ForEach(1..<10) { digit in swatch("数字 \(digit)", "colorKuColors", digit - 1) }
                }
            }
            block("错误标记") {
                SettingsColumns {
                    swatch("冲突数字", "colorKuColors", 9)
                    swatch("偏离解答", "colorKuColors", 10)
                }
            }
        }
    }
    private var levelsFonts: some View {
        Group {
            block("难度与评分上限") {
                HStack { Spacer(); Text("分数上限").frame(width: 76); Text("文字").frame(width: 42); Text("底色").frame(width: 42) }
                    .font(.caption).foregroundColor(.secondary)
                ForEach(visual.levels.indices, id: \.self) { i in
                    let level = visual.levels[i], name = NativeBoardAppearance.levelNames[i]
                    HStack {
                        Text(LocalizedStringKey(name)).padding(.horizontal, 6).padding(.vertical, 2)
                            .foregroundColor(Color(NativeBoardAppearance.cgColor(level.foreground)))
                            .background(RoundedRectangle(cornerRadius: 4).fill(Color(NativeBoardAppearance.cgColor(level.background))))
                        Spacer()
                        if (1...4).contains(i) {
                            AppearanceNumberField(value: String(level.maxScore), label: name + "分数上限") { text in
                                guard let number = Int32(text), number >= 0 else { return false }
                                edit { $0.levels[i].maxScore = number }; return true
                            }.frame(width: 76)
                        } else {
                            Text(i == 0 ? "—" : "无上限").foregroundColor(.secondary).frame(width: 76)
                        }
                        ColorPicker(name + "文字", selection: colorBinding(level.foreground) { c in edit { $0.levels[i].foreground = c } }).labelsHidden()
                        ColorPicker(name + "底色", selection: colorBinding(level.background) { c in edit { $0.levels[i].background = c } }).labelsHidden()
                    }
                }
            }
            block("字体") {
                ForEach(["defaultValueFont", "defaultCandidateFont", "bigFont", "smallFont"], id: \.self) { key in
                    AppearanceFontRow(title: ["defaultValueFont":"棋盘数字", "defaultCandidateFont":"候选数", "bigFont":"打印标题", "smallFont":"打印评分"][key]!,
                        font: visual.fonts[key]!, printFont: ["bigFont","smallFont"].contains(key)) { f in edit { $0.fonts[key] = f } }
                }
            }
            block("棋盘比例") {
                SettingsColumns {
                    ForEach(["valueFontFactor","candidateFontFactor","hintBackFactor","boxLineFactor"], id: \.self) { key in
                        let title = ["valueFontFactor":"数字字号／格宽","candidateFontFactor":"候选字号／格宽","hintBackFactor":"提示标记大小","boxLineFactor":"宫线粗细"][key]!
                        HStack {
                            Text(LocalizedStringKey(title)); Spacer()
                            AppearanceNumberField(value: String(visual.factors[key]!), label: title) { text in
                                guard let value = Double(text), value.isFinite, value > 0 else { return false }
                                edit { $0.factors[key] = value }; return true
                            }.frame(width: 76)
                        }
                    }
                }
            }
        }
    }
}

private struct AppearanceNumberField: View {
    let value: String
    let label: String
    let update: (String) -> Bool
    @State private var draft = ""
    var body: some View {
        TextField(label, text: Binding(get: { draft }, set: { draft = $0; _ = update($0) }), onEditingChanged: { focused in
            if !focused { draft = value }
        }).multilineTextAlignment(.trailing).accessibilityLabel(label)
            .onAppear { draft = value }.onChange(of: value) { newValue in
                if Double(draft) != Double(newValue) { draft = newValue }
            }
    }
}

private struct AppearanceFontRow: View {
    let title: String
    let font: NativePaintFont
    let printFont: Bool
    let update: (NativePaintFont) -> Void
    private static let families = NSFontManager.shared.availableFontFamilies.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    private func binding<T>(_ path: WritableKeyPath<NativePaintFont, T>) -> Binding<T> {
        Binding(get: { font[keyPath: path] }, set: { next in var copy = font; copy[keyPath: path] = next; update(copy) })
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(LocalizedStringKey(title)).font(.subheadline)
            HStack {
                Picker(LocalizedStringKey(title + "字体"), selection: binding(\.name)) {
                    if !Self.families.contains(font.name) { Text(font.name).tag(font.name) }
                    ForEach(Self.families, id: \.self) { name in Text(name).tag(name) }
                }.labelsHidden()
                Picker(LocalizedStringKey(title + "字形"), selection: binding(\.style)) {
                    ForEach(0..<4) { i in Text(LocalizedStringKey(["常规","粗体","斜体","粗斜体"][i])).tag(i) }
                }.labelsHidden().frame(width: 74)
                AppearanceNumberField(value: String(font.size), label: title + "字号") { text in
                    guard let n = Int(text), n > 0, n <= Int(Int32.max) else { return false }
                    var next = font; next.size = n; update(next); return true
                }.frame(width: 44)
                    .help(printFont ? "打印字号" : "字体的标称字号。棋盘上的实际字号由格宽和下方比例决定。")
                Text("pt").font(.caption).foregroundColor(.secondary)
            }
        }
    }
}
