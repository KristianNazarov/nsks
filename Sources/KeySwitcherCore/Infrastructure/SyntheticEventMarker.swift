import CoreGraphics
import Foundation

/// Marks CGEvents posted by KeySwitcher so the monitor can ignore them.
public enum SyntheticEventMarker {
    /// Unique magic value stored in eventSourceUserData.
    public static let magic: Int64 = 0x4B53_5731_0001 // "KSW1"

    public static func mark(_ event: CGEvent) {
        event.setIntegerValueField(.eventSourceUserData, value: magic)
    }

    public static func isSynthetic(_ event: CGEvent) -> Bool {
        event.getIntegerValueField(.eventSourceUserData) == magic
    }
}

/// Thread-safe flag raised while we post synthetic keystrokes.
/// Acts as a second line of defense if userData is stripped by the system.
public final class SyntheticEventGuard: @unchecked Sendable {
    public static let shared = SyntheticEventGuard()

    private let lock = NSLock()
    private var depth = 0

    public var isActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return depth > 0
    }

    public func begin() {
        lock.lock()
        depth += 1
        lock.unlock()
    }

    public func end() {
        lock.lock()
        depth = max(0, depth - 1)
        lock.unlock()
    }

    public func withSynthetic<T>(_ body: () throws -> T) rethrows -> T {
        begin()
        defer { end() }
        return try body()
    }
}
