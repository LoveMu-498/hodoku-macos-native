// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import Combine
import SwiftUI

final class SettingsSearch: ObservableObject {
    @Published var text = ""
}

final class NativeSettingsPanel: NSPanel, NSSearchFieldDelegate {
    private final class DoneButton: NSButton {
        override var acceptsFirstResponder: Bool { isEnabled }
    }

    private let search = NSSearchField()
    private let done = DoneButton()
    private let heading = NSTextField(labelWithString: "")
    private let feedback = NSTextField(labelWithString: "")
    private let query = SettingsSearch()
    private var preferenceChanges: AnyCancellable?

    static func dialogSize(in available: NSSize) -> NSSize {
        NSSize(width: max(1, min(824, available.width - 32)),
               height: max(1, min(630, available.height - 40)))
    }

    init(workspace: NativeDesktopWorkspace, size: NSSize) {
        super.init(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        setAccessibilityIdentifier("workspace-settings-dialog")
        autorecalculatesKeyViewLoop = true
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { animationBehavior = .none }
        search.delegate = self
        search.setAccessibilityIdentifier("settings-search")
        search.widthAnchor.constraint(equalToConstant: size.width >= 650 ? 198 : 142).isActive = true
        search.controlSize = .regular
        heading.font = .systemFont(ofSize: 16, weight: .semibold)
        feedback.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        feedback.textColor = .secondaryLabelColor

        done.target = self
        done.action = #selector(finish)
        done.bezelStyle = .rounded
        done.setAccessibilityIdentifier("workspace-inspector-back")

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let bar = NSStackView(views: [heading, spacer, search])
        bar.spacing = 12
        bar.alignment = .centerY

        let footer = NSStackView(views: [feedback, NSView(), done])
        footer.spacing = 12
        footer.alignment = .centerY

        let detail = NSHostingView(rootView: SettingsContent(workspace: workspace, search: query))
        let topLine = NSBox()
        topLine.boxType = .separator
        let bottomLine = NSBox()
        bottomLine.boxType = .separator
        let root = NSView()
        for child in [bar, topLine, detail, bottomLine, footer] {
            child.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(child)
        }
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: root.topAnchor),
            bar.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18),
            bar.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -18),
            bar.heightAnchor.constraint(equalToConstant: 46),
            topLine.topAnchor.constraint(equalTo: bar.bottomAnchor),
            topLine.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            topLine.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            detail.topAnchor.constraint(equalTo: topLine.bottomAnchor),
            detail.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            detail.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            detail.bottomAnchor.constraint(equalTo: bottomLine.topAnchor),
            bottomLine.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            bottomLine.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            bottomLine.bottomAnchor.constraint(equalTo: footer.topAnchor),
            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18),
            footer.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -18),
            footer.heightAnchor.constraint(equalToConstant: 45),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])
        contentView = root
        contentMinSize = size
        contentMaxSize = size
        setContentSize(size)
        initialFirstResponder = search
        makeFirstResponder(search)
        preferenceChanges = workspace.$preferences.sink { [weak self] preferences in
            self?.updateLanguage(preferences.general ?? NativeGeneralOptions())
        }
    }

    private func updateLanguage(_ options: NativeGeneralOptions) {
        title = options.localized("设置")
        heading.stringValue = title
        search.placeholderString = options.localized("查找设置分类")
        search.setAccessibilityLabel(search.placeholderString)
        feedback.stringValue = options.localized("更改即时保存")
        done.title = options.localized("完成")
    }

    func controlTextDidChange(_ obj: Notification) { query.text = search.stringValue }

    private var searchHasFocus: Bool {
        guard let firstResponder else { return false }
        return firstResponder === search || firstResponder === search.currentEditor()
    }

    override func sendEvent(_ event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if event.type == .keyDown, event.keyCode == 53, modifiers.isEmpty {
            finish()
            return
        }
        if event.type == .keyDown, event.keyCode == 48, modifiers.isSubset(of: .shift) {
            let backwards = modifiers.contains(.shift)
            if backwards && searchHasFocus {
                makeFirstResponder(done)
                return
            }
            if !backwards && firstResponder === done {
                makeFirstResponder(search)
                return
            }
            let beganInSearch = searchHasFocus
            super.sendEvent(event)
            if beganInSearch && searchHasFocus { makeFirstResponder(done) }
            return
        }
        super.sendEvent(event)
    }

    @objc private func finish() {
        // Text fields commit pending values when focus leaves the editor.
        guard makeFirstResponder(done) else { return }
        sheetParent?.endSheet(self, returnCode: .OK)
    }
}

private struct SettingsContent: View {
    @ObservedObject var workspace: NativeDesktopWorkspace
    @ObservedObject var search: SettingsSearch
    var body: some View {
        let options = workspace.preferences.general ?? NativeGeneralOptions()
        NativeSettingsView(workspace: workspace, search: search)
            .environment(\.locale, options.locale)
            .font(options.useDefaultFontSize ? .body : .system(size: CGFloat(options.customFontSize)))
    }
}
