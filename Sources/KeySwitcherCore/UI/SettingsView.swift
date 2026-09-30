import AppKit
import SwiftUI

public struct SettingsView: View {
    @ObservedObject var controller: AppController
    @State private var recording: HotkeyAction?
    @State private var draft: AppSettings

    public init(controller: AppController) {
        self.controller = controller
        _draft = State(initialValue: controller.settingsStore.settings)
    }

    public var body: some View {
        Form {
            Section("General") {
                Toggle("Enable KeySwitcher", isOn: $draft.isEnabled)
                    .onChange(of: draft.isEnabled) { _, newValue in
                        controller.isEnabled = newValue
                        persist()
                    }
            }

            Section("Hotkeys") {
                ForEach(HotkeyAction.allCases) { action in
                    HStack {
                        Text(action.displayName)
                        Spacer()
                        if let hotkey = draft.hotkeys[action] {
                            Text(HotkeyManager.displayString(for: hotkey))
                                .font(.body.monospaced())
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.secondary.opacity(0.15))
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                        }
                        Button(recording == action ? "Press keys…" : "Record") {
                            recording = action
                        }
                        .disabled(recording != nil && recording != action)
                    }
                }

                Text("Default: Right ⌘ + Right ⇧ (layout), Right ⌘ + Right ⌥ (case)")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button("Reset to Defaults") {
                    draft = .defaults
                    persist()
                    recording = nil
                }
            }

            Section("Note") {
                Text("Record: press and release the chord (Right ⌘+Right ⇧). Escape cancels. Layout shortcut converts selection if present, otherwise the last typed word. Action runs on key release.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .frame(width: 520, height: 360)
        .keySwitcherBringWindowToFront()
        .background(HotkeyCaptureRepresentable(recording: $recording) { action, hotkey in
            draft.hotkeys[action] = hotkey
            persist()
            recording = nil
        })
        .navigationTitle("Settings")
    }

    private func persist() {
        controller.settingsStore.settings = draft
        controller.isEnabled = draft.isEnabled
        controller.reloadHotkeys()
    }
}

/// Records chords by physical modifier keyCodes (left vs right), not CGEvent device bits.
struct HotkeyCaptureRepresentable: NSViewRepresentable {
    @Binding var recording: HotkeyAction?
    var onCapture: (HotkeyAction, Hotkey) -> Void

    func makeNSView(context: Context) -> CaptureView {
        let view = CaptureView()
        view.parent = context.coordinator
        return view
    }

    func updateNSView(_ nsView: CaptureView, context: Context) {
        context.coordinator.recording = recording
        context.coordinator.onCapture = onCapture
        context.coordinator.onCancel = {
            recording = nil
        }
        nsView.isCapturing = recording != nil
        if recording == nil {
            context.coordinator.reset()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator {
        var recording: HotkeyAction?
        var onCapture: ((HotkeyAction, Hotkey) -> Void)?
        var onCancel: (() -> Void)?
        var held: Set<UInt16> = []
        var peakHeld: Set<UInt16> = []
        var armed = false

        func reset() {
            held.removeAll()
            peakHeld.removeAll()
            armed = false
        }

        func handleFlagsChanged(_ event: NSEvent) {
            guard recording != nil else { return }
            let code = UInt16(event.keyCode)
            guard ModifierKeyCode.all.contains(code) else { return }

            let flags = event.modifierFlags
            let flagOn: Bool
            switch code {
            case ModifierKeyCode.leftCommand, ModifierKeyCode.rightCommand:
                flagOn = flags.contains(.command)
            case ModifierKeyCode.leftShift, ModifierKeyCode.rightShift:
                flagOn = flags.contains(.shift)
            case ModifierKeyCode.leftOption, ModifierKeyCode.rightOption:
                flagOn = flags.contains(.option)
            case ModifierKeyCode.leftControl, ModifierKeyCode.rightControl:
                flagOn = flags.contains(.control)
            default:
                return
            }

            if held.contains(code) {
                held.remove(code)
                if !flagOn { clearFamily(code) }
            } else if flagOn {
                held.insert(code)
            } else {
                clearFamily(code)
            }

            peakHeld.formUnion(held)

            let primaryCount = primaryCount(in: peakHeld)
            if primaryCount >= 2 {
                armed = true
            }

            // Capture when releasing after a 2+ modifier chord
            if armed && held.isEmpty, let action = recording,
               let hotkey = HotkeyManager.hotkeyFrom(heldModifiers: peakHeld, keyCode: nil) {
                let captured = hotkey
                let cb = onCapture
                reset()
                DispatchQueue.main.async {
                    cb?(action, captured)
                }
            }
        }

        func handleKeyDown(_ event: NSEvent) -> Bool {
            guard let action = recording else { return false }
            if event.keyCode == 53 {
                reset()
                DispatchQueue.main.async { self.onCancel?() }
                return true
            }
            let code = UInt16(event.keyCode)
            if ModifierKeyCode.all.contains(code) { return false }

            let mods = held
            if mods.isEmpty { return false }
            guard let hotkey = HotkeyManager.hotkeyFrom(heldModifiers: mods, keyCode: code) else { return false }
            reset()
            DispatchQueue.main.async {
                self.onCapture?(action, hotkey)
            }
            return true
        }

        private func clearFamily(_ code: UInt16) {
            switch code {
            case ModifierKeyCode.leftCommand, ModifierKeyCode.rightCommand:
                held.remove(ModifierKeyCode.leftCommand)
                held.remove(ModifierKeyCode.rightCommand)
            case ModifierKeyCode.leftShift, ModifierKeyCode.rightShift:
                held.remove(ModifierKeyCode.leftShift)
                held.remove(ModifierKeyCode.rightShift)
            case ModifierKeyCode.leftOption, ModifierKeyCode.rightOption:
                held.remove(ModifierKeyCode.leftOption)
                held.remove(ModifierKeyCode.rightOption)
            case ModifierKeyCode.leftControl, ModifierKeyCode.rightControl:
                held.remove(ModifierKeyCode.leftControl)
                held.remove(ModifierKeyCode.rightControl)
            default: break
            }
        }

        private func primaryCount(in set: Set<UInt16>) -> Int {
            var kinds = Set<String>()
            for c in set {
                switch c {
                case ModifierKeyCode.leftCommand, ModifierKeyCode.rightCommand: kinds.insert("cmd")
                case ModifierKeyCode.leftShift, ModifierKeyCode.rightShift: kinds.insert("shift")
                case ModifierKeyCode.leftOption, ModifierKeyCode.rightOption: kinds.insert("opt")
                case ModifierKeyCode.leftControl, ModifierKeyCode.rightControl: kinds.insert("ctrl")
                default: break
                }
            }
            return kinds.count
        }
    }

    final class CaptureView: NSView {
        weak var parent: Coordinator?
        var isCapturing = false
        private var keyMonitor: Any?
        private var flagsMonitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if keyMonitor == nil {
                keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                    guard let self, self.isCapturing else { return event }
                    return self.parent?.handleKeyDown(event) == true ? nil : event
                }
            }
            if flagsMonitor == nil {
                flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
                    guard let self, self.isCapturing else { return event }
                    self.parent?.handleFlagsChanged(event)
                    return event
                }
            }
        }
    }
}
