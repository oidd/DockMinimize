//
//  HotkeyManager.swift
//  DockMinimize
//

import Cocoa
import Carbon.HIToolbox

extension Notification.Name {
    static let hotkeyBindingsChanged = Notification.Name("hotkeyBindingsChanged")
}

struct AppHotkeyBinding: Codable, Identifiable, Equatable {
    let bundleID: String
    var shortcut: KeyboardShortcut?

    var id: String { bundleID }
}

struct KeyboardShortcut: Codable, Equatable, Hashable {
    let keyCode: Int
    let modifierFlagsRawValue: UInt64

    init(keyCode: Int, modifierFlags: NSEvent.ModifierFlags) {
        self.keyCode = keyCode
        self.modifierFlagsRawValue = UInt64(modifierFlags.normalizedShortcutFlags.rawValue)
    }

    var modifierFlags: NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(rawValue: UInt(modifierFlagsRawValue)).normalizedShortcutFlags
    }

    var displayString: String {
        let modifierPart = modifierFlags.displayString
        let keyPart = Self.keyDisplayName(for: keyCode)
        return modifierPart.isEmpty ? keyPart : modifierPart + keyPart
    }

    var isValidGlobalShortcut: Bool {
        !modifierFlags.isEmpty || Self.functionKeyKeyCodes.contains(keyCode)
    }

    func matches(keyCode: Int, modifierFlags: NSEvent.ModifierFlags) -> Bool {
        self.keyCode == keyCode && self.modifierFlags == modifierFlags.normalizedShortcutFlags
    }

    private static let functionKeyKeyCodes: Set<Int> = [
        Int(kVK_F1), Int(kVK_F2), Int(kVK_F3), Int(kVK_F4), Int(kVK_F5),
        Int(kVK_F6), Int(kVK_F7), Int(kVK_F8), Int(kVK_F9), Int(kVK_F10),
        Int(kVK_F11), Int(kVK_F12), Int(kVK_F13), Int(kVK_F14), Int(kVK_F15),
        Int(kVK_F16), Int(kVK_F17), Int(kVK_F18), Int(kVK_F19), Int(kVK_F20)
    ]

    private static func keyDisplayName(for keyCode: Int) -> String {
        switch keyCode {
        case Int(kVK_ANSI_A): return "A"
        case Int(kVK_ANSI_B): return "B"
        case Int(kVK_ANSI_C): return "C"
        case Int(kVK_ANSI_D): return "D"
        case Int(kVK_ANSI_E): return "E"
        case Int(kVK_ANSI_F): return "F"
        case Int(kVK_ANSI_G): return "G"
        case Int(kVK_ANSI_H): return "H"
        case Int(kVK_ANSI_I): return "I"
        case Int(kVK_ANSI_J): return "J"
        case Int(kVK_ANSI_K): return "K"
        case Int(kVK_ANSI_L): return "L"
        case Int(kVK_ANSI_M): return "M"
        case Int(kVK_ANSI_N): return "N"
        case Int(kVK_ANSI_O): return "O"
        case Int(kVK_ANSI_P): return "P"
        case Int(kVK_ANSI_Q): return "Q"
        case Int(kVK_ANSI_R): return "R"
        case Int(kVK_ANSI_S): return "S"
        case Int(kVK_ANSI_T): return "T"
        case Int(kVK_ANSI_U): return "U"
        case Int(kVK_ANSI_V): return "V"
        case Int(kVK_ANSI_W): return "W"
        case Int(kVK_ANSI_X): return "X"
        case Int(kVK_ANSI_Y): return "Y"
        case Int(kVK_ANSI_Z): return "Z"
        case Int(kVK_ANSI_0): return "0"
        case Int(kVK_ANSI_1): return "1"
        case Int(kVK_ANSI_2): return "2"
        case Int(kVK_ANSI_3): return "3"
        case Int(kVK_ANSI_4): return "4"
        case Int(kVK_ANSI_5): return "5"
        case Int(kVK_ANSI_6): return "6"
        case Int(kVK_ANSI_7): return "7"
        case Int(kVK_ANSI_8): return "8"
        case Int(kVK_ANSI_9): return "9"
        case Int(kVK_ANSI_Minus): return "-"
        case Int(kVK_ANSI_Equal): return "="
        case Int(kVK_ANSI_LeftBracket): return "["
        case Int(kVK_ANSI_RightBracket): return "]"
        case Int(kVK_ANSI_Backslash): return "\\"
        case Int(kVK_ANSI_Semicolon): return ";"
        case Int(kVK_ANSI_Quote): return "'"
        case Int(kVK_ANSI_Comma): return ","
        case Int(kVK_ANSI_Period): return "."
        case Int(kVK_ANSI_Slash): return "/"
        case Int(kVK_ANSI_Grave): return "`"
        case Int(kVK_Return): return "↩"
        case Int(kVK_Tab): return "⇥"
        case Int(kVK_Space): return "Space"
        case Int(kVK_Delete): return "⌫"
        case Int(kVK_ForwardDelete): return "⌦"
        case Int(kVK_Escape): return "⎋"
        case Int(kVK_LeftArrow): return "←"
        case Int(kVK_RightArrow): return "→"
        case Int(kVK_UpArrow): return "↑"
        case Int(kVK_DownArrow): return "↓"
        case Int(kVK_Home): return "Home"
        case Int(kVK_End): return "End"
        case Int(kVK_PageUp): return "Page Up"
        case Int(kVK_PageDown): return "Page Down"
        case Int(kVK_F1): return "F1"
        case Int(kVK_F2): return "F2"
        case Int(kVK_F3): return "F3"
        case Int(kVK_F4): return "F4"
        case Int(kVK_F5): return "F5"
        case Int(kVK_F6): return "F6"
        case Int(kVK_F7): return "F7"
        case Int(kVK_F8): return "F8"
        case Int(kVK_F9): return "F9"
        case Int(kVK_F10): return "F10"
        case Int(kVK_F11): return "F11"
        case Int(kVK_F12): return "F12"
        case Int(kVK_F13): return "F13"
        case Int(kVK_F14): return "F14"
        case Int(kVK_F15): return "F15"
        case Int(kVK_F16): return "F16"
        case Int(kVK_F17): return "F17"
        case Int(kVK_F18): return "F18"
        case Int(kVK_F19): return "F19"
        case Int(kVK_F20): return "F20"
        default: return "Key \(keyCode)"
        }
    }
}

extension NSEvent.ModifierFlags {
    static let shortcutRelevantFlags: NSEvent.ModifierFlags = [.command, .option, .control, .shift]

    var normalizedShortcutFlags: NSEvent.ModifierFlags {
        intersection(.shortcutRelevantFlags)
    }

    var displayString: String {
        var output = ""
        if contains(.control) { output += "⌃" }
        if contains(.option) { output += "⌥" }
        if contains(.shift) { output += "⇧" }
        if contains(.command) { output += "⌘" }
        return output
    }
}

extension CGEventFlags {
    var normalizedShortcutFlags: NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(rawValue: UInt(rawValue)).normalizedShortcutFlags
    }
}

final class HotkeyMonitor {
    static let shared = HotkeyMonitor()

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var activeBindings: [KeyboardShortcut: String] = [:]
    private let stateLock = NSLock()

    private var suspendedForRecording = false

    private init() {}

    var hasRegisteredHotkeys: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return !activeBindings.isEmpty
    }

    func start() {
        reloadBindings()
    }

    func stop() {
        stateLock.lock()
        activeBindings = [:]
        suspendedForRecording = false
        stateLock.unlock()
        stopTap()
    }

    func reloadBindings() {
        var bindings: [KeyboardShortcut: String] = [:]
        for binding in SettingsManager.shared.hotkeyBindings {
            guard let shortcut = binding.shortcut else { continue }
            bindings[shortcut] = binding.bundleID
        }

        stateLock.lock()
        activeBindings = bindings
        stateLock.unlock()

        guard AccessibilityManager.shared.isAccessibilityEnabled, !bindings.isEmpty else {
            stopTap()
            return
        }

        if eventTap == nil {
            installTap()
        } else if let tap = eventTap, !CGEvent.tapIsEnabled(tap: tap) {
            CGEvent.tapEnable(tap: tap, enable: true)
        }
    }

    func suspendForRecording() {
        stateLock.lock()
        suspendedForRecording = true
        stateLock.unlock()
    }

    func resumeAfterRecording() {
        stateLock.lock()
        suspendedForRecording = false
        stateLock.unlock()
    }

    func isAlive() -> Bool {
        if !hasRegisteredHotkeys {
            return true
        }

        guard let tap = eventTap else { return false }
        return CGEvent.tapIsEnabled(tap: tap)
    }

    private func installTap() {
        let eventMask = (1 << CGEventType.keyDown.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(eventMask),
            callback: { _, type, event, refcon -> Unmanaged<CGEvent>? in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
                return monitor.handleEvent(type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            DebugLogger.shared.log("⚠️ [HotkeyMonitor] Failed to create keyboard event tap.")
            return
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        if let runLoopSource {
            CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func stopTap() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
    }

    private func handleEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        guard type == .keyDown else { return Unmanaged.passUnretained(event) }
        guard event.getIntegerValueField(.keyboardEventAutorepeat) == 0 else {
            return Unmanaged.passUnretained(event)
        }

        let shouldPassThrough: Bool = {
            stateLock.lock()
            defer { stateLock.unlock() }
            return suspendedForRecording || activeBindings.isEmpty
        }()

        if shouldPassThrough {
            return Unmanaged.passUnretained(event)
        }

        let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
        let modifierFlags = event.flags.normalizedShortcutFlags

        let matchedBinding: (KeyboardShortcut, String)? = {
            stateLock.lock()
            defer { stateLock.unlock() }
            return activeBindings.first(where: { shortcut, _ in
                shortcut.matches(keyCode: keyCode, modifierFlags: modifierFlags)
            })
        }()

        guard let (shortcut, bundleID) = matchedBinding else {
            return Unmanaged.passUnretained(event)
        }

        DispatchQueue.main.async {
            self.toggleTargetApplication(bundleID: bundleID, shortcut: shortcut)
        }
        return nil
    }

    private func toggleTargetApplication(bundleID: String, shortcut: KeyboardShortcut) {
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .first(where: { !$0.isTerminated }) {
            
            // ⭐️ 核心修复：优先咨询 SideBarBridge，确保 whitelisted app 的状态由 SideBar 决定
            if SideBarBridge.shared.shouldForwardHotkey(for: bundleID) {
                SideBarBridge.shared.requestSideBarHotkeyAction(bundleID: bundleID, shortcut: shortcut) { handled in
                    if !handled {
                        DispatchQueue.main.async {
                            WindowManager.shared.toggleWindows(for: app, source: .hotkey)
                        }
                    }
                }
            } else {
                WindowManager.shared.toggleWindows(for: app, source: .hotkey)
            }
            return
        }

        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            DebugLogger.shared.log("⚠️ [HotkeyMonitor] Unable to find app URL for \(bundleID)")
            return
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: appURL, configuration: configuration, completionHandler: nil)
    }
}

final class HotkeyCaptureCenter: ObservableObject {
    static let shared = HotkeyCaptureCenter()

    @Published private(set) var recordingBundleID: String?
    @Published private(set) var statusMessage: String?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var completion: ((KeyboardShortcut?) -> Void)?
    private var localMouseMonitor: Any?
    private var globalMouseMonitor: Any?

    private init() {}

    func beginRecording(for bundleID: String, onCapture: @escaping (KeyboardShortcut?) -> Void) {
        cancelRecording()

        guard AccessibilityManager.shared.isAccessibilityEnabled else {
            statusMessage = SettingsManager.shared.t("请先开启辅助功能权限后再录制快捷键。", "Enable Accessibility permission before recording a hotkey.")
            AccessibilityManager.shared.requestAccessibility()
            return
        }

        recordingBundleID = bundleID
        statusMessage = nil
        completion = onCapture
        HotkeyMonitor.shared.suspendForRecording()

        installTap()
        installMouseCancellationMonitors()
    }

    func cancelRecording() {
        finish(with: nil)
    }

    private func installTap() {
        let eventMask = (1 << CGEventType.keyDown.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(eventMask),
            callback: { _, type, event, refcon -> Unmanaged<CGEvent>? in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let recorder = Unmanaged<HotkeyCaptureCenter>.fromOpaque(refcon).takeUnretainedValue()
                return recorder.handleEvent(type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            statusMessage = SettingsManager.shared.t("快捷键录制启动失败，请确认辅助功能权限仍然有效。", "Failed to start recording. Please confirm Accessibility permission is still active.")
            finish(with: nil)
            return
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        if let runLoopSource {
            CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func stopTap() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
    }

    private func installMouseCancellationMonitors() {
        removeMouseCancellationMonitors()

        localMouseMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] event in
            guard let self, self.recordingBundleID != nil else { return event }
            DispatchQueue.main.async {
                self.cancelRecording()
            }
            return event
        }

        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            guard let self, self.recordingBundleID != nil else { return }
            DispatchQueue.main.async {
                self.cancelRecording()
            }
        }
    }

    private func removeMouseCancellationMonitors() {
        if let localMouseMonitor {
            NSEvent.removeMonitor(localMouseMonitor)
            self.localMouseMonitor = nil
        }
        if let globalMouseMonitor {
            NSEvent.removeMonitor(globalMouseMonitor)
            self.globalMouseMonitor = nil
        }
    }

    private func handleEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        guard type == .keyDown else { return Unmanaged.passUnretained(event) }

        let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
        let modifierFlags = event.flags.normalizedShortcutFlags

        if keyCode == Int(kVK_Escape) && modifierFlags.isEmpty {
            DispatchQueue.main.async {
                self.finish(with: nil)
            }
            return nil
        }

        let shortcut = KeyboardShortcut(keyCode: keyCode, modifierFlags: modifierFlags)
        guard shortcut.isValidGlobalShortcut else {
            DispatchQueue.main.async {
                self.statusMessage = SettingsManager.shared.t(
                    "请至少使用一个修饰键，或者直接使用 F1-F20 功能键。",
                    "Use at least one modifier key, or bind a standalone F1-F20 function key."
                )
            }
            return nil
        }

        DispatchQueue.main.async {
            self.finish(with: shortcut)
        }
        return nil
    }

    private func finish(with shortcut: KeyboardShortcut?) {
        stopTap()
        removeMouseCancellationMonitors()

        let callback = completion
        completion = nil
        recordingBundleID = nil
        if shortcut != nil {
            statusMessage = nil
        }
        HotkeyMonitor.shared.resumeAfterRecording()

        callback?(shortcut)
    }
}
