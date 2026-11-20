// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit

struct NativeWindowLayout: Codable {
    let frame: CGRect
    let toolbarVisible: Bool
    let fullScreen: Bool

    init(window: NSWindow, normalFrame: CGRect?) {
        fullScreen = window.styleMask.contains(.fullScreen)
        frame = fullScreen ? normalFrame ?? window.frame : window.frame
        toolbarVisible = window.toolbar?.isVisible ?? true
    }

    func visibleFrame(for window: NSWindow) -> CGRect {
        let screens = NSScreen.screens.map(\.visibleFrame)
        guard let main = NSScreen.main?.visibleFrame ?? screens.first else { return window.frame }
        func intersectionArea(_ screen: CGRect) -> CGFloat {
            let overlap = screen.intersection(frame)
            return overlap.isNull ? 0 : overlap.width * overlap.height
        }
        let screen = screens.filter { intersectionArea($0) > 0 }.max { intersectionArea($0) < intersectionArea($1) } ?? main
        let minimum = window.frameRect(forContentRect: CGRect(origin: .zero, size: window.contentMinSize)).size
        let width = min(screen.width, max(minimum.width, frame.width))
        let height = min(screen.height, max(minimum.height, frame.height))
        let origin = intersectionArea(screen) > 0 ? frame.origin : CGPoint(x: screen.midX - width / 2, y: screen.midY - height / 2)
        return CGRect(x: min(max(screen.minX, origin.x), screen.maxX - width),
                      y: min(max(screen.minY, origin.y), screen.maxY - height), width: width, height: height)
    }
}
