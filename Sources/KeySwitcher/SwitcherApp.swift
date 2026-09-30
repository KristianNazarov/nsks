import SwiftUI
import KeySwitcherCore

@main
struct SwitcherApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @ObservedObject private var controller = AppController.shared
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        MenuBarExtra("KeySwitcher", systemImage: controller.isEnabled ? "keyboard" : "keyboard.chevron.compact.down") {
            MenuBarContent(
                controller: controller,
                openSettings: {
                    openWindow(id: "settings")
                    AppDelegate.bringOpenWindowsToFront()
                },
                openDiagnostics: {
                    controller.ensureMonitoring()
                    openWindow(id: "diagnostics")
                    AppDelegate.bringOpenWindowsToFront()
                }
            )
        }
        .menuBarExtraStyle(.menu)

        Window("Settings", id: "settings") {
            SettingsView(controller: AppController.shared)
        }
        .defaultSize(width: 520, height: 380)

        Window("Permissions", id: "diagnostics") {
            DiagnosticsView(controller: AppController.shared)
        }
        .defaultSize(width: 480, height: 420)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        AppController.shared.start()
        AppLogger.info("KeySwitcher launched")
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppController.shared.stop()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    static func bringOpenWindowsToFront() {
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            for window in NSApp.windows where window.isVisible || window.isMiniaturized {
                window.collectionBehavior.insert(.moveToActiveSpace)
                window.makeKeyAndOrderFront(nil)
                window.orderFrontRegardless()
            }
        }
    }
}
