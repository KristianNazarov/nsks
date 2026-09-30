import AppKit
import Foundation

public protocol HotkeyHandling: AnyObject {
    func hotkeyTriggered(_ action: HotkeyAction)
}

public struct ModifierTapResult: Sendable {
    public var actionToTrigger: HotkeyAction?
    /// If true, KeyboardMonitor must delete this flagsChanged event (apps never see it).
    public var swallow: Bool

    public init(actionToTrigger: HotkeyAction? = nil, swallow: Bool = false) {
        self.actionToTrigger = actionToTrigger
        self.swallow = swallow
    }
}

/// Tracks physical left/right modifiers by keyCode and matches configured chords.
///
/// For `switchLayout` (⌘⇧): the completing Shift/Cmd event is **swallowed** so editors
/// like Sublime never see ⌘⇧ (which clears selection). Conversion runs on release,
/// when selection is still intact — same path as Change Case.
public final class HotkeyManager: @unchecked Sendable {
    public weak var handler: HotkeyHandling?

    public var onHeldModifiersChanged: ((Set<UInt16>) -> Void)?

    private let lock = NSLock()
    private var hotkeys: [HotkeyAction: Hotkey]
    private var lastTriggerAt: [HotkeyAction: Date] = [:]
    private let debounceInterval: TimeInterval = 0.35

    private var heldModifiers: Set<UInt16> = []
    private var armedActions: Set<HotkeyAction> = []

    /// switchLayout chord was completed (we swallowed the completing modifier).
    private var layoutAwaitingRelease = false
    /// Swallow further flagsChanged for shift/cmd until chord fully ends.
    private var swallowLayoutModifierEvents = false
    /// Fire switchLayout only after BOTH cmd and shift are up (so Backspace isn't Cmd-modified).
    private var layoutPendingFire = false

    public init(settings: AppSettings = SettingsStore.shared.settings) {
        self.hotkeys = settings.hotkeys
    }

    public func update(from settings: AppSettings) {
        lock.lock()
        hotkeys = settings.hotkeys
        lock.unlock()
    }

    public func matchKeyDown(keyCode: Int64, flags: CGEventFlags) -> HotkeyAction? {
        lock.lock()
        // Cmd+Shift+<key> → cancel pending layout hotkey (not a pure chord tap)
        if layoutAwaitingRelease || layoutPendingFire {
            layoutAwaitingRelease = false
            layoutPendingFire = false
            swallowLayoutModifierEvents = false
            armedActions.remove(.switchLayout)
            AppLogger.info("Layout chord cancelled (other key pressed)")
        }
        let snapshot = hotkeys
        let held = heldModifiers
        lock.unlock()

        let state = Self.modifierState(held: held, flags: flags)
        for (action, hotkey) in snapshot {
            guard let requiredKey = hotkey.keyCode else { continue }
            guard Int64(requiredKey) == keyCode else { continue }
            if Self.chordMatches(state, required: hotkey.modifiers) {
                return action
            }
        }
        return nil
    }

    public func handleFlagsChanged(keyCode: Int64, flags: CGEventFlags) -> ModifierTapResult {
        let code = UInt16(truncatingIfNeeded: keyCode)
        guard ModifierKeyCode.all.contains(code) else {
            return ModifierTapResult()
        }

        var result = ModifierTapResult()
        var heldSnapshot: Set<UInt16> = []
        var newlyArmed: [HotkeyAction] = []
        var fire: HotkeyAction?

        lock.lock()
        updateHeldModifiers(changedKey: code, flags: flags)
        heldSnapshot = heldModifiers
        let state = Self.modifierState(held: heldModifiers, flags: flags)
        let snapshot = hotkeys

        for (action, hotkey) in snapshot where hotkey.isModifierOnly {
            if Self.chordMatches(state, required: hotkey.modifiers) {
                if !armedActions.contains(action) {
                    newlyArmed.append(action)
                }
                armedActions.insert(action)
            }
        }

        // Newly completed switchLayout chord → swallow so apps don't see ⌘⇧
        if newlyArmed.contains(.switchLayout) {
            layoutAwaitingRelease = true
            layoutPendingFire = false
            swallowLayoutModifierEvents = true
            result.swallow = true
            AppLogger.info("Layout chord armed — swallowing modifier event")
        }

        let holdingLayoutMods =
            heldModifiers.contains(ModifierKeyCode.rightCommand)
            || heldModifiers.contains(ModifierKeyCode.leftCommand)
            || heldModifiers.contains(ModifierKeyCode.rightShift)
            || heldModifiers.contains(ModifierKeyCode.leftShift)

        // Chord released (no longer fully matches)?
        for action in Array(armedActions) {
            guard let hotkey = snapshot[action], hotkey.isModifierOnly else { continue }
            if !Self.chordMatches(state, required: hotkey.modifiers) {
                armedActions.remove(action)
                if action == .switchLayout {
                    if layoutAwaitingRelease {
                        // Don't fire yet — wait until Cmd is also up, else Backspace becomes Cmd+⌫
                        layoutPendingFire = true
                        layoutAwaitingRelease = false
                        AppLogger.info("Layout chord broken — waiting for all modifiers up")
                    }
                    if swallowLayoutModifierEvents {
                        result.swallow = true
                    }
                } else {
                    fire = action
                }
            }
        }

        // Fire layout only when no cmd/shift remain from the gesture
        if layoutPendingFire && !holdingLayoutMods {
            fire = .switchLayout
            layoutPendingFire = false
            swallowLayoutModifierEvents = false
            AppLogger.info("Layout chord fully released — firing")
        }

        if swallowLayoutModifierEvents {
            if code == ModifierKeyCode.rightShift || code == ModifierKeyCode.leftShift
                || code == ModifierKeyCode.rightCommand || code == ModifierKeyCode.leftCommand {
                result.swallow = true
            }
        }

        if heldModifiers.isEmpty {
            armedActions.removeAll()
            layoutAwaitingRelease = false
            // If we somehow still have pending and mods empty, fire now
            if layoutPendingFire {
                fire = .switchLayout
                layoutPendingFire = false
            }
            swallowLayoutModifierEvents = false
        }

        result.actionToTrigger = fire
        lock.unlock()

        onHeldModifiersChanged?(heldSnapshot)
        return result
    }

    public var currentlyHeldModifiers: Set<UInt16> {
        lock.lock()
        defer { lock.unlock() }
        return heldModifiers
    }

    public var isHoldingLayoutChordModifiers: Bool {
        lock.lock()
        defer { lock.unlock() }
        return heldModifiers.contains(ModifierKeyCode.rightCommand)
            || heldModifiers.contains(ModifierKeyCode.leftCommand)
            || heldModifiers.contains(ModifierKeyCode.rightShift)
            || heldModifiers.contains(ModifierKeyCode.leftShift)
    }

    public func triggerIfNeeded(_ action: HotkeyAction) {
        lock.lock()
        let now = Date()
        if let last = lastTriggerAt[action], now.timeIntervalSince(last) < debounceInterval {
            lock.unlock()
            return
        }
        lastTriggerAt[action] = now
        lock.unlock()

        AppLogger.info("Hotkey triggered: \(action.rawValue)")
        DispatchQueue.main.async { [weak self] in
            self?.handler?.hotkeyTriggered(action)
        }
    }

    private func updateHeldModifiers(changedKey code: UInt16, flags: CGEventFlags) {
        let flagOn = primaryFlagOn(for: code, flags: flags)
        if heldModifiers.contains(code) {
            heldModifiers.remove(code)
            if !flagOn {
                clearFamily(of: code)
            }
        } else if flagOn {
            heldModifiers.insert(code)
        } else {
            clearFamily(of: code)
        }
    }

    private func clearFamily(of code: UInt16) {
        switch code {
        case ModifierKeyCode.leftCommand, ModifierKeyCode.rightCommand:
            heldModifiers.remove(ModifierKeyCode.leftCommand)
            heldModifiers.remove(ModifierKeyCode.rightCommand)
        case ModifierKeyCode.leftShift, ModifierKeyCode.rightShift:
            heldModifiers.remove(ModifierKeyCode.leftShift)
            heldModifiers.remove(ModifierKeyCode.rightShift)
        case ModifierKeyCode.leftOption, ModifierKeyCode.rightOption:
            heldModifiers.remove(ModifierKeyCode.leftOption)
            heldModifiers.remove(ModifierKeyCode.rightOption)
        case ModifierKeyCode.leftControl, ModifierKeyCode.rightControl:
            heldModifiers.remove(ModifierKeyCode.leftControl)
            heldModifiers.remove(ModifierKeyCode.rightControl)
        default:
            break
        }
    }

    private func primaryFlagOn(for keyCode: UInt16, flags: CGEventFlags) -> Bool {
        switch keyCode {
        case ModifierKeyCode.leftCommand, ModifierKeyCode.rightCommand:
            return flags.contains(.maskCommand)
        case ModifierKeyCode.leftShift, ModifierKeyCode.rightShift:
            return flags.contains(.maskShift)
        case ModifierKeyCode.leftOption, ModifierKeyCode.rightOption:
            return flags.contains(.maskAlternate)
        case ModifierKeyCode.leftControl, ModifierKeyCode.rightControl:
            return flags.contains(.maskControl)
        default:
            return false
        }
    }

    public static func modifierState(held: Set<UInt16>, flags: CGEventFlags) -> UInt64 {
        var state: UInt64 = 0
        if flags.contains(.maskShift) { state |= CGEventFlagsCompat.shift }
        if flags.contains(.maskAlternate) { state |= CGEventFlagsCompat.alternate }
        if flags.contains(.maskCommand) { state |= CGEventFlagsCompat.command }
        if flags.contains(.maskControl) { state |= CGEventFlagsCompat.control }

        for code in held {
            if let bit = ModifierKeyCode.deviceBit(for: code) {
                state |= bit
            }
        }
        if held.contains(ModifierKeyCode.leftCommand) || held.contains(ModifierKeyCode.rightCommand) {
            state |= CGEventFlagsCompat.command
        }
        if held.contains(ModifierKeyCode.leftShift) || held.contains(ModifierKeyCode.rightShift) {
            state |= CGEventFlagsCompat.shift
        }
        if held.contains(ModifierKeyCode.leftOption) || held.contains(ModifierKeyCode.rightOption) {
            state |= CGEventFlagsCompat.alternate
        }
        if held.contains(ModifierKeyCode.leftControl) || held.contains(ModifierKeyCode.rightControl) {
            state |= CGEventFlagsCompat.control
        }
        return state
    }

    public static func chordMatches(_ state: UInt64, required: UInt64) -> Bool {
        let primaryRequired = required & CGEventFlagsCompat.primaryMask
        let primaryActual = state & CGEventFlagsCompat.primaryMask
        guard primaryActual == primaryRequired else { return false }

        let deviceRequired = required & CGEventFlagsCompat.deviceMask
        if deviceRequired != 0 {
            let deviceActual = state & CGEventFlagsCompat.deviceMask
            guard (deviceActual & deviceRequired) == deviceRequired else { return false }
            if !sideIsExclusive(required: deviceRequired, actual: deviceActual) {
                return false
            }
        }
        return true
    }

    private static func sideIsExclusive(required: UInt64, actual: UInt64) -> Bool {
        func check(left: UInt64, right: UInt64) -> Bool {
            let wantsLeft = required & left != 0
            let wantsRight = required & right != 0
            if wantsRight && !wantsLeft && actual & left != 0 { return false }
            if wantsLeft && !wantsRight && actual & right != 0 { return false }
            return true
        }
        return check(left: CGEventFlagsCompat.leftCommand, right: CGEventFlagsCompat.rightCommand)
            && check(left: CGEventFlagsCompat.leftShift, right: CGEventFlagsCompat.rightShift)
            && check(left: CGEventFlagsCompat.leftAlternate, right: CGEventFlagsCompat.rightAlternate)
            && check(left: CGEventFlagsCompat.leftControl, right: CGEventFlagsCompat.rightControl)
    }

    public static func displayString(for hotkey: Hotkey) -> String {
        var parts: [String] = []
        let m = hotkey.modifiers
        if m & CGEventFlagsCompat.control != 0 {
            parts.append(sideLabel(left: m & CGEventFlagsCompat.leftControl != 0,
                                   right: m & CGEventFlagsCompat.rightControl != 0, symbol: "⌃"))
        }
        if m & CGEventFlagsCompat.alternate != 0 {
            parts.append(sideLabel(left: m & CGEventFlagsCompat.leftAlternate != 0,
                                   right: m & CGEventFlagsCompat.rightAlternate != 0, symbol: "⌥"))
        }
        if m & CGEventFlagsCompat.shift != 0 {
            parts.append(sideLabel(left: m & CGEventFlagsCompat.leftShift != 0,
                                   right: m & CGEventFlagsCompat.rightShift != 0, symbol: "⇧"))
        }
        if m & CGEventFlagsCompat.command != 0 {
            parts.append(sideLabel(left: m & CGEventFlagsCompat.leftCommand != 0,
                                   right: m & CGEventFlagsCompat.rightCommand != 0, symbol: "⌘"))
        }
        if let keyCode = hotkey.keyCode {
            parts.append(keyName(keyCode: keyCode))
        }
        return parts.joined(separator: " + ")
    }

    private static func sideLabel(left: Bool, right: Bool, symbol: String) -> String {
        if right && !left { return "Right \(symbol)" }
        if left && !right { return "Left \(symbol)" }
        return symbol
    }

    public static func keyName(keyCode: UInt16) -> String {
        let map: [UInt16: String] = [
            0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V",
            11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T",
            31: "O", 32: "U", 34: "I", 35: "P", 37: "L", 38: "J", 40: "K",
            45: "N", 46: "M",
            18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6", 26: "7", 28: "8", 25: "9", 29: "0"
        ]
        return map[keyCode] ?? "Key\(keyCode)"
    }

    public static func hotkeyFrom(heldModifiers: Set<UInt16>, keyCode: UInt16?) -> Hotkey? {
        var modifiers: UInt64 = 0
        for code in heldModifiers {
            guard let bit = ModifierKeyCode.deviceBit(for: code) else { continue }
            modifiers |= bit
            switch code {
            case ModifierKeyCode.leftCommand, ModifierKeyCode.rightCommand:
                modifiers |= CGEventFlagsCompat.command
            case ModifierKeyCode.leftShift, ModifierKeyCode.rightShift:
                modifiers |= CGEventFlagsCompat.shift
            case ModifierKeyCode.leftOption, ModifierKeyCode.rightOption:
                modifiers |= CGEventFlagsCompat.alternate
            case ModifierKeyCode.leftControl, ModifierKeyCode.rightControl:
                modifiers |= CGEventFlagsCompat.control
            default: break
            }
        }
        guard modifiers & CGEventFlagsCompat.primaryMask != 0 else { return nil }
        return Hotkey(keyCode: keyCode, modifiers: modifiers)
    }
}
