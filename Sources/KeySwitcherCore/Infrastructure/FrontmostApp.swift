import AppKit
import Foundation

enum FrontmostApp {
    static var bundleID: String? {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }

    /// Terminals often ignore unicode injection / privateState backspace and have no AX value.
    static var isTerminalLike: Bool {
        guard let id = bundleID?.lowercased() else { return false }
        let needles = [
            "terminal",
            "iterm",
            "warp",
            "alacritty",
            "kitty",
            "wezterm",
            "hyper",
            "ghostty",
            "tabby",
            "rio.terminal"
        ]
        return needles.contains { id.contains($0) }
    }
}
