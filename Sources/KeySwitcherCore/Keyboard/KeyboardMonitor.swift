import AppKit
import ApplicationServices
import Foundation

public final class KeyboardMonitor: @unchecked Sendable {
    public let buffer = KeyboardBuffer()
    public private(set) var isTapActive = false

    public var hotkeyManager: HotkeyManager?
    public var isEnabled: () -> Bool = { true }
    /// Mouse-drag or Shift+arrow — Sublime has no AX selection API.
    public var onExplicitSelectionGesture: (() -> Void)?
    /// Ordinary typing clears the "explicit selection" hint.
    public var onTypingActivity: (() -> Void)?
    public var onAppSwitch: (() -> Void)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var mouseDownPoint: CGPoint?

    public init() {}

    public func start() -> Bool {
        stop()

        let mask = (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.leftMouseDown.rawValue)
            | (1 << CGEventType.leftMouseUp.rawValue)
            | (1 << CGEventType.rightMouseDown.rawValue)
            | (1 << CGEventType.otherMouseDown.rawValue)

        let userInfo = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: keyboardTapCallback,
            userInfo: userInfo
        ) else {
            AppLogger.error("Failed to create CGEventTap")
            isTapActive = false
            return false
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        if let source = runLoopSource {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        }
        CGEvent.tapEnable(tap: tap, enable: true)
        isTapActive = true
        observeWorkspace()
        AppLogger.info("Event tap started")
        return true
    }

    public func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
        isTapActive = false
        removeWorkspaceObservers()
        AppLogger.info("Event tap stopped")
    }

    public func setTapEnabled(_ enabled: Bool) {
        guard let tap = eventTap else { return }
        CGEvent.tapEnable(tap: tap, enable: enabled)
        isTapActive = enabled
    }

    fileprivate func handle(event: CGEvent, type: CGEventType) -> Unmanaged<CGEvent>? {
        // Re-enable tap if disabled by timeout
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
                isTapActive = true
                AppLogger.warning("Event tap re-enabled after disable")
            }
            return Unmanaged.passUnretained(event)
        }

        if SyntheticEventMarker.isSynthetic(event) || SyntheticEventGuard.shared.isActive {
            return Unmanaged.passUnretained(event)
        }

        if !isEnabled() {
            return Unmanaged.passUnretained(event)
        }

        switch type {
        case .leftMouseDown:
            mouseDownPoint = event.location
            invalidateBuffer(reason: "mouse")
            return Unmanaged.passUnretained(event)

        case .leftMouseUp:
            if let start = mouseDownPoint {
                let end = event.location
                let dx = abs(end.x - start.x)
                let dy = abs(end.y - start.y)
                if dx > 4 || dy > 4 {
                    onExplicitSelectionGesture?()
                }
            }
            mouseDownPoint = nil
            return Unmanaged.passUnretained(event)

        case .rightMouseDown, .otherMouseDown:
            invalidateBuffer(reason: "mouse")
            return Unmanaged.passUnretained(event)

        case .flagsChanged:
            if let manager = hotkeyManager {
                let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
                let result = manager.handleFlagsChanged(keyCode: keyCode, flags: event.flags)
                if let action = result.actionToTrigger {
                    manager.triggerIfNeeded(action)
                }
                if result.swallow {
                    return nil // apps must not see ⌘⇧ (clears selection in Sublime etc.)
                }
            }
            return Unmanaged.passUnretained(event)

        case .keyDown:
            return handleKeyDown(event)

        default:
            return Unmanaged.passUnretained(event)
        }
    }

    private func handleKeyDown(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags

        // Letter+modifier hotkeys: swallow so the character isn't typed
        if let manager = hotkeyManager, let action = manager.matchKeyDown(keyCode: keyCode, flags: flags) {
            manager.triggerIfNeeded(action)
            return nil
        }

        // Shift+arrows = keyboard selection
        let arrows: Set<Int64> = [123, 124, 125, 126]
        if flags.contains(.maskShift), arrows.contains(keyCode) {
            onExplicitSelectionGesture?()
            invalidateBuffer(reason: "navigation")
            return Unmanaged.passUnretained(event)
        }

        // Command / Control shortcuts invalidate (except we already handled our hotkeys)
        if flags.contains(.maskCommand) || flags.contains(.maskControl) {
            invalidateBuffer(reason: "modifier-shortcut")
            return Unmanaged.passUnretained(event)
        }

        // Navigation / editing keys that move caret or change content unpredictably
        let invalidatingKeyCodes: Set<Int64> = [
            123, 124, 125, 126, // arrows
            115, 119, // Home / End
            116, 121, // PageUp / PageDown
            36, 48, // Return / Tab — treat as hard boundary → invalidate for safety
            53 // Escape
        ]
        if invalidatingKeyCodes.contains(keyCode) {
            invalidateBuffer(reason: "navigation")
            return Unmanaged.passUnretained(event)
        }

        // Backspace
        if keyCode == 51 {
            buffer.backspace()
            onTypingActivity?()
            if buffer.characterCount == 0 {
                buffer.markHealthy()
            }
            return Unmanaged.passUnretained(event)
        }

        // Recover to healthy when user starts typing again after invalidation
        if !buffer.isHealthy {
            buffer.resetHealthy()
        }

        onTypingActivity?()

        if let chars = eventString(event), let first = chars.first {
            // Multi-char rare; take first / all
            for ch in chars {
                buffer.append(ch)
            }
            _ = first
        }

        return Unmanaged.passUnretained(event)
    }

    private func eventString(_ event: CGEvent) -> String? {
        var length = 0
        event.keyboardGetUnicodeString(maxStringLength: 0, actualStringLength: &length, unicodeString: nil)
        guard length > 0 else {
            // Fallback: try NSEvent
            if let nsEvent = NSEvent(cgEvent: event), let chars = nsEvent.charactersIgnoringModifiers ?? nsEvent.characters {
                return chars.isEmpty ? nil : chars
            }
            return nil
        }
        var buffer = [UniChar](repeating: 0, count: max(length, 8))
        var actual = 0
        event.keyboardGetUnicodeString(maxStringLength: buffer.count, actualStringLength: &actual, unicodeString: &buffer)
        guard actual > 0 else { return nil }
        return String(utf16CodeUnits: buffer, count: actual)
    }

    private func invalidateBuffer(reason: String) {
        buffer.invalidate(reason: reason)
        AppLogger.debug("Keyboard buffer invalidated (\(reason))")
    }

    private func observeWorkspace() {
        removeWorkspaceObservers()
        let nc = NSWorkspace.shared.notificationCenter
        let names: [NSNotification.Name] = [
            NSWorkspace.didActivateApplicationNotification,
            NSWorkspace.activeSpaceDidChangeNotification
        ]
        for name in names {
            let token = nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.invalidateBuffer(reason: "app-switch")
                self?.onAppSwitch?()
            }
            workspaceObservers.append(token)
        }

        let local = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.invalidateBuffer(reason: "resign-active")
        }
        workspaceObservers.append(local)
    }

    private func removeWorkspaceObservers() {
        let nc = NSWorkspace.shared.notificationCenter
        for token in workspaceObservers {
            nc.removeObserver(token)
            NotificationCenter.default.removeObserver(token)
        }
        workspaceObservers.removeAll()
    }
}

private func keyboardTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let refcon else {
        return Unmanaged.passUnretained(event)
    }
    let monitor = Unmanaged<KeyboardMonitor>.fromOpaque(refcon).takeUnretainedValue()
    return monitor.handle(event: event, type: type)
}
