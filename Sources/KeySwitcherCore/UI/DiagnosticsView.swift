import SwiftUI

public struct DiagnosticsView: View {
    @ObservedObject var controller: AppController

    public init(controller: AppController) {
        self.controller = controller
    }

    public var body: some View {
        let status = controller.permissionStatus

        Form {
            Section("Permissions") {
                statusRow("Accessibility", status.accessibilityGranted ? "Granted" : "Not granted", ok: status.accessibilityGranted)
                statusRow("Input Monitoring", status.inputMonitoringGranted ? "Granted" : "Not granted", ok: status.inputMonitoringGranted)

                HStack {
                    Button("Request Accessibility…") {
                        controller.permissions.requestAccessibilityPrompt()
                        controller.refreshPermissions()
                    }
                    Button("Open System Settings") {
                        controller.permissions.openAccessibilitySettings()
                    }
                }
                HStack {
                    Button("Request Input Monitoring…") {
                        controller.permissions.requestInputMonitoringPrompt()
                        controller.refreshPermissions()
                    }
                    Button("Open System Settings") {
                        controller.permissions.openInputMonitoringSettings()
                    }
                }
            }

            Section("Status") {
                statusRow("Event Tap", status.eventTapActive ? "Active" : "Inactive", ok: status.eventTapActive)
                statusRow("Keyboard buffer", status.bufferHealthy ? "Healthy" : "Unreliable", ok: status.bufferHealthy)
                LabeledContent("Input Source") {
                    Text(status.currentInputSource)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
            }

            Section {
                Button("Retry Start Monitoring") {
                    controller.ensureMonitoring()
                }
                Button("Refresh") {
                    controller.refreshPermissions()
                }
            }

            Section("Help") {
                Text("KeySwitcher нужен доступ Accessibility и Input Monitoring. Выдайте оба, затем нажмите Retry Start Monitoring. Поля паролей (Secure Input) не поддерживаются.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .frame(width: 480, height: 420)
        .keySwitcherBringWindowToFront()
        .onAppear {
            controller.refreshPermissions()
        }
    }

    @ViewBuilder
    private func statusRow(_ title: String, _ value: String, ok: Bool) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .foregroundStyle(ok ? .green : .red)
                .fontWeight(.medium)
        }
    }
}
