import AppKit
import Foundation

public final class AppController: ObservableObject, HotkeyHandling {
    public static let shared = AppController()

    @Published public var isEnabled: Bool {
        didSet { enabledFlag.store(isEnabled) }
    }
    @Published public var statusMessage: String = ""
    @Published public var permissionStatus: PermissionStatus

    public let monitor = KeyboardMonitor()
    public let hotkeyManager: HotkeyManager
    public let settingsStore = SettingsStore.shared
    public let permissions = PermissionManager.shared
    public let inputSources = InputSourceManager.shared

    private let layoutConverter = LayoutConverter()
    private let caseConverter = CaseConverter()
    private let selectedText = SelectedTextService()
    private let accessibilityText = AccessibilityTextService()
    private let replacement = TextReplacementService()
    private let enabledFlag = AtomicBool(true)

    /// Selection captured early (often on Right ⌘ alone) before ⌘⇧ clears it.
    private var pendingLayoutSelection: String?
    /// Bundle ID of the app when `pendingLayoutSelection` was captured.
    private var pendingLayoutSelectionBundleID: String?
    /// True if we saw a non-empty selection during this layout chord.
    private var layoutChordSawSelection = false
    /// One clipboard snapshot attempt per layout chord (at arm time).
    private var layoutChordCopyAttempted = false
    /// Last non-empty AX selection observed outside of a dying ⌘⇧ chord.
    private var cachedSelection: String?
    /// User recently selected with mouse drag or Shift+arrows (Sublime has no AX selection).
    private var recentExplicitSelection = false
    private var mouseDownScreenPoint: CGPoint?
    private var wasHoldingLayoutModsForCapture = false

    private var diagnosticsTimer: Timer?
    private var selectionCacheTimer: Timer?

    public init() {
        let settings = SettingsStore.shared.settings
        isEnabled = settings.isEnabled
        enabledFlag.store(settings.isEnabled)
        hotkeyManager = HotkeyManager(settings: settings)
        permissionStatus = PermissionManager.shared.snapshot(eventTapActive: false, bufferHealthy: true)
        hotkeyManager.handler = self
        hotkeyManager.onHeldModifiersChanged = { [weak self] held in
            self?.captureSelectionEarlyIfNeeded(held: held)
        }
        monitor.hotkeyManager = hotkeyManager
        monitor.isEnabled = { [enabledFlag] in
            enabledFlag.load()
        }
        monitor.onExplicitSelectionGesture = { [weak self] in
            self?.recentExplicitSelection = true
            AppLogger.debug("Explicit selection gesture noted")
        }
        monitor.onTypingActivity = { [weak self] in
            self?.recentExplicitSelection = false
        }
        monitor.onAppSwitch = { [weak self] in
            self?.clearSelectionCaptureState(reason: "app-switch")
            self?.recentExplicitSelection = false
        }
    }

    public func start() {
        refreshPermissions()
        if permissions.isAccessibilityGranted() && permissions.isInputMonitoringGranted() {
            _ = monitor.start()
        } else {
            AppLogger.warning("Permissions missing — event tap not started")
        }
        hotkeyManager.update(from: settingsStore.settings)
        startDiagnosticsPolling()
        startSelectionCachePolling()
    }

    public func stop() {
        monitor.stop()
        diagnosticsTimer?.invalidate()
        diagnosticsTimer = nil
        selectionCacheTimer?.invalidate()
        selectionCacheTimer = nil
    }

    public func toggleEnabled() {
        isEnabled.toggle()
        var s = settingsStore.settings
        s.isEnabled = isEnabled
        settingsStore.settings = s
        statusMessage = isEnabled ? "Enabled" : "Disabled"
        AppLogger.info(isEnabled ? "App enabled" : "App disabled")
    }

    public func reloadHotkeys() {
        hotkeyManager.update(from: settingsStore.settings)
    }

    public func refreshPermissions() {
        permissionStatus = permissions.snapshot(
            eventTapActive: monitor.isTapActive,
            bufferHealthy: monitor.buffer.isHealthy
        )
    }

    public func ensureMonitoring() {
        refreshPermissions()
        if permissions.isAccessibilityGranted() && permissions.isInputMonitoringGranted() {
            if !monitor.isTapActive {
                _ = monitor.start()
            }
        }
        refreshPermissions()
    }

    // MARK: - HotkeyHandling

    /// Snapshot selection as soon as layout modifiers go down — before ⌘⇧ clears it.
    private func captureSelectionEarlyIfNeeded(held: Set<UInt16>) {
        let holdingCmd =
            held.contains(ModifierKeyCode.rightCommand)
            || held.contains(ModifierKeyCode.leftCommand)
        let holdingShift =
            held.contains(ModifierKeyCode.rightShift)
            || held.contains(ModifierKeyCode.leftShift)
        let holding = holdingCmd || holdingShift

        // New chord after idle → drop stale pending from Terminal/other apps
        if holding && !wasHoldingLayoutModsForCapture {
            clearSelectionCaptureState(reason: "new-chord")
        }
        wasHoldingLayoutModsForCapture = holding

        guard holding else {
            layoutChordCopyAttempted = false
            return
        }

        let bid = NSWorkspace.shared.frontmostApplication?.bundleIdentifier

        if let text = accessibilityText.selectedText(), !text.isEmpty {
            pendingLayoutSelection = text
            pendingLayoutSelectionBundleID = bid
            cachedSelection = text
            layoutChordSawSelection = true
            AppLogger.debug("Early AX selection snapshot (\(text.count) chars)")
        } else if case .present(let len) = accessibilityText.selectionPresence(), len > 0 {
            layoutChordSawSelection = true
            if pendingLayoutSelection == nil,
               let sliced = accessibilityText.selectedTextViaRange() {
                pendingLayoutSelection = sliced
                pendingLayoutSelectionBundleID = bid
                cachedSelection = sliced
                AppLogger.debug("Early AX range-slice snapshot (\(sliced.count) chars)")
            } else {
                AppLogger.debug("Early AX selection range present (len=\(len))")
            }
        }
    }

    private func clearSelectionCaptureState(reason: String) {
        if pendingLayoutSelection != nil || layoutChordSawSelection {
            AppLogger.debug("Clear selection capture (\(reason))")
        }
        pendingLayoutSelection = nil
        pendingLayoutSelectionBundleID = nil
        layoutChordSawSelection = false
        layoutChordCopyAttempted = false
    }

    private func startSelectionCachePolling() {
        selectionCacheTimer?.invalidate()
        // Disabled noisy AX polling — it spammed logs and cached cross-app selections.
        selectionCacheTimer = nil
        cachedSelection = nil
    }

    private func finishSelectionConversion(_ converted: ConversionResult) {
        clearSelectionCaptureState(reason: "finish")
        cachedSelection = nil
        recentExplicitSelection = false
        _ = inputSources.selectLayout(converted.targetLayout)
        flashStatus("Switched selection → \(converted.targetLayout.rawValue)")
        AppLogger.info("Conversion succeeded (selection)")
    }

    public func hotkeyTriggered(_ action: HotkeyAction) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard self.isEnabled else {
                self.flashStatus("Disabled")
                return
            }
            switch action {
            case .switchLayout:
                Task { await self.switchLayoutSmart() }
            case .changeSelectedCase:
                Task { await self.changeSelectedCase() }
            }
        }
    }

    // MARK: - Operations

    /// Smart layout switch: selection if present, otherwise last word.
    public func switchLayoutSmart() async {
        defer {
            clearSelectionCaptureState(reason: "smart-defer")
            recentExplicitSelection = false
        }

        let lastWordHint = monitor.buffer.lastWord()?.word
        let presence = accessibilityText.selectionPresence()
        let liveSelected = accessibilityText.selectedText()
        let frontID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier

        // Pending only if captured for THIS frontmost app and not absurdly large vs a word.
        let pending: String? = {
            guard let p = pendingLayoutSelection, !p.isEmpty else { return nil }
            guard pendingLayoutSelectionBundleID == frontID else {
                AppLogger.trace("Ignoring pending from other app \(pendingLayoutSelectionBundleID ?? "nil")")
                return nil
            }
            if p.count > 200 {
                AppLogger.trace("Ignoring oversized pending (\(p.count) chars)")
                return nil
            }
            return p
        }()

        let hasAXSelection =
            (liveSelected.map { !$0.isEmpty } ?? false)
            || (pending.map { !$0.isEmpty } ?? false)
            || {
                if case .present = presence { return true }
                return false
            }()

        AppLogger.trace("""
            switchLayoutSmart BEGIN
            \(accessibilityText.probeReport())
            pending=\(pending.map { $0.debugDescription } ?? "nil")
            layoutChordSawSelection=\(layoutChordSawSelection)
            recentExplicitSelection=\(recentExplicitSelection)
            lastWordHint=\(lastWordHint.map { $0.debugDescription } ?? "nil")
            hasAXSelection=\(hasAXSelection)
            """)

        // 1) Live / fresh pending AX text
        if let liveSelected, !liveSelected.isEmpty {
            AppLogger.trace("branch: replaceLayoutSelection(live)")
            if await replaceLayoutSelection(liveSelected) {
                AppLogger.trace("switchLayoutSmart END ok=live")
                return
            }
        }
        if let pending {
            AppLogger.trace("branch: replaceLayoutSelection(pending) — verified paste only")
            if await replaceLayoutSelection(pending) {
                AppLogger.trace("switchLayoutSmart END ok=pending")
                return
            }
        }

        // 2) Known selection (AX range or explicit mouse/keyboard selection) → case-path clipboard
        if hasAXSelection || recentExplicitSelection || layoutChordSawSelection {
            AppLogger.trace("branch: convertSelectionLikeCaseChange")
            if await convertSelectionLikeCaseChange() {
                AppLogger.trace("switchLayoutSmart END ok=case-path")
                return
            }
            // Sublime: AX blind but selection exists — case-path should have worked via Cmd+C.
            // If it failed, do NOT paste stale data; fall through to last word only if no explicit selection.
            if hasAXSelection || recentExplicitSelection {
                AppLogger.trace("switchLayoutSmart END fail=selection")
                await MainActor.run { self.flashStatus("Selection replace failed") }
                return
            }
        }

        // 3) AX-unknown without explicit selection evidence → last word (safe)
        AppLogger.trace("branch: switchLastWord")
        switchLastWord()
        AppLogger.trace("switchLayoutSmart END lastWord")
    }

    /// Dump AX state of the frontmost app into the log + status (for manual debugging).
    public func probeFrontmostSelection() {
        let report = accessibilityText.probeReport()
        AppLogger.trace("MANUAL PROBE\n\(report)")
        flashStatus("Probe written to log")
        let url = AppLogger.logFileURL
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    public func openLogFile() {
        NSWorkspace.shared.activateFileViewerSelecting([AppLogger.logFileURL])
    }

    public func clearDebugLog() {
        AppLogger.clearLogFile()
        flashStatus("Log cleared")
    }

    /// Identical strategy to Change Case (AX → clipboard transformSelection).
    private func convertSelectionLikeCaseChange() async -> Bool {
        let converter = layoutConverter
        let box = LayoutBox()
        let ok = await selectedText.transformSelection { text in
            guard let converted = converter.convert(text) else { return nil }
            box.layout = converted.targetLayout
            return converted.text
        }
        if ok {
            await MainActor.run {
                if let layout = box.layout {
                    _ = self.inputSources.selectLayout(layout)
                }
                self.cachedSelection = nil
                self.flashStatus("Switched selection")
                AppLogger.info("Conversion succeeded (selection, case-path)")
            }
        }
        return ok
    }

    private func convertSelectionViaClipboardSafe(lastWordHint: String?) async -> Bool {
        let converter = layoutConverter
        let box = LayoutBox()
        let ok = await selectedText.transformSelectionForLayoutSwitch(lastWordHint: lastWordHint) { text in
            guard let converted = converter.convert(text) else { return nil }
            box.layout = converted.targetLayout
            return converted.text
        }
        if ok {
            await MainActor.run {
                if let layout = box.layout {
                    _ = self.inputSources.selectLayout(layout)
                }
                self.cachedSelection = nil
                self.flashStatus("Switched selection")
                AppLogger.info("Conversion succeeded (selection, guarded clipboard)")
            }
        }
        return ok
    }

    @discardableResult
    private func replaceLayoutSelection(_ text: String) async -> Bool {
        guard let converted = layoutConverter.convert(text) else {
            await MainActor.run {
                self.flashStatus("Cannot convert selection")
            }
            AppLogger.warning("Selection convert failed")
            return false
        }
        let ok = await selectedText.replaceCapturedSelection(text, with: converted.text)
        AppLogger.trace("replaceLayoutSelection ok=\(ok) originalLen=\(text.count) replacementLen=\(converted.text.count)")
        await MainActor.run {
            if ok {
                self.finishSelectionConversion(converted)
            } else {
                self.flashStatus("Selection replace failed")
                AppLogger.warning("Selection replace failed")
            }
        }
        return ok
    }

    public func switchLastWord() {
        guard monitor.buffer.isHealthy else {
            flashStatus("Buffer unreliable")
            AppLogger.warning("Switch last word aborted: buffer unreliable")
            return
        }
        guard let match = monitor.buffer.lastWord() else {
            flashStatus("No word")
            AppLogger.info("Switch last word: no word in buffer")
            return
        }
        guard let converted = layoutConverter.convert(match.word) else {
            flashStatus("Cannot convert")
            AppLogger.warning("Switch last word: conversion failed")
            return
        }

        let expected = match.word + match.trailingSeparators
        let insert = converted.text + match.trailingSeparators
        let ok = replacement.replaceLastWord(
            deleteCount: match.deleteCount,
            insert: insert,
            expected: expected
        )
        if ok {
            monitor.buffer.replaceWithTrusted(insert)
            _ = inputSources.selectLayout(converted.targetLayout)
            flashStatus("Switched word → \(converted.targetLayout.rawValue)")
            AppLogger.info("Conversion succeeded (last word), layout=\(converted.targetLayout.rawValue)")
        } else {
            flashStatus("Replace failed")
            AppLogger.warning("Last word UI replace failed — buffer unchanged")
        }
    }

    public func switchSelectedText() async {
        let box = LayoutBox()
        let converter = layoutConverter
        let ok = await selectedText.transformSelection { text in
            guard let converted = converter.convert(text) else { return nil }
            box.layout = converted.targetLayout
            return converted.text
        }
        let layout = box.layout
        await MainActor.run {
            if ok {
                if let layout {
                    _ = self.inputSources.selectLayout(layout)
                }
                self.flashStatus("Switched selection")
                AppLogger.info("Conversion succeeded (selection)")
            } else {
                self.flashStatus("No selection / failed")
                AppLogger.warning("Switch selected failed")
            }
        }
    }

    public func changeSelectedCase() async {
        let converter = caseConverter
        let ok = await selectedText.transformSelection { text in
            let converted = converter.convert(text)
            return converted == text ? nil : converted
        }
        await MainActor.run {
            self.flashStatus(ok ? "Case changed" : "No selection / failed")
            if ok {
                AppLogger.info("Case conversion succeeded")
            } else {
                AppLogger.warning("Case conversion failed")
            }
        }
    }

    private func flashStatus(_ message: String) {
        statusMessage = message
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            if self?.statusMessage == message {
                self?.statusMessage = ""
            }
        }
    }

    private func startDiagnosticsPolling() {
        diagnosticsTimer?.invalidate()
        diagnosticsTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            DispatchQueue.main.async {
                self?.refreshPermissions()
            }
        }
    }
}

private final class AtomicBool: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Bool

    init(_ value: Bool) {
        self.value = value
    }

    func store(_ newValue: Bool) {
        lock.lock()
        value = newValue
        lock.unlock()
    }

    func load() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

private final class LayoutBox: @unchecked Sendable {
    var layout: KeyboardLayoutID?
}
