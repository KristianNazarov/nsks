import AppKit
import SwiftUI

/// Brings the hosting window to the front when a menu-bar accessory app opens Settings.
struct WindowFronting: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            Self.bringToFront(view.window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            Self.bringToFront(nsView.window)
        }
    }

    static func bringToFront(_ window: NSWindow?) {
        guard let window else { return }
        NSApp.activate(ignoringOtherApps: true)
        window.collectionBehavior.insert(.moveToActiveSpace)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }
}

public extension View {
    func keySwitcherBringWindowToFront() -> some View {
        background(WindowFronting().frame(width: 0, height: 0))
    }
}
