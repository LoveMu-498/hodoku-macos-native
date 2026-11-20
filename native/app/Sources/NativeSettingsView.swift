// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import SwiftUI

private enum SettingsTopic: String, CaseIterable, Identifiable {
    case general, levelsFonts, colors, colorku, solver, steps, allSteps, progress, training, generator
    var id: Self { self }

    var item: (title: String, icon: String, keywords: String) {
        switch self {
        case .general: return ("通用", "gearshape", "语言 外观 主题 深色 浅色 鼠标 单击 双击 操作音效 候选数 高亮 筛选 区域 光标 窗口 历史 版式 字号 提示")
        case .levelsFonts: return ("难度与字体", "textformat.size", "级别 等级 名称 分数 评分 上限 字体 字号 前景 背景 大小 比例 线宽")
        case .colors: return ("棋盘配色", "paintpalette", "颜色 数字 题面 格子 候选数 选中 高亮 删除 提示 边框 网格 ALS 着色")
        case .colorku: return ("彩色数独", "circle.grid.3x3", "ColorKu 数字 色球 调色盘 偏差 错误")
        case .solver: return ("求解顺序与评分", "list.number", "求解器 技巧 启用 顺序 分值 排序 步骤 难度")
        case .steps: return ("技巧选项", "slider.horizontal.3", "求解步骤 链 鱼 鳍 模板 ALS 唯一性 训练 Death Blossom 缓存")
        case .allSteps: return ("查找全部步骤", "magnifyingglass", "查找 所有技巧 候选数字 普通鱼 海怪鱼 Kraken ALS 范围 鱼鳍 长度")
        case .progress: return ("进度评估", "chart.bar", "进度提示 解题 评分 技巧 启用 顺序 预设")
        case .training: return ("训练技巧", "graduationcap", "学习 练习 模式 特定技巧")
        case .generator: return ("出题与图案", "square.grid.3x3", "新题 难度 普通 学习 练习 生成器 给定数 题型 模式 .hpat 导入 导出 唯一解")
        }
    }

    var isTechniqueList: Bool {
        self == .solver || self == .progress || self == .training
    }

    static let groups: [(String, [Self])] = [
        ("工作台", [.general, .levelsFonts, .colors, .colorku]),
        ("求解", [.solver, .steps, .allSteps, .progress]),
        ("新题", [.training, .generator])
    ]

    func matches(_ query: String, options: NativeGeneralOptions) -> Bool {
        query.isEmpty || (options.localized(item.title) + " " + item.title + " " + item.keywords).localizedCaseInsensitiveContains(query)
    }
}

struct NativeSettingsView: View {
    @ObservedObject var workspace: NativeDesktopWorkspace
    @State private var topic = SettingsTopic.general
    @ObservedObject var search: SettingsSearch
    @State private var failure: String?
    @State private var retry: NativeWorkspacePreferences?

    private var query: String { search.text.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var results: [SettingsTopic] { SettingsTopic.allCases.filter { $0.matches(query, options: workspace.board.generalOptions) } }

    private var preferences: Binding<NativeWorkspacePreferences> {
        Binding(get: { workspace.preferences }, set: apply)
    }

    private func apply(_ value: NativeWorkspacePreferences) {
        guard value != workspace.preferences else { return }
        do {
            var next = value
            if next.historyLimit < workspace.preferences.historyLimit {
                next.history = Array(next.history.prefix(next.historyLimit))
            }
            try workspace.updatePreferences(next)
            failure = nil
            retry = nil
        } catch {
            failure = error.localizedDescription
            retry = value
        }
    }

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                if geometry.size.width >= 650 {
                    HStack(spacing: 0) {
                        sidebar.frame(width: 174)
                        Divider()
                        detail
                    }
                } else {
                    if !results.isEmpty {
                        Picker("设置分类", selection: $topic) {
                            ForEach(results) { item in Text(LocalizedStringKey(item.item.title)).tag(item) }
                        }.accessibilityIdentifier("settings-category")
                        .padding(.horizontal, 16).padding(.vertical, 8).frame(maxWidth: .infinity, alignment: .leading)
                        Divider()
                    }
                    detail
                }
                if let failure = failure {
                    Divider()
                    HStack {
                        Image(systemName: "exclamationmark.triangle")
                        Text("设置未能生效。"+failure)
                        Spacer()
                        if let value = retry { Button("重试") { apply(value) } }
                    }.padding(10)
                }
            }
            .onChange(of: query) { _ in
                if !results.contains(topic), let first = results.first { topic = first }
            }
        }
    }

    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(SettingsTopic.groups.indices, id: \.self) { index in
                    let items = SettingsTopic.groups[index].1.filter(results.contains)
                    if !items.isEmpty {
                        Text(LocalizedStringKey(SettingsTopic.groups[index].0)).font(.caption.weight(.semibold))
                            .foregroundColor(.secondary).padding(.leading, 8).padding(.top, 12)
                        ForEach(items) { item in
                            Button { topic = item } label: {
                                HStack(spacing: 9) {
                                    Image(systemName: item.item.icon).frame(width: 21).foregroundColor(.accentColor)
                                    Text(LocalizedStringKey(item.item.title))
                                    Spacer(minLength: 0)
                                }.padding(.vertical, 6).padding(.horizontal, 8)
                                .contentShape(Rectangle())
                            }.buttonStyle(WorkbenchControlStyle(selected: topic == item, alignment: .leading))
                            .accessibilityIdentifier("settings-topic-" + item.rawValue)
                            .accessibilityAddTraits(item == topic ? .isSelected : [])
                        }
                    }
                }
            }.padding(.horizontal, 10).padding(.bottom, 16)
        }.background(Color.primary.opacity(0.025))
    }

    @ViewBuilder private var detail: some View {
        if results.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "magnifyingglass").font(.title)
                Text("没有匹配的设置分类")
                Button("清除搜索") { search.text = "" }
            }.foregroundColor(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            GeometryReader { geometry in
                let fillsHeight = topic.isTechniqueList && geometry.size.height >= 340
                if fillsHeight {
                    detailContent(fillsHeight: true)
                } else {
                    ScrollView { detailContent(fillsHeight: false) }
                }
            }.id(topic)
        }
    }

    private func detailContent(fillsHeight: Bool) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(LocalizedStringKey(topic.item.title)).font(.system(size: 19, weight: .semibold))
                .accessibilityAddTraits(.isHeader).accessibilityIdentifier("settings-heading-" + topic.rawValue)
            page(fillsHeight: fillsHeight)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 20).padding(.vertical, 16)
    }

    @ViewBuilder private func page(fillsHeight: Bool) -> some View {
        switch topic {
        case .general: NativeGeneralSettingsPage(preferences: preferences)
        case .levelsFonts: NativeAppearanceSettingsPage(section: .levelsFonts, preferences: preferences)
        case .colors: NativeAppearanceSettingsPage(section: .colors, preferences: preferences)
        case .colorku: NativeAppearanceSettingsPage(section: .colorku, preferences: preferences)
        case .solver: NativeSolverSettingsPage(section: .solver, preferences: preferences, config: workspace.board.solverConfig, fillsHeight: fillsHeight)
        case .steps: NativeSolverSettingsPage(section: .steps, preferences: preferences, config: workspace.board.solverConfig)
        case .allSteps: NativeSolverSettingsPage(section: .allSteps, preferences: preferences, config: workspace.board.solverConfig)
        case .progress: NativeSolverSettingsPage(section: .progress, preferences: preferences, config: workspace.board.solverConfig, fillsHeight: fillsHeight)
        case .training: NativeSolverSettingsPage(section: .training, preferences: preferences, config: workspace.board.solverConfig, fillsHeight: fillsHeight)
        case .generator: NativeGeneratorSettingsPage(preferences: preferences, config: workspace.board.solverConfig,
            showTraining: { topic = .training; search.text = "" })
        }
    }
}

struct SettingsColumns<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 232), spacing: 18, alignment: .leading)],
                  alignment: .leading, spacing: 9) {
            content
        }
    }
}
