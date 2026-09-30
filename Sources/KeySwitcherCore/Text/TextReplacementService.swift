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

    public func deleteCharacters(count: Int) {
        let n = min(max(0, count), Self.maxDeleteCount)
        guard n > 0 else { return }
        SyntheticEventGuard.shared.withSynthetic {
            let source = CGEventSource(stateID: .privateState)
            source?.localEventsSuppressionInterval = 0
            for _ in 0..<n {
                postKey(keyCode: 51, keyDown: true, flags: [], source: source) // Backspace
                postKey(keyCode: 51, keyDown: false, flags: [], source: source)
                Thread.sleep(forTimeInterval: 0.008)
            }
        }
    }

    public func typeText(_ text: String) {
        guard !text.isEmpty else { return }
        SyntheticEventGuard.shared.withSynthetic {
            let source = CGEventSource(stateID: .privateState)
            source?.localEventsSuppressionInterval = 0
            for ch in text {
                postUnicode(ch, source: source)
                Thread.sleep(forTimeInterval: 0.001)
            }
        }
    }

    /// Returns `true` only when the UI was actually updated.
    @discardableResult
    public func replaceLastWord(deleteCount: Int, insert: String, expected: String) -> Bool {
        Thread.sleep(forTimeInterval: 0.08)
        let n = min(max(0, deleteCount), Self.maxDeleteCount)
        guard n > 0, !expected.isEmpty else { return false }

        // If the word is already selected, just replace it — never re-select "before caret"
        // (that expands upward in Sublime when location is the selection start).
        if let sel = accessibility.selectedText(), Self.matchesSelection(sel, expected: expected) {
            if accessibility.setSelectedText(insert) { return true }
            if clipboard.syncPasteOverSelection(insert) { return true }
        }
        if case .present(let len) = accessibility.selectionPresence(),
           len == expected.utf16.count || len == n {
            if accessibility.setSelectedText(insert) { return true }
            if clipboard.syncPasteOverSelection(insert) { return true }
        }

        // AX value replace when available (skip enormous buffers)
        if accessibility.replaceInFocusedValue(original: expected, replacement: insert) {
            return true
        }

        // Select exactly `n` chars ending at caret/selection-end, then paste
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
            // Never leave a dangling selection for the next hotkey press
            accessibility.collapseSelectionToEnd()
        }

        // Backspace + paste (modifiers are up). Prefer length check when AX value exists.
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

        // Sublime large files / no AX value: backspace + paste (no ⌥⇧← — it grows selection).
        deleteCharacters(count: n)
        Thread.sleep(forTimeInterval: 0.03)
        if clipboard.syncPasteOverSelection(insert) { return true }
        typeText(insert)
        return true
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
