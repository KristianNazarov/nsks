import ApplicationServices
import Cocoa
import Foundation

public struct PermissionStatus: Equatable, Sendable {
    public var accessibilityGranted: Bool
    public var inputMonitoringGranted: Bool
    public var eventTapActive: Bool
    public var currentInputSource: String
    public var bufferHealthy: Bool

    public init(
        accessibilityGranted: Bool,
        inputMonitoringGranted: Bool,
        eventTapActive: Bool,
        currentInputSource: String,
        bufferHealthy: Bool
    ) {
        self.accessibilityGranted = accessibilityGranted
        self.inputMonitoringGranted = inputMonitoringGranted
        self.eventTapActive = eventTapActive
        self.currentInputSource = currentInputSource
        self.bufferHealthy = bufferHealthy
    }
}

public final class PermissionManager: @unchecked Sendable {
    public static let shared = PermissionManager()

    public init() {}

    public func isAccessibilityGranted() -> Bool {
        AXIsProcessTrusted()
    }

    public func isInputMonitoringGranted() -> Bool {
        // CGPreflightListenEventAccess available since macOS 10.15 / refined later
        CGPreflightListenEventAccess()
    }

    public func requestAccessibilityPrompt() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        AppLogger.info("Requested Accessibility permission prompt")
    }

    public func requestInputMonitoringPrompt() {
        _ = CGRequestListenEventAccess()
        AppLogger.info("Requested Input Monitoring permission")
    }

    public func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    public func openInputMonitoringSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
            NSWorkspace.shared.open(url)
        }
    }

    public func snapshot(eventTapActive: Bool, bufferHealthy: Bool) -> PermissionStatus {
        PermissionStatus(
            accessibilityGranted: isAccessibilityGranted(),
            inputMonitoringGranted: isInputMonitoringGranted(),
            eventTapActive: eventTapActive,
            currentInputSource: InputSourceManager.shared.currentSourceID,
            bufferHealthy: bufferHealthy
        )
    }
}
