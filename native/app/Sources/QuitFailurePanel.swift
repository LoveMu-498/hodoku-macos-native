// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import SwiftUI

enum QuitChoice { case retry, cancel, discard }

final class QuitFailurePanel: NSPanel {
    static let toastID = "workspace-quit-failure-toast"

    private final class ActionButton: NSButton {
        override var acceptsFirstResponder: Bool { true }
    }

    private let options: NativeGeneralOptions
    private let board: NativeBoardModel
    private let respond: (QuitChoice) -> Void
    private let details: NSHostingView<QuitFailureDetails>
    private let discard = ActionButton()
    private let cancel = ActionButton()
    private let retry = ActionButton()
    private var actions: [NSButton] { [discard, cancel, retry] }

    init(failure: String, board: NativeBoardModel, respond: @escaping (QuitChoice) -> Void) {
        let options = board.generalOptions
        self.options = options
        self.board = board
        self.respond = respond
        details = NSHostingView(rootView: QuitFailureDetails(failure: failure, options: options, board: board))
        let compactSize = NSSize(width: 446, height: 302)
        super.init(contentRect: NSRect(origin: .zero, size: compactSize),
                   styleMask: [.titled], backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        title = options.localized("退出前保存失败")
        setAccessibilityIdentifier("workspace-quit-dialog")
        configure(discard, "仍然退出", id: "discard", action: #selector(discardChanges))
        discard.contentTintColor = .systemRed
        configure(cancel, "取消退出", id: "cancel", action: #selector(cancelQuit))
        cancel.keyEquivalent = "\u{1b}"
        configure(retry, "重试保存", id: "retry", action: #selector(retrySave))
        defaultButtonCell = retry.cell as? NSButtonCell
        retry.keyEquivalent = "\r"

        let buttons = NSStackView(views: actions)
        buttons.orientation = .horizontal
        buttons.spacing = 10
        let content = NSView()
        content.addSubview(details)
        content.addSubview(buttons)
        details.translatesAutoresizingMaskIntoConstraints = false
        buttons.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            details.topAnchor.constraint(equalTo: content.topAnchor, constant: 23),
            details.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            details.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            details.bottomAnchor.constraint(equalTo: buttons.topAnchor, constant: -16),
            buttons.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            buttons.leadingAnchor.constraint(greaterThanOrEqualTo: content.leadingAnchor, constant: 24),
            buttons.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -19)
        ])
        contentView = content
        contentMinSize = compactSize
        contentMaxSize = compactSize
        setContentSize(compactSize)
        initialFirstResponder = retry
        makeFirstResponder(retry)
    }

    func updateFailure(_ failure: String) {
        details.rootView = QuitFailureDetails(failure: failure, options: options, board: board)
    }

    override func sendEvent(_ event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.shift, .command, .control, .option])
        if event.type == .keyDown, event.keyCode == 48, modifiers.isSubset(of: .shift) {
            let current = actions.firstIndex { $0 === firstResponder } ?? actions.count - 1
            let next = (current + (modifiers.contains(.shift) ? -1 : 1) + actions.count) % actions.count
            makeFirstResponder(actions[next])
            return
        }
        super.sendEvent(event)
    }

    private func configure(_ button: NSButton, _ title: String, id: String, action: Selector) {
        button.title = options.localized(title)
        button.bezelStyle = .rounded
        button.target = self
        button.action = action
        button.setAccessibilityIdentifier("workspace-quit-" + id)
    }

    @objc private func retrySave() { respond(.retry) }
    @objc private func cancelQuit() { respond(.cancel) }
    @objc private func discardChanges() { respond(.discard) }
}

private struct QuitFailureDetails: View {
    private struct Issue: Identifiable {
        let reason: String
        var objects: [String]
        var id: String { reason }
    }

    let failure: String
    let options: NativeGeneralOptions
    @ObservedObject var board: NativeBoardModel

    private var issues: [Issue] {
        var result: [Issue] = []
        for line in failure.split(separator: "\n") {
            let parts = line.split(separator: "　", maxSplits: 1).map(String.init)
            let reason = parts.count == 2 ? parts[1] : String(line)
            let objects = parts.count == 2 ? [options.localized(parts[0])] : []
            if let index = result.firstIndex(where: { $0.reason == reason }) {
                result[index].objects.append(contentsOf: objects)
            } else {
                result.append(Issue(reason: reason, objects: objects))
            }
        }
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 25, weight: .medium))
                    .foregroundColor(.orange)
                    .accessibilityHidden(true)
                Group {
                    if board.operationMessageID == QuitFailurePanel.toastID, let message = board.operationMessage {
                        NativeOperationToast(message: message, tone: .failure, identifier: QuitFailurePanel.toastID)
                    } else {
                        Text("退出前保存失败").font(.title3).fontWeight(.semibold)
                    }
                }.frame(height: 28).accessibilityAddTraits(.isHeader)
            }
            Text("重试保存，或取消退出以返回当前工作台。")
                .fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(issues) { issue in
                        VStack(alignment: .leading, spacing: 3) {
                            if !issue.objects.isEmpty { Text(issue.objects.joined(separator: " / ")).fontWeight(.semibold) }
                            Text(issue.reason).foregroundColor(.secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }.padding(10)
            }
            .frame(height: 82)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.055)))
            .accessibilityIdentifier("workspace-quit-issues")
            Text("仍然退出可能会丢失上面未保存的更改。")
                .fixedSize(horizontal: false, vertical: true)
                .foregroundColor(.secondary)
        }
        .font(.system(size: 13))
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .environment(\.locale, options.locale)
    }
}

struct WorkspaceModalBackdrop: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        ZStack {
            if reduceTransparency { Color(NSColor.windowBackgroundColor).opacity(0.9) }
            else { FrostedWorkspace().opacity(0.55) }
            Color.black.opacity(0.10)
        }.accessibilityHidden(true).allowsHitTesting(false)
    }
}

private struct FrostedWorkspace: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let blur = NSVisualEffectView()
        blur.material = .popover
        blur.blendingMode = .withinWindow
        blur.state = .active
        return blur
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}
