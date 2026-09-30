import Carbon
import Foundation

public final class InputSourceManager: @unchecked Sendable {
    public static let shared = InputSourceManager()

    public init() {}

    public var currentSourceID: String {
        onMainSync {
            guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else {
                return "unknown"
            }
            return sourceID(of: source) ?? "unknown"
        }
    }

    public var currentLayoutHint: KeyboardLayoutID? {
        layoutID(forSourceID: currentSourceID)
    }

    public func availableSources() -> [(id: String, name: String)] {
        onMainSync {
            guard let list = TISCreateInputSourceList(nil, false)?.takeRetainedValue() as? [TISInputSource] else {
                return []
            }
            return list.compactMap { source in
                guard isKeyboardLayoutSource(source),
                      let id = sourceID(of: source) else { return nil }
                let name = localizedName(of: source) ?? id
                return (id, name)
            }
        }
    }

    /// TIS APIs must run on the main thread — calling from a Swift concurrency worker
    /// crashes with `dispatch_assert_queue_fail` / EXC_BREAKPOINT.
    @discardableResult
    public func selectLayout(_ layout: KeyboardLayoutID) -> Bool {
        onMainSync {
            guard let source = findSource(for: layout) else {
                AppLogger.warning("Input source not found for \(layout.rawValue)")
                return false
            }
            let status = TISSelectInputSource(source)
            let ok = status == noErr
            if ok {
                AppLogger.info("Input source switched to \(layout.rawValue)")
            } else {
                AppLogger.error("Failed to switch input source, status=\(status)")
            }
            return ok
        }
    }

    public func findSource(for layout: KeyboardLayoutID) -> TISInputSource? {
        // Caller must already be on main when invoked from selectLayout's onMainSync.
        // Public use also hops to main.
        if Thread.isMainThread {
            return findSourceUnlocked(for: layout)
        }
        return onMainSync { findSourceUnlocked(for: layout) }
    }

    private func findSourceUnlocked(for layout: KeyboardLayoutID) -> TISInputSource? {
        guard let list = TISCreateInputSourceList(nil, false)?.takeRetainedValue() as? [TISInputSource] else {
            return nil
        }

        let preferredIDs: [String]
        switch layout {
        case .english:
            preferredIDs = [
                "com.apple.keylayout.ABC",
                "com.apple.keylayout.US",
                "com.apple.keylayout.British",
                "com.apple.keylayout.Australian",
                "com.apple.keylayout.Canadian",
                "com.apple.keylayout.USExtended",
                "com.apple.keylayout.ABC-India"
            ]
        case .russian:
            preferredIDs = [
                "com.apple.keylayout.Russian",
                "com.apple.keylayout.RussianWin",
                "com.apple.keylayout.Russian-Phonetic"
            ]
        }

        for id in preferredIDs {
            if let match = list.first(where: { sourceID(of: $0) == id }) {
                return match
            }
        }

        for source in list {
            guard isKeyboardLayoutSource(source), let id = sourceID(of: source) else { continue }
            switch layout {
            case .english:
                if id.contains("keylayout.ABC") || id.contains("keylayout.US") || id.hasSuffix(".British") {
                    return source
                }
                if let langs = languages(of: source), langs.contains(where: { $0.hasPrefix("en") }) {
                    if id.contains("keylayout") {
                        return source
                    }
                }
            case .russian:
                if id.contains("Russian") {
                    return source
                }
                if let langs = languages(of: source), langs.contains(where: { $0.hasPrefix("ru") }) {
                    return source
                }
            }
        }
        return nil
    }

    public func layoutID(forSourceID id: String) -> KeyboardLayoutID? {
        let lower = id.lowercased()
        if lower.contains("russian") || lower.contains(".ru") {
            return .russian
        }
        if lower.contains("abc") || lower.contains("us") || lower.contains("british")
            || lower.contains("australian") || lower.contains("canadian") {
            return .english
        }
        return nil
    }

    private func onMainSync<T>(_ body: () -> T) -> T {
        if Thread.isMainThread {
            return body()
        }
        return DispatchQueue.main.sync(execute: body)
    }

    private func sourceID(of source: TISInputSource) -> String? {
        guard let cf = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return nil }
        return Unmanaged<CFString>.fromOpaque(cf).takeUnretainedValue() as String
    }

    private func localizedName(of source: TISInputSource) -> String? {
        guard let cf = TISGetInputSourceProperty(source, kTISPropertyLocalizedName) else { return nil }
        return Unmanaged<CFString>.fromOpaque(cf).takeUnretainedValue() as String
    }

    private func languages(of source: TISInputSource) -> [String]? {
        guard let cf = TISGetInputSourceProperty(source, kTISPropertyInputSourceLanguages) else { return nil }
        return Unmanaged<CFArray>.fromOpaque(cf).takeUnretainedValue() as? [String]
    }

    private func isKeyboardLayoutSource(_ source: TISInputSource) -> Bool {
        guard let cf = TISGetInputSourceProperty(source, kTISPropertyInputSourceCategory) else { return false }
        let category = Unmanaged<CFString>.fromOpaque(cf).takeUnretainedValue() as String
        return category == (kTISCategoryKeyboardInputSource as String)
    }
}
