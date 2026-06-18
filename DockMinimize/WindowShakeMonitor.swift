//
//  WindowShakeMonitor.swift
//  DockMinimize
//

import Cocoa
import ApplicationServices

final class WindowShakeMonitor {
    static let shared = WindowShakeMonitor()

    private struct TrackingState {
        let target: WindowFocusTarget
        let initialBounds: CGRect
        var lastBounds: CGRect
        var lastSampleAt: Date
        var didConfirmWindowMove = false
        var didTrigger = false
        var firstDirectionAt: Date?
        var lastDirection = 0
        var segmentAnchorX: CGFloat
        var segmentExtremeX: CGFloat
        var directionChanges = 0
    }

    private let queue = DispatchQueue(label: "com.dockminimize.windowShake", qos: .userInteractive)
    private let log = DebugLogger.shared

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var trackingState: TrackingState?
    private var lastTriggerAt: Date = .distantPast

    private let minSampleInterval: TimeInterval = 0.016
    private let triggerCooldown: TimeInterval = 1.0
    private let maxShakeDuration: TimeInterval = 1.05
    private let minWindowMoveToArm: CGFloat = 12
    private let minSampleDeltaX: CGFloat = 3
    private let minSegmentDistance: CGFloat = 34
    private let requiredDirectionChanges = 3

    private init() {}

    func start() {
        guard eventTap == nil else { return }
        guard SettingsManager.shared.shakeToFocusEnabled else { return }

        let eventMask =
            (1 << CGEventType.leftMouseDown.rawValue) |
            (1 << CGEventType.leftMouseDragged.rawValue) |
            (1 << CGEventType.leftMouseUp.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(eventMask),
            callback: { _, type, event, refcon -> Unmanaged<CGEvent>? in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<WindowShakeMonitor>.fromOpaque(refcon).takeUnretainedValue()
                monitor.enqueue(type: type, event: event)
                return Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            log.log("[ShakeToFocus] Failed to create event tap.")
            return
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        if let runLoopSource {
            CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        CGEvent.tapEnable(tap: tap, enable: true)
        log.log("[ShakeToFocus] Monitor started")
    }

    func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
        queue.async { [weak self] in
            self?.trackingState = nil
        }
    }

    func isAlive() -> Bool {
        guard SettingsManager.shared.shakeToFocusEnabled else { return true }
        guard let tap = eventTap else { return false }
        return CGEvent.tapIsEnabled(tap: tap)
    }

    private func enqueue(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return
        }

        let location = event.location
        queue.async { [weak self] in
            self?.handle(type: type, location: location)
        }
    }

    private func handle(type: CGEventType, location: CGPoint) {
        guard SettingsManager.shared.shakeToFocusEnabled else {
            trackingState = nil
            return
        }

        switch type {
        case .leftMouseDown:
            beginTracking(at: location)
        case .leftMouseDragged:
            updateTracking()
        case .leftMouseUp:
            trackingState = nil
        default:
            break
        }
    }

    private func beginTracking(at location: CGPoint) {
        trackingState = nil

        guard Date().timeIntervalSince(lastTriggerAt) >= triggerCooldown else {
            return
        }

        guard let candidate = topLevelWindow(at: location),
              let bounds = currentBounds(for: candidate.windowId) else {
            return
        }

        trackingState = TrackingState(
            target: candidate,
            initialBounds: bounds,
            lastBounds: bounds,
            lastSampleAt: Date(),
            segmentAnchorX: bounds.midX,
            segmentExtremeX: bounds.midX
        )
    }

    private func updateTracking() {
        guard var state = trackingState, !state.didTrigger else { return }

        let now = Date()
        guard now.timeIntervalSince(state.lastSampleAt) >= minSampleInterval else {
            return
        }

        guard let bounds = currentBounds(for: state.target.windowId) else {
            trackingState = nil
            return
        }

        let previousX = state.lastBounds.midX
        let currentX = bounds.midX
        let sampleDeltaX = currentX - previousX
        state.lastBounds = bounds
        state.lastSampleAt = now

        if !state.didConfirmWindowMove {
            let movedDistance = hypot(
                bounds.midX - state.initialBounds.midX,
                bounds.midY - state.initialBounds.midY
            )
            if movedDistance >= minWindowMoveToArm {
                state.didConfirmWindowMove = true
            } else {
                trackingState = state
                return
            }
        }

        guard abs(sampleDeltaX) >= minSampleDeltaX else {
            trackingState = state
            return
        }

        let direction = sampleDeltaX > 0 ? 1 : -1

        if let firstDirectionAt = state.firstDirectionAt,
           now.timeIntervalSince(firstDirectionAt) > maxShakeDuration {
            resetShakeCounters(&state, currentX: currentX, direction: direction, now: now)
            trackingState = state
            return
        }

        if state.lastDirection == 0 {
            resetShakeCounters(&state, currentX: currentX, direction: direction, now: now)
            trackingState = state
            return
        }

        if direction == state.lastDirection {
            updateSegmentExtreme(&state, currentX: currentX)
        } else {
            let segmentDistance = abs(state.segmentExtremeX - state.segmentAnchorX)
            if segmentDistance >= minSegmentDistance {
                state.directionChanges += 1
                state.segmentAnchorX = state.segmentExtremeX
                state.lastDirection = direction
                state.segmentExtremeX = currentX
            } else {
                state.lastDirection = direction
                state.segmentAnchorX = currentX
                state.segmentExtremeX = currentX
            }
        }

        if state.directionChanges >= requiredDirectionChanges {
            state.didTrigger = true
            lastTriggerAt = now
            triggerShakeFocus(for: state.target)
        }

        trackingState = state
    }

    private func resetShakeCounters(
        _ state: inout TrackingState,
        currentX: CGFloat,
        direction: Int,
        now: Date
    ) {
        state.firstDirectionAt = now
        state.lastDirection = direction
        state.segmentAnchorX = currentX
        state.segmentExtremeX = currentX
        state.directionChanges = 0
    }

    private func updateSegmentExtreme(_ state: inout TrackingState, currentX: CGFloat) {
        if state.lastDirection > 0 {
            state.segmentExtremeX = max(state.segmentExtremeX, currentX)
        } else {
            state.segmentExtremeX = min(state.segmentExtremeX, currentX)
        }
    }

    private func triggerShakeFocus(for target: WindowFocusTarget) {
        log.log("[ShakeToFocus] Triggered for \(target.bundleID) window \(target.windowId)")
        DispatchQueue.main.async {
            // 把"聚焦 / 恢复"的判定收口到 WindowManager，由它根据桌面状态和快照决定走哪条分支。
            WindowManager.shared.handleShakeGesture(for: target)
        }
    }

    private func topLevelWindow(at point: CGPoint) -> WindowFocusTarget? {
        guard let windowList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return nil
        }

        let ownBundleID = Bundle.main.bundleIdentifier ?? "com.dockminimize.app"

        for windowInfo in windowList {
            guard let windowId = cgWindowID(from: windowInfo[kCGWindowNumber as String]),
                  let ownerPID = pid(from: windowInfo[kCGWindowOwnerPID as String]),
                  let bounds = cgRect(from: windowInfo[kCGWindowBounds as String]) else {
                continue
            }

            if !bounds.contains(point) { continue }
            if bounds.width < 100 || bounds.height < 100 { continue }
            if let layer = intValue(from: windowInfo[kCGWindowLayer as String]), layer != 0 { continue }
            if let alpha = cgFloat(from: windowInfo[kCGWindowAlpha as String]), alpha < 0.1 { continue }
            if let sharingState = intValue(from: windowInfo[kCGWindowSharingState as String]), sharingState == 0 { continue }

            guard let app = NSRunningApplication(processIdentifier: ownerPID),
                  !app.isTerminated,
                  let bundleID = app.bundleIdentifier else {
                return nil
            }

            if ownerPID == getpid() ||
               bundleID == ownBundleID ||
               bundleID == "com.apple.dock" ||
               bundleID == "com.apple.systemuiserver" ||
               bundleID == "com.ivean.SideBar" ||
               SettingsManager.shared.shouldSkipDockHandling(bundleID: bundleID) {
                return nil
            }

            return WindowFocusTarget(
                windowId: windowId,
                ownerPID: ownerPID,
                bundleID: bundleID
            )
        }

        return nil
    }

    private func currentBounds(for windowId: CGWindowID) -> CGRect? {
        guard let windowList = CGWindowListCopyWindowInfo(
            [.optionIncludingWindow, .excludeDesktopElements],
            windowId
        ) as? [[String: Any]],
              let windowInfo = windowList.first else {
            return nil
        }

        return cgRect(from: windowInfo[kCGWindowBounds as String])
    }

    private func cgWindowID(from value: Any?) -> CGWindowID? {
        if let value = value as? CGWindowID {
            return value
        }
        if let value = value as? UInt32 {
            return CGWindowID(value)
        }
        if let value = value as? Int, value >= 0 {
            return CGWindowID(value)
        }
        if let value = value as? NSNumber {
            return CGWindowID(truncating: value)
        }
        return nil
    }

    private func pid(from value: Any?) -> pid_t? {
        if let value = value as? pid_t {
            return value
        }
        if let value = value as? Int {
            return pid_t(value)
        }
        if let value = value as? NSNumber {
            return pid_t(truncating: value)
        }
        return nil
    }

    private func intValue(from value: Any?) -> Int? {
        if let value = value as? Int {
            return value
        }
        if let value = value as? NSNumber {
            return value.intValue
        }
        return nil
    }

    private func cgFloat(from value: Any?) -> CGFloat? {
        if let value = value as? CGFloat {
            return value
        }
        if let value = value as? Double {
            return CGFloat(value)
        }
        if let value = value as? Int {
            return CGFloat(value)
        }
        if let value = value as? NSNumber {
            return CGFloat(truncating: value)
        }
        return nil
    }

    private func cgRect(from value: Any?) -> CGRect? {
        guard let dict = value as? [String: Any],
              let x = cgFloat(from: dict["X"]),
              let y = cgFloat(from: dict["Y"]),
              let width = cgFloat(from: dict["Width"]),
              let height = cgFloat(from: dict["Height"]) else {
            return nil
        }

        return CGRect(x: x, y: y, width: width, height: height)
    }
}
