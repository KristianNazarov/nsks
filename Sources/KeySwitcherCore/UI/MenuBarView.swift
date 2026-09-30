import AppKit
import SwiftUI

public struct MenuBarContent: View {
    @ObservedObject var controller: AppController
    var openSettings: () -> Void
    var openDiagnostics: () -> Void

    public init(
        controller: AppController,
        openSettings: @escaping () -> Void,
        openDiagnostics: @escaping () -> Void
    ) {
        self.controller = controller
        self.openSettings = openSettings
        self.openDiagnostics = openDiagnostics
    }

    public var body: some View {
        Button(controller.isEnabled ? "Disable" : "Enable") {
            controller.toggleEnabled()
        }
        Divider()
        Button("Settings…") {
            openSettings()
        }
        Button("Permissions…") {
            controller.ensureMonitoring()
            openDiagnostics()
        }
        if !controller.statusMessage.isEmpty {
            Divider()
            Text(controller.statusMessage)
        }
        Divider()
        Button("Quit") {
            controller.stop()
            NSApplication.shared.terminate(nil)
        }
    }
}
