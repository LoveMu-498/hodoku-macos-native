// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

struct NativeSolverSettingsPage: View {
    let section: NativeSolverSection
    @Binding var preferences: NativeWorkspacePreferences
    let config: NativeSolverConfig
    var fillsHeight = false
    @State private var search = ""
    @State private var category = ""
    @State private var selected = ""
    private static let categories = Dictionary(uniqueKeysWithValues: LegacySettingsDefaults.rows.map { ($0[0], $0[10]) })
    private static let categoryNames: [String: String] = [
        "SINGLES":"单值技巧", "INTERSECTIONS":"交叉锁定", "SUBSETS":"数组", "BASIC_FISH":"基础鱼", "FINNED_BASIC_FISH":"带鳍基础鱼",
        "FRANKEN_FISH":"Franken 鱼", "FINNED_FRANKEN_FISH":"带鳍 Franken 鱼", "MUTANT_FISH":"变异鱼", "FINNED_MUTANT_FISH":"带鳍变异鱼",
        "SINGLE_DIGIT_PATTERNS":"单数字模式", "COLORING":"着色", "UNIQUENESS":"唯一性", "CHAINS_AND_LOOPS":"链与环",
        "WINGS":"翼形", "ALMOST_LOCKED_SETS":"近锁定集", "ENUMERATIONS":"枚举", "MISCELLANEOUS":"其他技巧", "LAST_RESORT":"最终手段"
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if section != .steps { techniques(config) }
            ForEach(section.optionGroups.indices, id: \.self) { i in
                let group = section.optionGroups[i]
                GroupBox(label: Text(LocalizedStringKey(group.0))) {
                    VStack(alignment: .leading, spacing: 10) {
                        // Keep the nine-digit picker on its own line.
                        let digits = group.1.filter { option in
                            if case .digits = option.control { return true }
                            return false
                        }
                        SettingsColumns {
                            ForEach(group.1.filter { option in !digits.contains { $0.key == option.key } }, id: \.key) { option in
                                setting(option)
                            }
                        }
                        ForEach(digits, id: \.key) { setting($0) }
                    }.padding(6).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Button("恢复本页默认值") { preferences.restoreSolverPage(section, config: config) }
        }
        .onChange(of: section) { _ in search = ""; selected = ""; category = "" }
    }

    private func setting(_ option: SolverOption) -> some View {
        optionRow(option, value: config.option(option.key)) { value in
            guard option.accepts(value) else { return }
            preferences.changeSolver(config) { next in
                next.apply(option: option.key, value: value)
                for (minKey, maxKey) in [("allStepsMinFishSize", "allStepsMaxFishSize"),
                                         ("allStepsKrakenMinFishSize", "allStepsKrakenMaxFishSize")] {
                    guard option.key == minKey || option.key == maxKey,
                          let lo = Int(next.option(minKey)), let hi = Int(next.option(maxKey)), lo > hi else { continue }
                    next.apply(option: option.key == minKey ? maxKey : minKey, value: value)
                }
            }
        }
        .disabled(option.key == "restrictChainLength" && config.option("restrictChainSize") == "false")
        .accessibilityIdentifier("settings-solver-" + option.key)
    }

    private func techniques(_ config: NativeSolverConfig) -> some View {
        let full = config.rules.indices.filter { section.includes(config.rules[$0]) }.sorted {
            let order: KeyPath<NativeSolverConfig.Rule, Int> = section == .progress ? \.progressIndex : \.index
            return (config.rules[$0][keyPath: order], $0) < (config.rules[$1][keyPath: order], $1)
        }
        let categories = Set(full.compactMap { Self.categories[config.rules[$0].kind] }).sorted { (Self.categoryNames[$0] ?? $0) < (Self.categoryNames[$1] ?? $1) }
        let locale = preferences.general ?? NativeGeneralOptions()
        let visible = full.filter { i in
            let kind = config.rules[i].kind
            let name = NativeHintTechnique(key: kind).name
            return (category.isEmpty || Self.categories[kind] == category) &&
                (search.isEmpty || kind.localizedCaseInsensitiveContains(search) || name.localizedCaseInsensitiveContains(search) || locale.localized(name).localizedCaseInsensitiveContains(search))
        }
        return VStack(alignment: .leading, spacing: 8) {
            if section == .progress {
                Picker("套用预设", selection: Binding<String>(get: { "" }, set: { preset in
                    guard !preset.isEmpty else { return }
                    preferences.changeSolver(config) { $0.progressPreset(level: Int(preset)) }
                })) {
                    Text("选择预设…").tag("")
                    Text("中等及以下").tag("2")
                    Text("困难及以下").tag("3")
                    Text("Simple Sudoku（SSTS）").tag("ssts")
                }
            }
            HStack {
                TextField("搜索技巧", text: $search)
                Picker("技巧族", selection: $category) {
                    Text("全部技巧族").tag("")
                    ForEach(categories, id: \.self) { Text(LocalizedStringKey(Self.categoryNames[$0] ?? $0)).tag($0) }
                }.labelsHidden().frame(maxWidth: 160).accessibilityLabel("技巧族")
            }
            if !category.isEmpty || !search.isEmpty {
                HStack {
                    Text("\(visible.count) 项").font(.caption).foregroundColor(.secondary)
                    Spacer()
                    Button("全部启用") { setEnabled(visible, true, config) }.disabled(visible.isEmpty)
                    Button("全部停用") { setEnabled(visible, false, config) }.disabled(visible.isEmpty)
                }
            }
            ScrollViewReader { reader in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(visible, id: \.self) { i in
                            let rule = config.rules[i]
                            HStack {
                                Toggle(LocalizedStringKey(NativeHintTechnique(key: rule.kind).name), isOn: Binding(
                                    get: { enabled(rule) }, set: { setEnabled([i], $0, config) }
                                )).toggleStyle(CheckboxToggleStyle()).fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 8)
                                if section == .solver || section == .progress {
                                    Button { selected = rule.kind } label: {
                                        Image(systemName: section == .solver ? "slider.horizontal.3" : "arrow.up.arrow.down")
                                    }.buttonStyle(BorderlessButtonStyle()).accessibilityLabel("调整" + NativeHintTechnique(key: rule.kind).name)
                                }
                            }
                            .padding(.horizontal, 8).frame(minHeight: 28)
                            .background(selected == rule.kind ? Color.accentColor.opacity(0.12) : Color.clear)
                            .contentShape(Rectangle()).onTapGesture { selected = rule.kind }
                            .id(rule.kind)
                        }
                    }
                }
                .frame(minHeight: fillsHeight ? 0 : 208, maxHeight: fillsHeight ? .infinity : 208)
                .accessibilityIdentifier("settings-technique-list")
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(5).overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.secondary.opacity(0.28), lineWidth: 1))
                if (section == .solver || section == .progress), let i = visible.first(where: { config.rules[$0].kind == selected }),
                   let position = full.firstIndex(of: i) {
                    editor(config, index: i, order: full, position: position) { reader.scrollTo(selected, anchor: .center) }
                }
            }
        }
    }

    private func editor(_ config: NativeSolverConfig, index: Int, order: [Int], position: Int, reveal: @escaping () -> Void) -> some View {
        let rule = config.rules[index]
        return GroupBox(label: Text(LocalizedStringKey(NativeHintTechnique(key: rule.kind).name))) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("搜索顺序").foregroundColor(.secondary)
                    Text("\(position + 1) / \(order.count)").font(.body.monospacedDigit())
                    Spacer()
                    ForEach([-1, 1], id: \.self) { direction in
                        Button(direction == -1 ? "上移" : "下移") {
                            guard order.indices.contains(position + direction) else { return }
                            let other = order[position + direction]
                            preferences.changeSolver(config) { next in
                                let key: WritableKeyPath<NativeSolverConfig.Rule, Int> = section == .progress ? \.progressIndex : \.index
                                let value = next.rules[index][keyPath: key]
                                next.rules[index][keyPath: key] = next.rules[other][keyPath: key]
                                next.rules[other][keyPath: key] = value
                            }
                            reveal()
                        }.disabled(!order.indices.contains(position + direction))
                    }
                }
                if section == .solver {
                    SettingsColumns {
                        Picker("难度", selection: Binding(get: { rule.level }, set: { level in
                            preferences.changeSolver(config) { $0.rules[index].level = level }
                        })) {
                            ForEach(1...5, id: \.self) { Text(LocalizedStringKey(NativeBoardAppearance.levelNames[$0])).tag($0) }
                        }
                        SolverNumberField(label: "基础分", value: String(rule.score), range: 0...Int(Int32.max)) { value in
                            preferences.changeSolver(config) { $0.rules[index].score = value }
                        }.id(rule.kind)
                    }
                }
            }.padding(5)
        }
    }

    private func enabled(_ rule: NativeSolverConfig.Rule) -> Bool {
        switch section {
        case .training: return preferences.training.contains(rule.kind)
        case .progress: return rule.progressEnabled
        case .allSteps: return rule.allEnabled
        default: return rule.enabled
        }
    }
    private func setEnabled(_ indices: [Int], _ value: Bool, _ config: NativeSolverConfig) {
        if section == .training {
            let keys = Set(indices.map { config.rules[$0].kind })
            var next = preferences
            if value { next.training.formUnion(keys) } else { next.training.subtract(keys) }
            preferences = next
            return
        }
        preferences.changeSolver(config) { next in
            for i in indices {
                switch section {
                case .progress: next.rules[i].progressEnabled = value
                case .allSteps: next.rules[i].allEnabled = value
                default: next.rules[i].enabled = value
                }
            }
        }
    }

    @ViewBuilder private func optionRow(_ field: SolverOption, value: String, set: @escaping (String) -> Void) -> some View {
        switch field.control {
        case .toggle:
            Toggle(LocalizedStringKey(field.name), isOn: Binding(get: { value == "true" }, set: { set(String($0)) }))
                .fixedSize(horizontal: false, vertical: true)
        case .number(let range):
            if range.upperBound > 100 {
                SolverNumberField(label: field.name, value: value, range: range) { set(String($0)) }
            } else {
                Stepper(value: Binding(get: { Int(value) ?? range.lowerBound }, set: { set(String($0)) }), in: range) {
                    HStack {
                        Text(LocalizedStringKey(field.name))
                        Spacer(minLength: 8)
                        Text(value).font(.body.monospacedDigit())
                    }
                }
                .accessibilityLabel(Text(LocalizedStringKey(field.name)))
                .accessibilityValue(Text(value))
            }
        case .choices(let names):
            Picker(LocalizedStringKey(field.name), selection: Binding(get: { Int(value) ?? 0 }, set: { set(String($0)) })) {
                ForEach(names.indices, id: \.self) { Text(LocalizedStringKey(names[$0])).tag($0) }
            }
        case .digits:
            VStack(alignment: .leading, spacing: 6) {
                Text(LocalizedStringKey(field.name))
                HStack(spacing: 5) {
                    ForEach(0..<9) { i in
                        let bits = Array(value)
                        let checked = bits.indices.contains(i) && bits[i] == "1"
                        Button {
                            guard bits.count == 9 else { return }
                            var next = bits; next[i] = checked ? "0" : "1"; set(String(next))
                        } label: {
                            Text(String(i + 1)).frame(minWidth: 14)
                        }.buttonStyle(WorkbenchControlStyle(selected: checked, alignment: .center))
                         .accessibilityLabel("数字 \(i + 1)").accessibilityValue(checked ? "已选" : "未选")
                    }
                }
            }
        }
    }
}

private struct SolverNumberField: View {
    let label, value: String
    let range: ClosedRange<Int>
    let change: (Int) -> Void
    @State private var draft: String
    @State private var editing = false

    init(label: String, value: String, range: ClosedRange<Int>, change: @escaping (Int) -> Void) {
        self.label = label
        self.value = value
        self.range = range
        self.change = change
        _draft = State(initialValue: value)
    }

    var body: some View {
        HStack {
            Text(LocalizedStringKey(label))
            Spacer()
            TextField(LocalizedStringKey(label), text: Binding(get: { draft }, set: { input in
                draft = input
                if let number = Int(input), range.contains(number), number != Int(value) { change(number) }
            }), onEditingChanged: { active in
                editing = active
                if !active { draft = value }
            }, onCommit: { draft = value })
            .multilineTextAlignment(.trailing).frame(width: 82)
        }
        .onChange(of: value) { newValue in
            if !editing || Int(draft) != Int(newValue) { draft = newValue }
        }
    }
}
