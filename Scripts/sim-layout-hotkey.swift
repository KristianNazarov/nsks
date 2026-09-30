#!/usr/bin/env swift
import AppKit
import CoreGraphics

/// Posts Right ⌘ + Right ⇧ (press both, release both) — KeySwitcher default layout chord.
/// Usage:
///   1. Focus the target app / text field with caret or selection ready
///   2. Run: swift Scripts/sim-layout-hotkey.swift
///
/// Needs Accessibility for the Terminal running this script.
/// KeySwitcher must be running and watching the same chord.

let rightCmd: CGKeyCode = 54
let rightShift: CGKeyCode = 60

func postFlags(_ key: CGKeyCode, down: Bool) {
    // flagsChanged events for modifiers
    guard let src = CGEventSource(stateID: .hidSystemState) else { return }
    guard let ev = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: down) else { return }
    ev.type = .flagsChanged
    var flags: CGEventFlags = []
    // Approximate combined flags while "held"
    if key == rightCmd && down { flags.insert(.maskCommand) }
    if key == rightShift && down { flags.insert(.maskShift) }
    // When posting the second key down, include both
    ev.flags = flags
    ev.post(tap: .cghidEventTap)
}

func postKeyDown(_ key: CGKeyCode, flags: CGEventFlags) {
    guard let src = CGEventSource(stateID: .hidSystemState) else { return }
    guard let down = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: true) else { return }
    down.type = .flagsChanged
    down.flags = flags
    down.post(tap: .cghidEventTap)
}

func postKeyUp(_ key: CGKeyCode, flags: CGEventFlags) {
    guard let src = CGEventSource(stateID: .hidSystemState) else { return }
    guard let up = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: false) else { return }
    up.type = .flagsChanged
    up.flags = flags
    up.post(tap: .cghidEventTap)
}

print("Posting Right ⌘ + Right ⇧ in 0.4s — focus your target now…")
fflush(stdout)
Thread.sleep(forTimeInterval: 0.4)

// Down Cmd, Down Shift, Up Shift, Up Cmd (typical chord)
postKeyDown(rightCmd, flags: .maskCommand)
Thread.sleep(forTimeInterval: 0.03)
postKeyDown(rightShift, flags: [.maskCommand, .maskShift])
Thread.sleep(forTimeInterval: 0.08)
postKeyUp(rightShift, flags: .maskCommand)
Thread.sleep(forTimeInterval: 0.03)
postKeyUp(rightCmd, flags: [])
Thread.sleep(forTimeInterval: 0.05)

print("Posted. Check KeySwitcher status / ~/Library/Logs/KeySwitcher/keyswitcher.log")
