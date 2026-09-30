import AppKit
import Foundation

public enum TextAcquireMethod: String, Sendable {
    case accessibility
    case clipboard
}

public struct AcquiredText: Sendable {
    public let text: String
    public let method: TextAcquireMethod

    public init(text: String, method: TextAcquireMethod) {
        self.text = text
        self.method = method
    }
}

public protocol SelectedTextProviding: AnyObject {
    func transformSelection(_ transform: @escaping (String) -> String?) async -> Bool
}

public final class AccessibilityTextService {
    public init() {}

    public enum SelectionPresence: Equatable, Sendable {
        /// Caret only — safe to fall back to last-word (do NOT Cmd+C: Sublime copies the line).
        case none
        /// Non-empty selected range reported by AX.
        case present(length: Int)
        /// Focused element has no usable range attribute (Electron/Cursor often).
        case unknown
    }

    public func selectionPresence() -> SelectionPresence {
        guard let element = focusedElement() else { return .unknown }

        var rangeRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef)
        guard result == .success, let axRange = rangeRef else {
            // Some apps expose selected text without a range attribute
            if let text = selectedText(), !text.isEmpty {
                return .present(length: text.utf16.count)
            }
            return .unknown
        }

        var cfRange = CFRange(location: 0, length: 0)
        guard AXValueGetValue(axRange as! AXValue, .cfRange, &cfRange) else {
            return .unknown
        }
        return cfRange.length > 0 ? .present(length: cfRange.length) : .none
    }

    public func selectedText() -> String? {
        let system = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        let focusResult = AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focusedRef)
        guard focusResult == .success, let focused = focusedRef else {
            AppLogger.debug("AX: no focused element")
            return nil
        }

        let element = focused as! AXUIElement
        var selectedRef: CFTypeRef?
        let selResult = AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &selectedRef)
        guard selResult == .success, let selected = selectedRef as? String, !selected.isEmpty else {
            AppLogger.debug("AX: selected text unavailable")
            return nil
        }
        return selected
    }

    /// Slice focused value by selected UTF-16 range when `kAXSelectedText` is empty.
    /// Skips enormous buffers (Sublime large files).
    public func selectedTextViaRange() -> String? {
        guard let element = focusedElement() else { return nil }

        var rangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
              let axRange = rangeRef else { return nil }
        var cfRange = CFRange(location: 0, length: 0)
        guard AXValueGetValue(axRange as! AXValue, .cfRange, &cfRange),
              cfRange.length > 0, cfRange.location >= 0 else { return nil }

        var valueRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valueRef) == .success,
              let full = valueRef as? String else { return nil }
        if full.utf16.count > 100_000 { return nil }
        guard cfRange.location + cfRange.length <= full.utf16.count,
              let swiftRange = Range(NSRange(location: cfRange.location, length: cfRange.length), in: full) else {
            return nil
        }
        let sliced = String(full[swiftRange])
        return sliced.isEmpty ? nil : sliced
    }

    public func setSelectedText(_ text: String) -> Bool {
        guard let element = focusedElement() else { return false }
        let error = AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFTypeRef)
        let ok = error == .success
        if !ok {
            AppLogger.debug("AX: failed to set selected text, error=\(error.rawValue)")
        }
        return ok
    }

    /// Replace `original` inside the focused field's full value (works even if selection was cleared).
    public func replaceInFocusedValue(original: String, replacement: String) -> Bool {
        guard !original.isEmpty, let element = focusedElement() else { return false }

        var valueRef: CFTypeRef?
        let valueResult = AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valueRef)
        guard valueResult == .success, var full = valueRef as? String, !full.isEmpty else {
            AppLogger.debug("AX: focused value unavailable")
            return false
        }

        // 1) Prefer current selected range if present
        var rangeRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
           let axRange = rangeRef {
            var cfRange = CFRange(location: 0, length: 0)
            let axValue = axRange as! AXValue
            if AXValueGetValue(axValue, .cfRange, &cfRange),
               cfRange.location >= 0,
               cfRange.length > 0,
               cfRange.location + cfRange.length <= full.utf16.count {
                if let swiftRange = Range(NSRange(location: cfRange.location, length: cfRange.length), in: full) {
                    full.replaceSubrange(swiftRange, with: replacement)
                    return setValue(full, on: element)
                }
            }
        }

        // 2) Replace last occurrence of the captured original string
        guard let found = full.range(of: original, options: .backwards) else {
            AppLogger.debug("AX: original fragment not found in focused value")
            return false
        }
        full.replaceSubrange(found, with: replacement)
        return setValue(full, on: element)
    }

    /// Select `count` UTF-16 units ending at the caret (or at the end of the current selection).
    /// Important: when a selection already exists, `location` is the start — using it as caret
    /// would select characters *above* the word (Sublime grows empty lines upward each press).
    public func selectBeforeCaret(count: Int) -> Bool {
        guard count > 0, let element = focusedElement() else { return false }

        var rangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
              let axRange = rangeRef else {
            AppLogger.debug("AX: selectBeforeCaret — no selected range")
            return false
        }

        var cfRange = CFRange(location: 0, length: 0)
        guard AXValueGetValue(axRange as! AXValue, .cfRange, &cfRange), cfRange.location >= 0 else {
            return false
        }

        let end = cfRange.location + max(cfRange.length, 0)
        let deleteCount = min(count, end)
        guard deleteCount > 0 else { return false }

        var newRange = CFRange(location: end - deleteCount, length: deleteCount)
        guard let value = AXValueCreate(.cfRange, &newRange) else { return false }
        let error = AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, value)
        let ok = error == .success
        if ok {
            AppLogger.info("AX: selected \(deleteCount) chars before caret/selection-end")
        } else {
            AppLogger.debug("AX: selectBeforeCaret failed, error=\(error.rawValue)")
        }
        return ok
    }

    /// Collapse selection to a caret at the selection end (or current caret).
    public func collapseSelectionToEnd() {
        guard let element = focusedElement() else { return }
        var rangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
              let axRange = rangeRef else { return }
        var cfRange = CFRange(location: 0, length: 0)
        guard AXValueGetValue(axRange as! AXValue, .cfRange, &cfRange) else { return }
        let end = cfRange.location + max(cfRange.length, 0)
        var collapsed = CFRange(location: end, length: 0)
        guard let value = AXValueCreate(.cfRange, &collapsed) else { return }
        AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, value)
    }

    /// Replace `count` UTF-16 units immediately before the caret (or selection start).
    /// Prefer select + setSelectedText so we never load the whole document (Sublime 60k+ lines).
    public func replaceBeforeCaret(count: Int, with replacement: String) -> Bool {
        guard count > 0 else { return false }
        if selectBeforeCaret(count: count) {
            if setSelectedText(replacement) {
                return true
            }
        }

        guard let element = focusedElement() else { return false }

        var valueRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valueRef) == .success,
              let full = valueRef as? String, !full.isEmpty else {
            AppLogger.debug("AX: replaceBeforeCaret — value unavailable")
            return false
        }

        // Avoid rewriting enormous buffers (Sublime large files)
        if full.utf16.count > 100_000 {
            AppLogger.debug("AX: replaceBeforeCaret — value too large, skip")
            return false
        }

        var caret = full.utf16.count
        var rangeRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
           let axRange = rangeRef {
            var cfRange = CFRange(location: 0, length: 0)
            if AXValueGetValue(axRange as! AXValue, .cfRange, &cfRange), cfRange.location >= 0 {
                caret = cfRange.location + max(cfRange.length, 0)
            }
        }

        let deleteCount = min(count, caret)
        guard deleteCount > 0 else { return false }
        let start = caret - deleteCount
        guard let swiftRange = Range(NSRange(location: start, length: deleteCount), in: full) else {
            AppLogger.debug("AX: replaceBeforeCaret — range mapping failed")
            return false
        }

        var updated = full
        updated.replaceSubrange(swiftRange, with: replacement)
        guard setValue(updated, on: element) else { return false }

        let newCaret = start + replacement.utf16.count
        var newRange = CFRange(location: newCaret, length: 0)
        if let axRange = AXValueCreate(.cfRange, &newRange) {
            AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, axRange)
        }
        AppLogger.info("AX: replaced \(deleteCount) chars before caret via value")
        return true
    }

    private func focusedElement() -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        let focusResult = AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focusedRef)
        guard focusResult == .success, let focused = focusedRef else { return nil }
        return (focused as! AXUIElement)
    }

    /// Full string value of the focused element, if exposed via AX.
    public func focusedValue() -> String? {
        guard let element = focusedElement() else { return nil }
        var valueRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valueRef) == .success,
              let full = valueRef as? String, !full.isEmpty else {
            return nil
        }
        return full
    }

    public func focusedValueUTF16Length() -> Int? {
        focusedValue()?.utf16.count
    }

    /// Human-readable AX snapshot for the focused element (debug / probe scripts).
    public func probeReport() -> String {
        let front = NSWorkspace.shared.frontmostApplication
        let bid = front?.bundleIdentifier ?? "(nil)"
        let name = front?.localizedName ?? "(nil)"
        var lines: [String] = [
            "frontmost=\(name)",
            "bundleId=\(bid)"
        ]
        guard focusedElement() != nil else {
            lines.append("focusedElement=nil")
            return lines.joined(separator: "\n")
        }
        lines.append("focusedElement=ok")
        switch selectionPresence() {
        case .none:
            lines.append("selectionPresence=none")
        case .present(let len):
            lines.append("selectionPresence=present(len=\(len))")
        case .unknown:
            lines.append("selectionPresence=unknown")
        }
        if let t = selectedText() {
            lines.append("selectedText=\(t.debugDescription) utf16=\(t.utf16.count)")
        } else {
            lines.append("selectedText=nil")
        }
        if let t = selectedTextViaRange() {
            lines.append("selectedTextViaRange=\(t.debugDescription) utf16=\(t.utf16.count)")
        } else {
            lines.append("selectedTextViaRange=nil")
        }
        if let v = focusedValue() {
            let preview = v.count > 80 ? String(v.prefix(80)) + "…" : v
            lines.append("focusedValue.len=\(v.count) utf16=\(v.utf16.count) preview=\(preview.debugDescription)")
        } else {
            lines.append("focusedValue=nil")
        }
        return lines.joined(separator: "\n")
    }

    private func setValue(_ text: String, on element: AXUIElement) -> Bool {
        let error = AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, text as CFTypeRef)
        let ok = error == .success
        if ok {
            AppLogger.info("AX: replaced text via focused value")
        } else {
            AppLogger.debug("AX: set value failed, error=\(error.rawValue)")
        }
        return ok
    }
}

public final class ClipboardTextService {
    public init() {}

    /// Copy current selection into a string without pasting. Returns nil on timeout.
    public func syncCopySelection(timeout: TimeInterval = 0.35) -> String? {
        let pasteboard = NSPasteboard.general
        let saved = savePasteboard(pasteboard)
        let changeCountBefore = pasteboard.changeCount

        postCommandKeySync("c")
        var copied = waitForStringChange(pasteboard: pasteboard, from: changeCountBefore, timeout: timeout)
        if copied == nil {
            let again = pasteboard.changeCount
            postCommandKeySync("c", preferHID: true)
            copied = waitForStringChange(pasteboard: pasteboard, from: again, timeout: timeout)
        }

        // Leave original pasteboard; we only needed the string
        let result = copied
        restorePasteboard(pasteboard, items: saved)
        // Re-set if we need the string after restore — we already have `result`
        return result
    }

    /// Write `text` to the general pasteboard and verify it stuck before returning.
    private func writeStringToPasteboardVerified(_ text: String, pasteboard: NSPasteboard = .general) -> Bool {
        pasteboard.clearContents()
        pasteboard.declareTypes([.string], owner: nil)
        guard pasteboard.setString(text, forType: .string) else {
            AppLogger.warning("Pasteboard setString failed")
            return false
        }
        // AppKit can lag one runloop; verify before Cmd+V or we paste the OLD clipboard.
        let deadline = Date().addingTimeInterval(0.12)
        while Date() < deadline {
            if pasteboard.string(forType: .string) == text {
                return true
            }
            Thread.sleep(forTimeInterval: 0.005)
        }
        AppLogger.warning("Pasteboard verify failed — refusing Cmd+V to avoid pasting old clipboard")
        return false
    }

    /// Synchronous copy→transform→paste. Use while selection is still alive (chord arm).
    public func syncTransformSelection(
        timeout: TimeInterval = 0.45,
        transform: (String) -> String?
    ) -> Bool {
        let pasteboard = NSPasteboard.general
        let saved = savePasteboard(pasteboard)
        let changeCountBefore = pasteboard.changeCount

        postCommandKeySync("c")
        var original = waitForStringChange(pasteboard: pasteboard, from: changeCountBefore, timeout: timeout)
        if original == nil {
            let again = pasteboard.changeCount
            postCommandKeySync("c", preferHID: true)
            original = waitForStringChange(pasteboard: pasteboard, from: again, timeout: timeout)
        }

        guard let original else {
            restorePasteboard(pasteboard, items: saved)
            AppLogger.warning("Clipboard sync: copy timed out")
            return false
        }

        guard let replacement = transform(original) else {
            restorePasteboard(pasteboard, items: saved)
            AppLogger.warning("Clipboard sync: transform returned nil")
            return false
        }

        guard writeStringToPasteboardVerified(replacement, pasteboard: pasteboard) else {
            restorePasteboard(pasteboard, items: saved)
            return false
        }
        postCommandKeySync("v", preferHID: true)
        Thread.sleep(forTimeInterval: 0.08)
        restorePasteboard(pasteboard, items: saved)
        return true
    }

    /// Paste known text over current selection (sync). Never Cmd+V until pasteboard matches `text`.
    public func syncPasteOverSelection(_ text: String) -> Bool {
        let pasteboard = NSPasteboard.general
        let saved = savePasteboard(pasteboard)
        guard writeStringToPasteboardVerified(text, pasteboard: pasteboard) else {
            restorePasteboard(pasteboard, items: saved)
            return false
        }
        postCommandKeySync("v", preferHID: true)
        Thread.sleep(forTimeInterval: 0.08)
        restorePasteboard(pasteboard, items: saved)
        return true
    }

    public func transformSelection(_ transform: (String) -> String?) async -> Bool {
        let pasteboard = NSPasteboard.general
        let saved = savePasteboard(pasteboard)
        let changeCountBefore = pasteboard.changeCount

        await postCommandKey("c", preferHID: false)
        var copied = await waitForPasteboardString(from: changeCountBefore, timeout: 0.7)
        if copied == nil {
            let again = pasteboard.changeCount
            await postCommandKey("c", preferHID: true)
            copied = await waitForPasteboardString(from: again, timeout: 0.7)
        }

        guard let original = copied else {
            restorePasteboard(pasteboard, items: saved)
            AppLogger.warning("Clipboard: copy timed out")
            return false
        }

        guard let replacement = transform(original) else {
            restorePasteboard(pasteboard, items: saved)
            AppLogger.warning("Clipboard: transform returned nil")
            return false
        }

        let written = await MainActor.run { writeStringToPasteboardVerified(replacement, pasteboard: pasteboard) }
        guard written else {
            restorePasteboard(pasteboard, items: saved)
            return false
        }

        await postCommandKey("v", preferHID: true)
        try? await Task.sleep(nanoseconds: 150_000_000)

        restorePasteboard(pasteboard, items: saved)
        return true
    }

    public func pasteOverSelection(_ text: String) async -> Bool {
        let pasteboard = NSPasteboard.general
        let saved = savePasteboard(pasteboard)
        let written = await MainActor.run { writeStringToPasteboardVerified(text, pasteboard: pasteboard) }
        guard written else {
            restorePasteboard(pasteboard, items: saved)
            return false
        }
        await postCommandKey("v", preferHID: true)
        try? await Task.sleep(nanoseconds: 150_000_000)
        restorePasteboard(pasteboard, items: saved)
        return true
    }

    /// Cmd+C, only paste `replacement` if the copied text matches `expected` (prevents stale pending paste).
    public func replaceSelectionMatching(
        expected: String,
        replacement: String,
        timeout: TimeInterval = 0.45
    ) async -> Bool {
        let pasteboard = NSPasteboard.general
        let saved = savePasteboard(pasteboard)
        let changeCountBefore = pasteboard.changeCount

        await postCommandKey("c", preferHID: false)
        var copied = await waitForPasteboardString(from: changeCountBefore, timeout: timeout)
        if copied == nil {
            let again = pasteboard.changeCount
            await postCommandKey("c", preferHID: true)
            copied = await waitForPasteboardString(from: again, timeout: timeout)
        }

        guard let copied else {
            restorePasteboard(pasteboard, items: saved)
            AppLogger.warning("replaceSelectionMatching: copy timed out")
            return false
        }

        let norm: (String) -> String = {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard copied == expected || norm(copied) == norm(expected) else {
            restorePasteboard(pasteboard, items: saved)
            AppLogger.warning(
                "replaceSelectionMatching: copy(\(copied.count)) != expected(\(expected.count)) — abort"
            )
            return false
        }

        let written = await MainActor.run { writeStringToPasteboardVerified(replacement, pasteboard: pasteboard) }
        guard written else {
            restorePasteboard(pasteboard, items: saved)
            return false
        }
        await postCommandKey("v", preferHID: true)
        try? await Task.sleep(nanoseconds: 150_000_000)
        restorePasteboard(pasteboard, items: saved)
        return true
    }

    public func savePasteboard(_ pasteboard: NSPasteboard = .general) -> [[String: Data]] {
        guard let items = pasteboard.pasteboardItems else { return [] }
        return items.map { item in
            var dict: [String: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    dict[type.rawValue] = data
                }
            }
            return dict
        }
    }

    public func restorePasteboard(_ pasteboard: NSPasteboard = .general, items: [[String: Data]]) {
        pasteboard.clearContents()
        guard !items.isEmpty else { return }
        let newItems: [NSPasteboardItem] = items.map { dict in
            let item = NSPasteboardItem()
            for (type, data) in dict {
                item.setData(data, forType: NSPasteboard.PasteboardType(type))
            }
            return item
        }
        pasteboard.writeObjects(newItems)
    }

    private func waitForPasteboardString(from changeCount: Int, timeout: TimeInterval) async -> String? {
        let pasteboard = NSPasteboard.general
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if pasteboard.changeCount != changeCount,
               let str = pasteboard.string(forType: .string),
               !str.isEmpty {
                return str
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return nil
    }

    private func waitForStringChange(
        pasteboard: NSPasteboard,
        from changeCount: Int,
        timeout: TimeInterval
    ) -> String? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if pasteboard.changeCount != changeCount,
               let str = pasteboard.string(forType: .string),
               !str.isEmpty {
                return str
            }
            Thread.sleep(forTimeInterval: 0.008)
        }
        return nil
    }

    private func postCommandKeyNow(_ key: String, state: CGEventSourceStateID) {
        let source = CGEventSource(stateID: state)
        source?.localEventsSuppressionInterval = 0
        let keyCode: CGKeyCode
        switch key.lowercased() {
        case "c": keyCode = 8
        case "v": keyCode = 9
        case "x": keyCode = 7
        case "a": keyCode = 0
        default: return
        }
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else {
            return
        }
        down.flags = .maskCommand
        up.flags = .maskCommand
        SyntheticEventMarker.mark(down)
        SyntheticEventMarker.mark(up)
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    private func postCommandKeySync(_ key: String, preferHID: Bool = false) {
        SyntheticEventGuard.shared.withSynthetic {
            if preferHID {
                postCommandKeyNow(key, state: .hidSystemState)
            } else {
                postCommandKeyNow(key, state: .privateState)
            }
        }
    }

    private func postCommandKey(_ key: String, preferHID: Bool = false) async {
        await MainActor.run {
            postCommandKeySync(key, preferHID: preferHID)
        }
        try? await Task.sleep(nanoseconds: 50_000_000)
    }
}

public final class SelectedTextService: SelectedTextProviding {
    private let ax = AccessibilityTextService()
    public let clipboard = ClipboardTextService()

    public init() {}

    public func replaceCapturedSelection(_ original: String, with replacement: String) async -> Bool {
        if let current = ax.selectedText(), !current.isEmpty {
            if ax.setSelectedText(replacement) {
                return true
            }
        }
        if case .present = ax.selectionPresence() {
            if ax.setSelectedText(replacement) {
                return true
            }
        }
        if ax.replaceInFocusedValue(original: original, replacement: replacement) {
            return true
        }
        if WordSelectionBridge.isFrontmostWord(), WordSelectionBridge.setSelectedText(replacement) {
            AppLogger.info("Word selection replaced via AppleScript")
            return true
        }
        // Only paste after Cmd+C confirms the live selection still matches `original`.
        // Prevents pasting stale pending / old clipboard over Sublime.
        AppLogger.info("AX replace failed — verified clipboard replace")
        return await clipboard.replaceSelectionMatching(expected: original, replacement: replacement)
    }

    public func transformSelection(_ transform: @escaping (String) -> String?) async -> Bool {
        if let text = ax.selectedText(), !text.isEmpty {
            AppLogger.info("Selected text obtained via AX")
            guard let replacement = transform(text) else {
                AppLogger.warning("AX transform returned nil")
                return false
            }
            if ax.setSelectedText(replacement) {
                return true
            }
            AppLogger.info("AX replace failed, falling back to clipboard")
            return await clipboard.pasteOverSelection(replacement)
        }

        if WordSelectionBridge.isFrontmostWord(),
           let text = WordSelectionBridge.selectedText(), !text.isEmpty {
            AppLogger.info("Selected text obtained via Word AppleScript")
            guard let replacement = transform(text) else {
                AppLogger.warning("Word transform returned nil")
                return false
            }
            if WordSelectionBridge.setSelectedText(replacement) {
                return true
            }
            return await clipboard.pasteOverSelection(replacement)
        }

        AppLogger.info("AX unavailable, trying clipboard fallback")
        return await clipboard.transformSelection(transform)
    }

    /// Layout-switch acquire that never pastes/inserts at a bare caret.
    ///
    /// Cursor/Electron without a selection often still copies the **entire field** on Cmd+C.
    /// That used to look like a multi-word selection (`"как дела" != lastWord "дела"`) and we
    /// pasted at the caret → `"как делаrfr ltkf"`, then the buffer desynced forever.
    public func transformSelectionForLayoutSwitch(
        lastWordHint: String?,
        transform: @escaping (String) -> String?
    ) async -> Bool {
        let presence = ax.selectionPresence()

        // Fast path: AX already has the selected string
        if let text = ax.selectedText(), !text.isEmpty {
            guard let replacement = transform(text) else { return false }
            if ax.setSelectedText(replacement) { return true }
            if ax.replaceInFocusedValue(original: text, replacement: replacement) { return true }
            return await clipboard.pasteOverSelection(replacement)
        }

        if WordSelectionBridge.isFrontmostWord(),
           let text = WordSelectionBridge.selectedText(), !text.isEmpty {
            guard let replacement = transform(text) else { return false }
            if WordSelectionBridge.setSelectedText(replacement) { return true }
            return await clipboard.pasteOverSelection(replacement)
        }

        // Caret only — never touch clipboard
        if case .none = presence {
            AppLogger.debug("Layout selection: AX caret-only, skip")
            return false
        }

        guard let original = clipboard.syncCopySelection(timeout: 0.45) else {
            AppLogger.debug("Layout selection: clipboard copy failed")
            return false
        }
        guard let replacement = transform(original) else { return false }

        let presenceAfter = ax.selectionPresence()
        let axTextAfter = ax.selectedText()
        let fieldValue = ax.focusedValue()

        // Confirmed AX selection text
        if let axTextAfter, !axTextAfter.isEmpty {
            if ax.setSelectedText(replacement) { return true }
            if ax.replaceInFocusedValue(original: original, replacement: replacement) { return true }
            return await clipboard.pasteOverSelection(replacement)
        }

        // Confirmed AX selected range
        if case .present = presenceAfter {
            if ax.setSelectedText(replacement) { return true }
            return await clipboard.pasteOverSelection(replacement)
        }

        if case .none = presenceAfter {
            AppLogger.debug("Layout selection: caret after copy — last word")
            return false
        }

        // —— AX-unknown (Cursor) ——
        let trimmed = original.trimmingCharacters(in: .whitespacesAndNewlines)

        // Entire field/line copy without a real selection
        if let fieldValue {
            let fieldTrimmed = fieldValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if original == fieldValue || trimmed == fieldTrimmed {
                AppLogger.debug("Layout selection: copy==full field — not a selection")
                return false
            }
            // Proper substring shorter than field → real selection
            if fieldValue.contains(original), original.count < fieldValue.count {
                AppLogger.info("Layout selection: substring selection under AX-unknown")
                if ax.replaceInFocusedValue(original: original, replacement: replacement) {
                    return true
                }
                return await clipboard.pasteOverSelection(replacement)
            }
        }

        if let hint = lastWordHint, !hint.isEmpty, trimmed == hint || original == hint {
            AppLogger.debug("Layout selection: copy==lastWord — last word")
            return false
        }

        // No field AX and copy doesn't match last word: refuse paste (safer than desync)
        AppLogger.debug("Layout selection: AX-unknown, refuse unsafe paste")
        return false
    }
}

/// Microsoft Word often exposes neither AX selected text nor reliable synthetic Cmd+C.
/// AppleScript / OSA is the supported automation path for selection content.
enum WordSelectionBridge {
    private static let wordBundleIDs: Set<String> = [
        "com.microsoft.Word",
        "com.microsoft.word"
    ]

    static func isFrontmostWord() -> Bool {
        guard let bid = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else { return false }
        return wordBundleIDs.contains(bid)
    }

    static func selectedText() -> String? {
        let script = """
        tell application "Microsoft Word"
          try
            return content of text object of selection
          on error
            return ""
          end try
        end tell
        """
        return runAppleScript(script)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    static func setSelectedText(_ text: String) -> Bool {
        let escaped = text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
        tell application "Microsoft Word"
          try
            set content of text object of selection to "\(escaped)"
            return "ok"
          on error
            return "err"
          end try
        end tell
        """
        return runAppleScript(script) == "ok"
    }

    private static func runAppleScript(_ source: String) -> String? {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return nil }
        let result = script.executeAndReturnError(&error)
        if let error {
            AppLogger.debug("Word AppleScript error: \(error)")
            return nil
        }
        return result.stringValue
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

