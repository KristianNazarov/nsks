#!/usr/bin/env swift
import AppKit
import ApplicationServices

/// Prints AX selection state for the frontmost app.
/// Usage:
///   1. Select text in Sublime/Cursor/TextEdit
///   2. Keep that app focused
///   3. Run: swift Scripts/ax-probe.swift
///
/// Needs Accessibility permission for the Terminal / `swift` runner.

func focusedElement() -> AXUIElement? {
    let system = AXUIElementCreateSystemWide()
    var focusedRef: CFTypeRef?
    guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
          let focused = focusedRef else { return nil }
    return (focused as! AXUIElement)
}

func selectedText(_ element: AXUIElement) -> String? {
    var ref: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &ref) == .success else {
        return nil
    }
    return ref as? String
}

func selectedRange(_ element: AXUIElement) -> CFRange? {
    var ref: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &ref) == .success,
          let ax = ref else { return nil }
    var range = CFRange(location: 0, length: 0)
    guard AXValueGetValue(ax as! AXValue, .cfRange, &range) else { return nil }
    return range
}

func focusedValue(_ element: AXUIElement) -> String? {
    var ref: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &ref) == .success else {
        return nil
    }
    return ref as? String
}

let front = NSWorkspace.shared.frontmostApplication
print("frontmost=\(front?.localizedName ?? "?")")
print("bundleId=\(front?.bundleIdentifier ?? "?")")

guard let el = focusedElement() else {
    print("focusedElement=nil")
    print("HINT: grant Accessibility to Terminal (or the process running this script)")
    exit(1)
}
print("focusedElement=ok")

if let r = selectedRange(el) {
    print("selectedRange=location:\(r.location) length:\(r.length)")
} else {
    print("selectedRange=nil")
}

if let t = selectedText(el) {
    print("selectedText=\(t.debugDescription) count=\(t.count)")
} else {
    print("selectedText=nil")
}

if let v = focusedValue(el) {
    let preview = v.count > 100 ? String(v.prefix(100)) + "…" : v
    print("focusedValue.count=\(v.count) preview=\(preview.debugDescription)")
} else {
    print("focusedValue=nil")
}

if let r = selectedRange(el), r.length > 0, let v = focusedValue(el),
   r.location >= 0, r.location + r.length <= v.utf16.count,
   let swiftRange = Range(NSRange(location: r.location, length: r.length), in: v) {
    print("sliced=\(String(v[swiftRange]).debugDescription)")
}

print("DONE")
