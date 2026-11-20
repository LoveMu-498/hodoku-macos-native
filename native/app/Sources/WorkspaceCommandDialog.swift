// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit

/// Native window modality handles pointer and command ownership. The explicit
/// key loop also includes action buttons when system Full Keyboard Access is off.
final class WorkspaceCommandDialog: NSPanel, NSTextFieldDelegate, NSTextViewDelegate {
    enum Input {
        case none
        case field(label: String, id: String)
        case text(label: String, id: String, value: String, editable: Bool)
        case choices(label: String, id: String, titles: [String])
    }

    private final class ActionButton: NSButton {
        override var acceptsFirstResponder: Bool { isEnabled }
    }

    private final class ChoiceButton: NSPopUpButton {
        override var acceptsFirstResponder: Bool { isEnabled }
    }

    private let options: NativeGeneralOptions
    private let primary = ActionButton()
    private let cancel = ActionButton()
    private let status = NSTextField(wrappingLabelWithString: "")
    private var field: NSTextField?
    private var editor: NSTextView?
    private var picker: NSPopUpButton?
    private var validating = false
    var submit: ((WorkspaceCommandDialog) -> Void)?
    var onCancel: (() -> Void)?
    var text: String { field?.stringValue ?? editor?.string ?? "" }
    var choice: Int { picker?.indexOfSelectedItem ?? -1 }

    init(options: NativeGeneralOptions, id: String, title: String, message: String, input: Input = .none,
         action: String, dismiss: String = "取消") {
        self.options = options
        let width: CGFloat = 440
        super.init(contentRect: NSRect(x: 0, y: 0, width: width, height: 180),
                   styleMask: [.titled], backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        self.title = options.localized(title)
        setAccessibilityIdentifier(id)

        let heading = NSTextField(labelWithString: self.title)
        heading.font = .systemFont(ofSize: 17, weight: .semibold)
        let description = NSTextField(wrappingLabelWithString: options.localized(message))
        description.textColor = .secondaryLabelColor
        description.preferredMaxLayoutWidth = width - 48

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 11
        stack.addArrangedSubview(heading)
        stack.addArrangedSubview(description)

        let inputView = makeInput(input)
        if let inputView { stack.addArrangedSubview(inputView) }
        status.textColor = .systemRed
        status.preferredMaxLayoutWidth = width - 48
        status.setAccessibilityIdentifier("workspace-dialog-status")
        stack.addArrangedSubview(status)
        status.isHidden = true

        configure(cancel, title: dismiss, id: "workspace-dialog-cancel", action: #selector(dismissDialog))
        cancel.keyEquivalent = "\u{1b}"
        let actionID = id == "workspace-point-add-dialog" ? "workspace-point-add" : id + "-action"
        configure(primary, title: action, id: actionID, action: #selector(submitDialog))
        primary.keyEquivalent = "\r"
        if editor?.isEditable == true { primary.keyEquivalentModifierMask = .command }
        defaultButtonCell = primary.cell as? NSButtonCell
        let actions = NSStackView(views: [cancel, primary])
        actions.spacing = 8
        let footer = NSView()
        footer.addSubview(actions)
        actions.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            actions.trailingAnchor.constraint(equalTo: footer.trailingAnchor),
            actions.leadingAnchor.constraint(greaterThanOrEqualTo: footer.leadingAnchor),
            actions.topAnchor.constraint(equalTo: footer.topAnchor),
            actions.bottomAnchor.constraint(equalTo: footer.bottomAnchor)
        ])
        stack.addArrangedSubview(footer)
        stack.setCustomSpacing(16, after: status)
        let content = NSView()
        content.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -18),
            footer.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        if let inputView { inputView.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        contentView = content
        setContentSize(NSSize(width: width, height: stack.fittingSize.height + 38))
        updatePrimary()
        let first = inputControl ?? (primary.isEnabled ? primary : cancel)
        initialFirstResponder = first
        makeFirstResponder(first)
    }

    private var inputControl: NSView? {
        if let field { return field }
        if let editor { return editor }
        return picker
    }

    private func makeInput(_ input: Input) -> NSView? {
        switch input {
        case .none: return nil
        case let .field(label, id):
            let entry = NSTextField(string: "")
            entry.placeholderString = options.localized(label)
            entry.setAccessibilityLabel(options.localized(label))
            entry.setAccessibilityIdentifier(id)
            entry.delegate = self
            field = entry
            return entry
        case let .text(label, id, value, editable):
            let scroll = NSTextView.scrollableTextView()
            scroll.borderType = .bezelBorder
            scroll.heightAnchor.constraint(equalToConstant: editable ? 116 : 58).isActive = true
            let text = scroll.documentView as! NSTextView
            text.string = value
            text.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
            text.isRichText = false
            text.isEditable = editable
            text.isAutomaticQuoteSubstitutionEnabled = false
            text.isAutomaticDashSubstitutionEnabled = false
            text.isAutomaticTextReplacementEnabled = false
            text.textContainerInset = NSSize(width: 6, height: 6)
            text.setAccessibilityLabel(options.localized(label))
            text.setAccessibilityIdentifier(id)
            text.delegate = self
            editor = text
            return scroll
        case let .choices(label, id, titles):
            guard !titles.isEmpty else {
                primary.isEnabled = false
                return nil
            }
            let list = ChoiceButton()
            list.addItems(withTitles: titles)
            list.setAccessibilityLabel(options.localized(label))
            list.setAccessibilityIdentifier(id)
            picker = list
            return list
        }
    }

    private func configure(_ button: NSButton, title: String, id: String, action: Selector) {
        button.title = options.localized(title)
        button.bezelStyle = .rounded
        button.target = self
        button.action = action
        button.setAccessibilityIdentifier(id)
    }

    func controlTextDidChange(_ notification: Notification) { updatePrimary() }
    func textDidChange(_ notification: Notification) { updatePrimary() }

    private func updatePrimary() {
        if field != nil || editor?.isEditable == true {
            primary.isEnabled = !validating && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    func setValidating(_ active: Bool) {
        validating = active
        editor?.isEditable = !active
        primary.isEnabled = !active && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if active { showStatus("正在检查题目…", failure: false) }
        else if let editor { makeFirstResponder(editor) }
    }

    func showError(_ error: Error) {
        showStatus(error.localizedDescription, failure: true)
    }

    private func showStatus(_ message: String, failure: Bool) {
        status.stringValue = options.localized(message)
        status.textColor = failure ? .systemRed : .secondaryLabelColor
        status.isHidden = false
        if let content = contentView, let stack = content.subviews.first as? NSStackView {
            stack.layoutSubtreeIfNeeded()
            setContentSize(NSSize(width: content.bounds.width, height: stack.fittingSize.height + 38))
        }
        NSAccessibility.post(element: status, notification: .valueChanged)
    }

    override func sendEvent(_ event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.shift, .command, .control, .option])
        if event.type == .keyDown {
            if event.keyCode == 48, modifiers.isSubset(of: .shift) {
                let targets = [inputControl, cancel, primary.isEnabled ? primary : nil].compactMap { $0 }
                let current = targets.firstIndex(where: { target in
                    target === firstResponder || (target as? NSTextField)?.currentEditor() === firstResponder
                })
                let backwards = modifiers.contains(.shift)
                let start = current ?? (backwards ? 0 : targets.count - 1)
                let next = (start + (backwards ? -1 : 1) + targets.count) % targets.count
                makeFirstResponder(targets[next])
                return
            }
            if event.keyCode == 53, modifiers.isEmpty { dismissDialog(); return }
            if [36, 76].contains(event.keyCode), modifiers == .command, editor != nil, primary.isEnabled {
                submitDialog()
                return
            }
        }
        super.sendEvent(event)
    }

    func complete() { sheetParent?.endSheet(self, returnCode: .OK) }

    @objc private func submitDialog() { if primary.isEnabled { submit?(self) } }
    @objc private func dismissDialog() {
        onCancel?()
        sheetParent?.endSheet(self, returnCode: .cancel)
    }
}
