// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import Combine

final class NativeHintWindowController: ObservableObject {
    @Published private(set) var centerOffset: CGFloat = 0
    weak var window: NSWindow?
    private var chrome: CGFloat = 0
    private var layout: ((CGSize) -> NativeHintLayout?)?
    private var scheduled = false

    func update(area: CGSize, layout: ((CGSize) -> NativeHintLayout?)?) {
        self.layout = layout
        if let content = window?.contentView, abs(content.bounds.width - area.width) < 1 {
            chrome = max(0, content.bounds.height - area.height)
        }
        scheduleExpansion()
    }

    func clear() { layout = nil }

    func constrainedSize(_ proposed: CGSize, for window: NSWindow) -> CGSize {
        guard window === self.window, let visible = window.screen?.visibleFrame,
              window.attachedSheet == nil, !window.styleMask.contains(.fullScreen) else { return proposed }
        return CGSize(width: requiredWidth(proposed, window: window, visible: visible), height: proposed.height)
    }

    func scheduleExpansion() {
        guard layout != nil, !scheduled else { return }
        scheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.scheduled = false
            guard let window = self.window, let visible = window.screen?.visibleFrame,
                  !window.inLiveResize, window.attachedSheet == nil, !window.styleMask.contains(.fullScreen) else { return }
            self.expand(window, within: visible)
        }
    }

    func expand(_ window: NSWindow, within visible: CGRect) {
        let frame = window.frame
        let width = requiredWidth(frame.size, window: window, visible: visible)
        guard width > frame.width else { return }
        let expanded = NativeHintWindowWidth.frame(for: width, current: frame, visible: visible)
        if expanded.midX != frame.midX { centerOffset += expanded.midX - frame.midX }
        window.setFrame(expanded, display: true)
    }

    private func requiredWidth(_ proposed: CGSize, window: NSWindow, visible: CGRect) -> CGFloat {
        guard let layout, proposed.width < visible.width else { return proposed.width }
        let content = window.contentRect(forFrameRect: CGRect(origin: .zero, size: proposed)).size
        let inset = proposed.width - content.width
        let area = CGSize(width: content.width, height: max(0, content.height - chrome))
        guard let current = layout(area), current.exceedsOverlapLimit else { return proposed.width }
        return NativeHintWindowWidth.expanded(from: area, to: visible.width - inset) { layout($0) ?? current } + inset
    }
}
