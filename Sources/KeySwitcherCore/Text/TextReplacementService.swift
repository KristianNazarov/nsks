import AppKit
import Foundation

/// Posts synthetic keystrokes marked as synthetic.
/// Uses a private event source and explicit flags so physically held modifiers
/// do not leak into injected events.
public final class TextReplacementService {
    public static let maxDeleteCount = 64

    private let accessibility = AccessibilityTextService()
    private let clipboard = ClipboardTextService()

    public init() {}

    public func deleteCharacters(count: Int, useHID: Bool = false) {
        let n = min(max(0, count), Self.maxDeleteCount)
        guard n > 0 else { return }
        SyntheticEventGuard.shared.withSynthetic {
            let source = CGEventSource(stateID: useHID ? .hidSystemState : .privateState)
            source?.localEventsSuppressionInterval = 0
            let delay = useHID ? 0.018 : 0.008
            for _ in 0..<n {
                postKey(keyCode: 51, keyDown: true, flags: [], source: source) // Backspace
                postKey(keyCode: 51, keyDown: false, flags: [], source: source)
                Thread.sleep(forTimeInterval: delay)
            }
        }
    }

    public func typeText(_ text: String, useHID: Bool = false) {
        guard !text.isEmpty else { return }
        SyntheticEventGuard.shared.withSynthetic {
            let source = CGEventSource(stateID: useHID ? .hidSystemState : .privateState)
            source?.localEventsSuppressionInterval = 0
            for ch in text {
                postUnicode(ch, source: source)
                Thread.sleep(forTimeInterval: 0.004)
            }
        }
    }

    /// Returns `true` only when the UI was actually updated (best-effort in terminals).
    @discardableResult
    public func replaceLastWord(deleteCount: Int, insert: String, expected: String) -> Bool {
        Thread.sleep(forTimeInterval: 0.08)
        let n = min(max(0, deleteCount), Self.maxDeleteCount)
        guard n > 0, !expected.isEmpty else { return false }

        if FrontmostApp.isTerminalLike {
            AppLogger.info("Last word: terminal-like app (\(FrontmostApp.bundleID ?? "?"))")
            return replaceLastWordInTerminal(deleteCount: n, insert: insert, expected: expected)
        }

        // If the word is already selected, just replace it
        if let sel = accessibility.selectedText(), Self.matchesSelection(sel, expected: expected) {
            if accessibility.setSelectedText(insert) { return true }
            if clipboard.syncPasteOverSelection(insert) { return true }
        }
        if case .present(let len) = accessibility.selectionPresence(),
           len == expected.utf16.count || len == n {
            if accessibility.setSelectedText(insert) { return true }
            if clipboard.syncPasteOverSelection(insert) { return true }
        }

        if accessibility.replaceInFocusedValue(original: expected, replacement: insert) {
            return true
        }

        if accessibility.selectBeforeCaret(count: n) {
            let confirmed: Bool = {
                if let sel = accessibility.selectedText(), Self.matchesSelection(sel, expected: expected) {
                    return true
                }
                if case .present(let len) = accessibility.selectionPresence() {
                    return len == n || len == expected.utf16.count
                }
                return false
            }()
            if confirmed {
                if accessibility.setSelectedText(insert) { return true }
                if clipboard.syncPasteOverSelection(insert) { return true }
            }
            accessibility.collapseSelectionToEnd()
        }

        if let lenBefore = accessibility.focusedValueUTF16Length(), lenBefore < 100_000 {
            deleteCharacters(count: n)
            Thread.sleep(forTimeInterval: 0.04)
            if let lenAfter = accessibility.focusedValueUTF16Length(), lenAfter <= lenBefore - min(n, lenBefore) {
                if clipboard.syncPasteOverSelection(insert) { return true }
                typeText(insert)
                return true
            }
            AppLogger.warning("Last word: verified backspace failed")
            return false
        }

        deleteCharacters(count: n)
        Thread.sleep(forTimeInterval: 0.03)
        if clipboard.syncPasteOverSelection(insert) { return true }
        typeText(insert)
        return true
    }

    /// Terminal.app / iTerm / Warp: never send arrow keys for deletion — they become CSI (`;2D`).
    /// Prefer readline Ctrl+W (one reliable keystroke), then paste. One → after paste clears
    /// Terminal’s “select pasted text” highlight without hurting the PTY when already at EOL.
    private func replaceLastWordInTerminal(deleteCount n: Int, insert: String, expected: String) -> Bool {
        _ = expected
        Thread.sleep(forTimeInterval: 0.06)

        postControlKey("w")
        Thread.sleep(forTimeInterval: 0.1)
        pasteOrTypeInTerminal(insert)
        // Terminal selects pasted text; dismiss highlight (at EOL → is a no-op for the shell).
        Thread.sleep(forTimeInterval: 0.04)
        postArrowRight()
        AppLogger.info("Terminal last word: Ctrl+W + paste/type (buffer had \(n) chars)")
        return true
    }

    private func pasteOrTypeInTerminal(_ insert: String) {
        let pasteboard = NSPasteboard.general
        let saved = clipboard.savePasteboard(pasteboard)
        if clipboard.writeVerifiedForTerminal(insert) {
            Thread.sleep(forTimeInterval: 0.05)
            postTerminalPaste()
            // Keep pasteboard until Terminal consumes Cmd+V
            Thread.sleep(forTimeInterval: 0.2)
            clipboard.restorePasteboard(pasteboard, items: saved)
            return
        }
        clipboard.restorePasteboard(pasteboard, items: saved)
        typeText(insert, useHID: true)
    }

    private func postTerminalPaste() {
        SyntheticEventGuard.shared.withSynthetic {
            let source = CGEventSource(stateID: .hidSystemState)
            source?.localEventsSuppressionInterval = 0
            postKey(keyCode: 9, keyDown: true, flags: .maskCommand, source: source) // V
            postKey(keyCode: 9, keyDown: false, flags: .maskCommand, source: source)
        }
    }

    private func postArrowRight() {
        SyntheticEventGuard.shared.withSynthetic {
            let source = CGEventSource(stateID: .hidSystemState)
            source?.localEventsSuppressionInterval = 0
            postKey(keyCode: 124, keyDown: true, flags: [], source: source)
            postKey(keyCode: 124, keyDown: false, flags: [], source: source)
        }
    }

    private func postControlKey(_ key: String) {
        let keyCode: CGKeyCode
        switch key.lowercased() {
        case "w": keyCode = 13
        case "u": keyCode = 32
        case "h": keyCode = 4
        default: return
        }
        SyntheticEventGuard.shared.withSynthetic {
            let source = CGEventSource(stateID: .hidSystemState)
            source?.localEventsSuppressionInterval = 0
            postKey(keyCode: keyCode, keyDown: true, flags: .maskControl, source: source)
            postKey(keyCode: keyCode, keyDown: false, flags: .maskControl, source: source)
        }
    }

    private static func matchesSelection(_ selected: String, expected: String) -> Bool {
        let a = selected.trimmingCharacters(in: .whitespacesAndNewlines)
        let b = expected.trimmingCharacters(in: .whitespacesAndNewlines)
        return a == b || selected == expected
    }

    private func postKey(keyCode: CGKeyCode, keyDown: Bool, flags: CGEventFlags, source: CGEventSource?) {
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: keyDown) else { return }
        event.flags = flags
        SyntheticEventMarker.mark(event)
        event.post(tap: .cghidEventTap)
    }

    private func postUnicode(_ character: Character, source: CGEventSource?) {
        let string = String(character)
        var utf16 = Array(string.utf16)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else {
            return
        }
        down.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
        up.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
        down.flags = []
        up.flags = []
        SyntheticEventMarker.mark(down)
        SyntheticEventMarker.mark(up)
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }
}
