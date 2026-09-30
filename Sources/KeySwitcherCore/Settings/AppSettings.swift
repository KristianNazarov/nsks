import Foundation

/// Global hotkey. `keyCode == nil` → modifier-only chord (e.g. Right ⌘ + Right ⇧).
public struct Hotkey: Codable, Equatable, Sendable, Hashable {
    public var keyCode: UInt16?
    /// Primary CGEventFlags bits + device-dependent left/right bits we track ourselves.
    public var modifiers: UInt64

    public init(keyCode: UInt16?, modifiers: UInt64) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    public var isModifierOnly: Bool { keyCode == nil }
}

public enum HotkeyAction: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Selected text if present, otherwise last typed word.
    case switchLayout
    case changeSelectedCase

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .switchLayout: return "Раскладка (слово / выделение)"
        case .changeSelectedCase: return "Регистр выделения"
        }
    }
}

public struct AppSettings: Codable, Equatable, Sendable {
    public var isEnabled: Bool
    public var hotkeys: [HotkeyAction: Hotkey]

    public static let defaults = AppSettings(
        isEnabled: true,
        hotkeys: [
            .switchLayout: Hotkey(
                keyCode: nil,
                modifiers: CGEventFlagsCompat.command
                    | CGEventFlagsCompat.shift
                    | CGEventFlagsCompat.rightCommand
                    | CGEventFlagsCompat.rightShift
            ),
            .changeSelectedCase: Hotkey(
                keyCode: nil,
                modifiers: CGEventFlagsCompat.command
                    | CGEventFlagsCompat.alternate
                    | CGEventFlagsCompat.rightCommand
                    | CGEventFlagsCompat.rightAlternate
            )
        ]
    )

    public init(isEnabled: Bool, hotkeys: [HotkeyAction: Hotkey]) {
        self.isEnabled = isEnabled
        self.hotkeys = hotkeys
    }
}

public enum CGEventFlagsCompat {
    public static let shift: UInt64 = 0x00020000
    public static let alternate: UInt64 = 0x00080000
    public static let command: UInt64 = 0x00100000
    public static let control: UInt64 = 0x00040000

    // Device-dependent masks (IOLLEvent.h). We mainly set these ourselves
    // based on modifier keyCodes — raw CGEvent bits are unreliable for L/R.
    public static let leftControl: UInt64 = 0x00000001
    public static let rightControl: UInt64 = 0x00000002
    public static let leftShift: UInt64 = 0x00000004
    public static let rightShift: UInt64 = 0x00000008
    public static let leftCommand: UInt64 = 0x00000010
    public static let rightCommand: UInt64 = 0x00000020
    public static let leftAlternate: UInt64 = 0x00000040
    public static let rightAlternate: UInt64 = 0x00000080

    public static let primaryMask: UInt64 = shift | alternate | command | control
    public static let deviceMask: UInt64 = 0x000000FF
}

/// Physical modifier keyCodes on macOS (ANSI).
public enum ModifierKeyCode {
    public static let leftCommand: UInt16 = 55
    public static let rightCommand: UInt16 = 54
    public static let leftShift: UInt16 = 56
    public static let rightShift: UInt16 = 60
    public static let leftOption: UInt16 = 58
    public static let rightOption: UInt16 = 61
    public static let leftControl: UInt16 = 59
    public static let rightControl: UInt16 = 62

    public static let all: Set<UInt16> = [
        leftCommand, rightCommand,
        leftShift, rightShift,
        leftOption, rightOption,
        leftControl, rightControl
    ]

    public static func deviceBit(for keyCode: UInt16) -> UInt64? {
        switch keyCode {
        case leftCommand: return CGEventFlagsCompat.leftCommand
        case rightCommand: return CGEventFlagsCompat.rightCommand
        case leftShift: return CGEventFlagsCompat.leftShift
        case rightShift: return CGEventFlagsCompat.rightShift
        case leftOption: return CGEventFlagsCompat.leftAlternate
        case rightOption: return CGEventFlagsCompat.rightAlternate
        case leftControl: return CGEventFlagsCompat.leftControl
        case rightControl: return CGEventFlagsCompat.rightControl
        default: return nil
        }
    }
}

public final class SettingsStore: @unchecked Sendable {
    public static let shared = SettingsStore()

    private let defaultsKey = "KeySwitcher.AppSettings.v3"
    private let lock = NSLock()
    private var cached: AppSettings

    public var settings: AppSettings {
        get {
            lock.lock()
            defer { lock.unlock() }
            return cached
        }
        set {
            lock.lock()
            cached = newValue
            lock.unlock()
            persist(newValue)
        }
    }

    public init() {
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let decoded = try? JSONDecoder().decode(AppSettings.self, from: data) {
            cached = decoded
        } else {
            cached = .defaults
        }
    }

    public func resetToDefaults() {
        settings = .defaults
    }

    private func persist(_ settings: AppSettings) {
        if let data = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }
}

extension AppSettings {
    enum CodingKeys: String, CodingKey {
        case isEnabled, hotkeys
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = try container.decode(Bool.self, forKey: .isEnabled)
        let raw = try container.decode([String: Hotkey].self, forKey: .hotkeys)
        var mapped: [HotkeyAction: Hotkey] = [:]
        for (key, value) in raw {
            if let action = HotkeyAction(rawValue: key) {
                mapped[action] = value
            }
        }
        for action in HotkeyAction.allCases where mapped[action] == nil {
            mapped[action] = AppSettings.defaults.hotkeys[action]
        }
        hotkeys = mapped
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(isEnabled, forKey: .isEnabled)
        var raw: [String: Hotkey] = [:]
        for (key, value) in hotkeys {
            raw[key.rawValue] = value
        }
        try container.encode(raw, forKey: .hotkeys)
    }
}
