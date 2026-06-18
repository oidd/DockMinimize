//
//  WindowManager.swift
//  DockMinimize
//
//  Created by Dock Minimize
//

import Cocoa
import ApplicationServices
import SwiftUI

enum WindowToggleSource {
    case dock
    case hotkey

    var respectsDockExclusions: Bool {
        switch self {
        case .dock:
            return true
        case .hotkey:
            return false
        }
    }
}

struct WindowFocusTarget: Equatable {
    let windowId: CGWindowID
    let ownerPID: pid_t
    let bundleID: String
}

class WindowManager: NSObject {
    static let shared = WindowManager()
    
    /// 存储已最小化的应用
    private var minimizedApps: Set<String> = []
    private var hideRequestGeneration: [String: Int] = [:]
    
    /// 递归检查是否正在进行窗口操作，防止连击导致的竞态和崩溃
    var isTransitioning: Bool = false
    
    /// 仅在 SideBar 刚把 floating 窗口交还给 DockMinimize 时，短暂抑制重复切换。
    private var appsInTransition: Set<String> = []
    private let transitionLockQueue = DispatchQueue(label: "com.dockminimize.transitionlock")
    private let detachedFloatingLockDuration: TimeInterval = 0.18

    private struct VisibleWindowSnapshot {
        let windowId: CGWindowID
        let ownerPID: pid_t
        let bundleID: String
    }

    // MARK: - 摇窗聚焦：状态机
    /// 记录上一次"摇窗聚焦"行为最小化掉的窗口集合。
    /// 当用户再次摇窗、且"再次摇晃恢复窗口"开关开启、且桌面已经没有其它可见窗口时，
    /// 用这个快照把曾经被最小化的窗口一次性恢复。
    ///
    /// 设计原则：判定只依赖"桌面是否还有其它可见窗口"，不依赖时间窗口、目标窗口一致性等隐性规则。
    /// 因此快照仅承载"最小化窗口列表"这一项必要数据，不存储 windowId / bundleID / createdAt 等
    /// 用不到的字段，避免误导后续维护者以为存在更复杂的判定逻辑。
    fileprivate struct ShakeFocusSnapshot {
        struct WindowRef: Equatable {
            let windowId: CGWindowID
            let ownerPID: pid_t
            let bundleID: String
        }

        var minimizedWindows: [WindowRef]
    }

    private var shakeFocusSnapshot: ShakeFocusSnapshot?
    private var shakeFocusObserversInstalled = false
    
    /// 切换窗口显示状态
    func toggleWindows(for app: NSRunningApplication, source: WindowToggleSource = .dock) {
        guard let bundleId = app.bundleIdentifier else { return }

        let shouldUseDetachedFloatingGuard =
            source == .hotkey &&
            SideBarBridge.shared.requiresDetachedFloatingGuard(for: bundleId)

        let shouldProceed: Bool = transitionLockQueue.sync {
            guard shouldUseDetachedFloatingGuard else { return true }
            if appsInTransition.contains(bundleId) {
                return false
            }
            appsInTransition.insert(bundleId)
            return true
        }
        guard shouldProceed else { return }

        if shouldUseDetachedFloatingGuard {
            DispatchQueue.main.asyncAfter(deadline: .now() + detachedFloatingLockDuration) { [weak self] in
                _ = self?.transitionLockQueue.sync {
                    self?.appsInTransition.remove(bundleId)
                }
            }
        }

        let requestGeneration = nextHideRequestGeneration(for: bundleId)
        
        let wasHidden = app.isHidden
        let wasActive = app.isActive
        let wasFrontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleId
        let wasEffectivelyActive = wasActive || wasFrontmost

        // 1. 唤醒阶段 (Wake Up Phase)
        // 如果 App 是隐藏的 (Cmd+H) 或 后台的 (Not Active)
        // ⭐️ Finder 特殊处理（I1）：跳过 !wasActive 检查，因为 Finder 在只有桌面时可能报告 inactive
        let shouldWakeUp = wasHidden || (!FinderSpecialHandler.handles(bundleId) && !wasEffectivelyActive)
        
        if shouldWakeUp {
            // ⭐️ 统一唤醒逻辑：不再区分来源，全部使用手动恢复机制
            // 事实证明，手动 AX 恢复比系统原生的 app.activate 在处理复杂应用（如企业微信）时更稳定
            let windows = WindowThumbnailService.shared.getWindows(
                for: bundleId,
                respectDockExclusions: source.respectsDockExclusions
            )
            
            if wasHidden {
                app.unhide()
            }
            
            let actionableWindows = windows.filter { !CFEqual($0.axElement, $0.appAxElement) }
            if actionableWindows.isEmpty {
                reopenApplication(for: app)
            } else {
                restoreAllWindows(windows: actionableWindows, app: app)
            }
            return
        }
        
        // 2. 交互阶段 (Active App Click)
        // 只有 App 已经是前台活跃时，点击才是 "Toggle" 意图。
        
        // ⭐️ 极致性能优化：先获取窗口数量
        let windows = WindowThumbnailService.shared.getWindows(
            for: bundleId,
            respectDockExclusions: source.respectsDockExclusions
        )
        let windowCount = windows.count
        
        // 防止连击 (Debounce)，所有应用均需遵循（除 Finder 外）。
        // Finder 跳过此锁是为了实现极致丝滑（toggleWindows Finder 分支自带短锁 50ms）。
        if !FinderSpecialHandler.handles(bundleId) {
            guard !isTransitioning else { return }
        }
        
        isTransitioning = true
        
        // 0. 无窗口 (Finder/Safari 后台运行，或者窗口已关闭)
        if windowCount == 0 {
            reopenApplication(for: app)
            // 极限响应解锁 (50ms)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.isTransitioning = false
            }
            return
        }
        
        // ⭐️ Finder 特殊逻辑（Bug③ 修复 + 收口到 FinderSpecialHandler）
        // 以第一个窗口为「确定性锚点」决定切换方向：
        //   - 第一个被缩小 → 全部恢复（用 toggleAllRestore：串行 setMinimized=false + 80ms 后 SkyLight raise，
        //     避免 Finder 因 SkyLight 抢断而拒收后发的 setMinimized 写入，导致只恢复一个）
        //   - 第一个被展开 → 全部缩小（toggleAllMinimize：主线程串行）
        if FinderSpecialHandler.handles(bundleId) {
            let isFirstMinimized = windows.first?.isMinimized ?? true

            if isFirstMinimized {
                FinderSpecialHandler.toggleAllRestore(windows: windows, app: app, log: DebugLogger.shared)
                minimizedApps.remove(bundleId)
            } else {
                FinderSpecialHandler.toggleAllMinimize(windows: windows, log: DebugLogger.shared)
                minimizedApps.insert(bundleId)
            }

            // 极致响应 (50ms)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.isTransitioning = false
            }
            return
        }
        
        // 强制使用 "Hide" 模式 (其他应用)
        toggleHide(
            for: app,
            bundleId: bundleId,
            requestGeneration: requestGeneration
        )
        
        // 极致响应 (50ms)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.isTransitioning = false 
        }
    }
    
    /// 确保所有窗口可见 (由 DockEventMonitor 在应用切到前台时调用)
    func ensureWindowsVisible(for app: NSRunningApplication) {
        guard !isTransitioning, let bundleId = app.bundleIdentifier else { return }
        
        // ⭐️ 核心修复：唤醒时也必须增加版本号，彻底废掉上一次隐藏操作可能遗留的“延迟补刀”任务
        _ = nextHideRequestGeneration(for: bundleId)
        
        isTransitioning = true
        
        if app.isHidden {
            app.unhide()
        }
        
        // 优先使用已经过滤好的真实窗口列表，避免 Dock 点击时只拿到 App 前台、但没有真正把窗口拉起来。
        let windows = WindowThumbnailService.shared.getWindows(for: bundleId)
        if windows.isEmpty {
            // ⭐️ 核心修复：如果没有窗口，尝试 AX 恢复后如果还是没窗口，触发重开
            let pid = app.processIdentifier
            let appElement = AXUIElementCreateApplication(pid)
            restoreAllWindows(appElement: appElement, app: app)
            
            // 给 AX 恢复留一点时间，如果依然没有窗口，则触发重开
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                let currentWindows = WindowThumbnailService.shared.getWindows(for: bundleId)
                if currentWindows.isEmpty {
                    self?.reopenApplication(for: app)
                }
            }
        } else {
            restoreAllWindows(windows: windows, app: app)
        }
        minimizedApps.remove(bundleId)
        
        // ⭐️ 固定延时解锁：Finder 0.05s 以实现极致丝滑；其他应用 0.1s（防连点失效）。
        let delay = FinderSpecialHandler.handles(bundleId) ? 0.05 : 0.1
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.isTransitioning = false 
        }
    }
    
    /// 关闭特定窗口
    func closeWindow(_ window: WindowThumbnailService.WindowInfo) {
        if let closeBtn = window.closeButton {
            // 执行关闭动作
            AXUIElementPerformAction(closeBtn, kAXPressAction as CFString)
            
            // 发送通知，告知 UI 更新列表
            NotificationCenter.default.post(name: NSNotification.Name("WindowDidClose"), object: nil, userInfo: ["windowId": window.windowId])
        }
    }

    // MARK: - 摇窗聚焦：统一入口

    /// 由 `WindowShakeMonitor` 触发的统一入口。根据当前桌面状态自动决定走"聚焦"还是"恢复"分支：
    /// - 桌面**还有其它可见窗口** → 执行聚焦：把它们最小化掉，并覆盖快照
    /// - 桌面**没有其它可见窗口**，且开启了"再次摇晃恢复窗口"，且有有效快照 → 执行恢复
    /// - 否则不做任何事（聚焦时如果实际最小化数为 0，不会建立快照，避免下次摇晃误以为是"恢复"但啥都没做）
    func handleShakeGesture(for target: WindowFocusTarget) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                self?.handleShakeGesture(for: target)
            }
            return
        }

        installShakeFocusObserversIfNeeded()

        let otherVisible = collectVisibleWindowsForShake(except: target)
        let restoreEnabled = SettingsManager.shared.shakeToFocusRestoreEnabled

        if otherVisible.isEmpty, restoreEnabled, let snapshot = shakeFocusSnapshot {
            performShakeRestore(snapshot: snapshot, shakeTarget: target)
        } else {
            performShakeFocus(otherVisible: otherVisible)
        }
    }

    private func performShakeFocus(otherVisible: [VisibleWindowSnapshot]) {
        guard !isTransitioning else { return }
        isTransitioning = true

        guard !otherVisible.isEmpty else {
            // 桌面已经只剩它了，但没有快照可恢复 → 啥都不做，留意不要建空快照
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.isTransitioning = false
            }
            return
        }

        DebugLogger.shared.log("[ShakeToFocus] Focusing: minimizing \(otherVisible.count) other visible window(s)")

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }

            var successfullyMinimized: [ShakeFocusSnapshot.WindowRef] = []

            let groupedByPID = Dictionary(grouping: otherVisible, by: \.ownerPID)
            for (pid, snapshots) in groupedByPID {
                let axWindows = self.axWindowMap(for: pid)
                for snapshot in snapshots {
                    guard let axWindow = axWindows[snapshot.windowId] else { continue }
                    if self.minimizeAXWindowReporting(axWindow) {
                        successfullyMinimized.append(
                            ShakeFocusSnapshot.WindowRef(
                                windowId: snapshot.windowId,
                                ownerPID: snapshot.ownerPID,
                                bundleID: snapshot.bundleID
                            )
                        )
                    }
                }
            }

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                // 方案 A：每一次新的聚焦动作都**完全覆盖**旧快照。
                // 心智模型："摇晃 = 当前状态切换"，最简洁、最贴近用户预期。
                if !successfullyMinimized.isEmpty {
                    self.shakeFocusSnapshot = ShakeFocusSnapshot(minimizedWindows: successfullyMinimized)
                    DebugLogger.shared.log("[ShakeToFocus] Snapshot saved: \(successfullyMinimized.count) window(s)")
                } else {
                    // 实际啥都没最小化（全是已最小化 / AX 失败）→ 不建立快照
                    DebugLogger.shared.log("[ShakeToFocus] No window minimized, snapshot not created")
                }
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in
                self?.isTransitioning = false
            }
        }
    }

    private func performShakeRestore(snapshot: ShakeFocusSnapshot, shakeTarget: WindowFocusTarget) {
        guard !isTransitioning else { return }
        isTransitioning = true

        DebugLogger.shared.log("[ShakeToFocus] Restoring up to \(snapshot.minimizedWindows.count) window(s)")

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }

            var restoredCount = 0
            let groupedByPID = Dictionary(grouping: snapshot.minimizedWindows, by: \.ownerPID)
            for (pid, refs) in groupedByPID {
                guard let app = NSRunningApplication(processIdentifier: pid),
                      !app.isTerminated else {
                    continue
                }
                let axWindows = self.axWindowMap(for: pid)
                for ref in refs {
                    guard let axWindow = axWindows[ref.windowId] else { continue }
                    if self.restoreAXWindowIfMinimized(axWindow) {
                        restoredCount += 1
                    }
                }
            }

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.shakeFocusSnapshot = nil
                if restoredCount > 0 {
                    // 被恢复的窗口会抢前景：每次 AX unminimize 都会让对应 App 顶到前面，
                    // 最后一个被恢复的窗口往往就成了 frontmost，导致用户正按住摇晃的"持握窗口"
                    // 被压到底下、视觉上"脱离鼠标"。这里在恢复结束后强制把摇晃源窗口拉回最前。
                    self.bringShakeTargetToFront(shakeTarget)
                    // 0.08s 后再做一次兜底，覆盖恢复动画末段仍有 App 抢焦的极端情况
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
                        self?.bringShakeTargetToFront(shakeTarget)
                    }
                    ShakeFocusToast.show(count: restoredCount)
                    DebugLogger.shared.log("[ShakeToFocus] Restore completed: \(restoredCount) window(s)")
                } else {
                    DebugLogger.shared.log("[ShakeToFocus] Restore: nothing to restore (windows closed or already restored)")
                }
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in
                self?.isTransitioning = false
            }
        }
    }

    /// 把"用户正在摇晃的那个窗口"重新提到最前并获得键盘焦点。
    ///
    /// 摇窗恢复时多个被恢复窗口会争夺前景，AX unminimize 默认会顺带激活它们的所属 App，
    /// 导致用户鼠标按着的源窗口被压到下面。这里通过 App.activate + AX raise/main/focused +
    /// SLPS 私有 API 三件套，把源窗口稳稳放回最前。
    private func bringShakeTargetToFront(_ target: WindowFocusTarget) {
        guard let app = NSRunningApplication(processIdentifier: target.ownerPID),
              !app.isTerminated else {
            return
        }

        // 1) 让目标 App 重新成为前台进程
        app.activate(options: .activateIgnoringOtherApps)

        // 2) 在目标 App 内部把目标窗口 raise + 标记为 main/focused
        let axWindows = axWindowMap(for: target.ownerPID)
        if let win = axWindows[target.windowId] {
            _ = AXUIElementPerformAction(win, kAXRaiseAction as CFString)
            _ = AXUIElementSetAttributeValue(win, kAXMainAttribute as CFString, true as CFTypeRef)
            _ = AXUIElementSetAttributeValue(win, kAXFocusedAttribute as CFString, true as CFTypeRef)
        }

        // 3) 使用 SLPS 私有 API 把 windowId 锁定为前台窗口，覆盖刚 unminimize 抢焦的情况
        bringWindowAppToFront(pid: target.ownerPID, windowId: target.windowId)
    }

    // MARK: - 摇窗聚焦：快照生命周期

    private func installShakeFocusObserversIfNeeded() {
        guard !shakeFocusObserversInstalled else { return }
        shakeFocusObserversInstalled = true

        // App 退出：从快照里移除该 App 的窗口条目
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleShakeFocusAppTerminated(_:)),
            name: NSWorkspace.didTerminateApplicationNotification,
            object: nil
        )

        // 系统睡眠：状态语境已变，清空快照
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleShakeFocusSystemSleep),
            name: NSWorkspace.willSleepNotification,
            object: nil
        )

        // 父开关关闭：清空快照
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleShakeFocusParentSettingChanged),
            name: .shakeToFocusChanged,
            object: nil
        )

        // 子开关关闭：清空快照
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleShakeFocusRestoreSettingChanged),
            name: .shakeToFocusRestoreChanged,
            object: nil
        )
    }

    @objc private func handleShakeFocusAppTerminated(_ note: Notification) {
        guard var snapshot = shakeFocusSnapshot,
              let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
            return
        }
        let terminatedPid = app.processIdentifier
        let before = snapshot.minimizedWindows.count
        snapshot.minimizedWindows.removeAll { $0.ownerPID == terminatedPid }
        let after = snapshot.minimizedWindows.count
        if before == after { return }

        if snapshot.minimizedWindows.isEmpty {
            shakeFocusSnapshot = nil
            DebugLogger.shared.log("[ShakeToFocus] Snapshot cleared: all windows belonged to terminated app")
        } else {
            shakeFocusSnapshot = snapshot
            DebugLogger.shared.log("[ShakeToFocus] Snapshot pruned: removed \(before - after) window(s) from terminated app")
        }
    }

    @objc private func handleShakeFocusSystemSleep() {
        clearShakeFocusSnapshot(reason: "system sleep")
    }

    @objc private func handleShakeFocusParentSettingChanged() {
        if !SettingsManager.shared.shakeToFocusEnabled {
            clearShakeFocusSnapshot(reason: "Shake to Focus disabled")
        }
    }

    @objc private func handleShakeFocusRestoreSettingChanged() {
        if !SettingsManager.shared.shakeToFocusRestoreEnabled {
            clearShakeFocusSnapshot(reason: "Shake Again to Restore disabled")
        }
    }

    private func clearShakeFocusSnapshot(reason: String) {
        guard shakeFocusSnapshot != nil else { return }
        shakeFocusSnapshot = nil
        DebugLogger.shared.log("[ShakeToFocus] Snapshot cleared: \(reason)")
    }

    private func collectVisibleWindowsForShake(except preservedWindow: WindowFocusTarget) -> [VisibleWindowSnapshot] {
        guard let windowList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return []
        }

        let ownBundleID = Bundle.main.bundleIdentifier ?? "com.dockminimize.app"
        var snapshots: [VisibleWindowSnapshot] = []
        var seenWindowIDs = Set<CGWindowID>()

        for windowInfo in windowList {
            guard let windowId = Self.cgWindowID(from: windowInfo[kCGWindowNumber as String]),
                  windowId != preservedWindow.windowId,
                  !seenWindowIDs.contains(windowId),
                  let ownerPID = Self.pid(from: windowInfo[kCGWindowOwnerPID as String]),
                  ownerPID != getpid(),
                  let bounds = Self.cgRect(from: windowInfo[kCGWindowBounds as String]) else {
                continue
            }

            seenWindowIDs.insert(windowId)

            if bounds.width < 100 || bounds.height < 100 { continue }
            if let layer = Self.intValue(from: windowInfo[kCGWindowLayer as String]), layer != 0 { continue }
            if let alpha = Self.cgFloat(from: windowInfo[kCGWindowAlpha as String]), alpha < 0.1 { continue }
            if let sharingState = Self.intValue(from: windowInfo[kCGWindowSharingState as String]), sharingState == 0 { continue }

            guard let app = NSRunningApplication(processIdentifier: ownerPID),
                  !app.isTerminated,
                  let bundleID = app.bundleIdentifier else {
                continue
            }

            if bundleID == ownBundleID ||
               bundleID == "com.apple.dock" ||
               bundleID == "com.apple.systemuiserver" ||
               bundleID == "com.ivean.SideBar" {
                continue
            }

            if SettingsManager.shared.shouldSkipDockHandling(bundleID: bundleID) {
                continue
            }

            snapshots.append(
                VisibleWindowSnapshot(
                    windowId: windowId,
                    ownerPID: ownerPID,
                    bundleID: bundleID
                )
            )
        }

        return snapshots
    }

    private func axWindowMap(for pid: pid_t) -> [CGWindowID: AXUIElement] {
        let appElement = AXUIElementCreateApplication(pid)
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement] else {
            return [:]
        }

        var result: [CGWindowID: AXUIElement] = [:]
        for window in windows {
            var windowId: CGWindowID = 0
            guard _AXUIElementGetWindow(window, &windowId) == .success, windowId != 0 else {
                continue
            }

            result[windowId] = window
        }
        return result
    }

    /// 返回值：是否真的由本次调用执行了最小化（用于决定要不要把它写进快照）。
    /// - 已经是最小化的窗口 → 返回 false，不计入快照
    /// - AX 调用失败 → 返回 false，不计入快照
    @discardableResult
    private func minimizeAXWindowReporting(_ window: AXUIElement) -> Bool {
        var minimizedRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &minimizedRef) == .success,
           let isMinimized = minimizedRef as? Bool,
           isMinimized {
            return false
        }

        let err = AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, true as CFTypeRef)
        return err == .success
    }

    /// 只恢复那些当前仍处于"最小化"状态的窗口；用户期间已经手动恢复的就跳过。
    private func restoreAXWindowIfMinimized(_ window: AXUIElement) -> Bool {
        var minimizedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &minimizedRef) == .success,
              let isMinimized = minimizedRef as? Bool,
              isMinimized else {
            return false
        }
        let err = AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, false as CFTypeRef)
        return err == .success
    }

    // MARK: - 隐藏模式
    
    private func toggleHide(for app: NSRunningApplication, bundleId: String, requestGeneration: Int) {
        if app.isHidden {
            app.unhide()
            app.activate(options: .activateIgnoringOtherApps)
        } else {
            app.hide()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
                self?.ensureAppHiddenIfNeeded(
                    app: app,
                    bundleId: bundleId,
                    attempt: 0,
                    requestGeneration: requestGeneration
                )
            }
        }
    }

    private func ensureAppHiddenIfNeeded(
        app: NSRunningApplication,
        bundleId: String,
        attempt: Int,
        requestGeneration: Int
    ) {
        guard isCurrentHideRequestGeneration(requestGeneration, for: bundleId) else {
            return
        }

        let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleId
        let hasVisibleWindows = hasVisibleTopLevelWindows(for: app.processIdentifier)
        let stillVisible = frontmost || hasVisibleWindows

        guard stillVisible else { return }

        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        _ = AXUIElementSetAttributeValue(appElement, kAXHiddenAttribute as CFString, true as CFTypeRef)

        guard attempt < 3 else {
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in
            guard let self else { return }
            guard self.isCurrentHideRequestGeneration(requestGeneration, for: bundleId) else {
                return
            }
            let visibleWindowsAfterAXHide = self.hasVisibleTopLevelWindows(for: app.processIdentifier)
            let stillNeedsFallback =
                !app.isHidden ||
                NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleId ||
                visibleWindowsAfterAXHide
            guard stillNeedsFallback else { return }
            self.ensureAppHiddenIfNeeded(
                app: app,
                bundleId: bundleId,
                attempt: attempt + 1,
                requestGeneration: requestGeneration
            )
        }
    }

    private func hasVisibleTopLevelWindows(for pid: pid_t) -> Bool {
        guard let windowList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return false
        }

        for windowInfo in windowList {
            guard let ownerPID = windowInfo[kCGWindowOwnerPID as String] as? pid_t,
                  ownerPID == pid else {
                continue
            }

            if let layer = windowInfo[kCGWindowLayer as String] as? Int, layer != 0 {
                continue
            }

            let alpha = windowInfo[kCGWindowAlpha as String] as? CGFloat ?? 1.0
            if alpha < 0.05 {
                continue
            }

            guard let boundsDict = windowInfo[kCGWindowBounds as String] as? [String: CGFloat],
                  let width = boundsDict["Width"],
                  let height = boundsDict["Height"] else {
                continue
            }

            if width < 40 || height < 40 {
                continue
            }

            return true
        }

        return false
    }
    
    // MARK: - 恢复逻辑
    
    /// 恢复所有真实窗口
    private func restoreAllWindows(windows: [WindowThumbnailService.WindowInfo], app: NSRunningApplication) {
        if app.isHidden {
            app.unhide()
        }
        
        // 先把进程提到前台，再逐个恢复窗口。
        app.activate(options: .activateIgnoringOtherApps)
        
        let primaryWindow = windows.first(where: { !isWindowMinimized($0.axElement) }) ?? windows.first
        if let primaryWindow {
            bringWindowAppToFront(pid: app.processIdentifier, windowId: primaryWindow.windowId)
        }
        
        // 后台异步执行 AX 指令，防止阻塞主线程
        DispatchQueue.global(qos: .userInteractive).async {
            for window in windows {
                if self.isWindowMinimized(window.axElement) {
                    _ = AXUIElementSetAttributeValue(window.axElement, kAXMinimizedAttribute as CFString, false as CFTypeRef)
                }
                _ = AXUIElementPerformAction(window.axElement, kAXRaiseAction as CFString)
                if window.windowId == primaryWindow?.windowId {
                    _ = AXUIElementSetAttributeValue(window.axElement, kAXMainAttribute as CFString, true as CFTypeRef)
                    _ = AXUIElementSetAttributeValue(window.axElement, kAXFocusedAttribute as CFString, true as CFTypeRef)
                }
            }
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            app.activate(options: .activateIgnoringOtherApps)
            if let primaryWindow {
                self.bringWindowAppToFront(pid: app.processIdentifier, windowId: primaryWindow.windowId)
            }
        }
    }
    
    /// 兜底方法：恢复该应用的所有窗口（带基础过滤，用于未知状态）
    private func restoreAllWindows(appElement: AXUIElement, app: NSRunningApplication) {
        if app.isHidden {
            app.unhide()
        }
        app.activate(options: .activateIgnoringOtherApps)
        
        var windowsRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef) == .success,
           let windows = windowsRef as? [AXUIElement] {
            
            for window in windows {
                // 这里加一层最基本的过滤：必须有标题
                var titleRef: CFTypeRef?
                AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleRef)
                let title = titleRef as? String ?? ""
                
                if !title.isEmpty {
                    if isWindowMinimized(window) {
                        AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, false as CFTypeRef)
                    }
                    AXUIElementPerformAction(window, kAXRaiseAction as CFString)
                }
            }
        }
    }
    
    /// 检查窗口是否已最小化
    private func isWindowMinimized(_ window: AXUIElement) -> Bool {
        var minimizedRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &minimizedRef) == .success,
           let minimized = minimizedRef as? Bool {
            return minimized
        }
        return false
    }
    
    private func bringWindowAppToFront(pid: pid_t, windowId: CGWindowID) {
        var psn = ProcessSerialNumber()
        guard GetProcessForPID(pid, &psn) == noErr else { return }
        
        _ = _SLPSSetFrontProcessWithOptions(&psn, windowId, SLPSMode.userGenerated.rawValue)
        makeKeyWindow(&psn, windowID: windowId)
    }

    private func nextHideRequestGeneration(for bundleId: String) -> Int {
        let next = (hideRequestGeneration[bundleId] ?? 0) + 1
        hideRequestGeneration[bundleId] = next
        return next
    }

    private func isCurrentHideRequestGeneration(_ generation: Int, for bundleId: String) -> Bool {
        hideRequestGeneration[bundleId] == generation
    }

    private static func cgWindowID(from value: Any?) -> CGWindowID? {
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

    private static func pid(from value: Any?) -> pid_t? {
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

    private static func intValue(from value: Any?) -> Int? {
        if let value = value as? Int {
            return value
        }
        if let value = value as? NSNumber {
            return value.intValue
        }
        return nil
    }

    private static func cgFloat(from value: Any?) -> CGFloat? {
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

    private static func cgRect(from value: Any?) -> CGRect? {
        guard let dict = value as? [String: Any],
              let x = cgFloat(from: dict["X"]),
              let y = cgFloat(from: dict["Y"]),
              let width = cgFloat(from: dict["Width"]),
              let height = cgFloat(from: dict["Height"]) else {
            return nil
        }

        return CGRect(x: x, y: y, width: width, height: height)
    }
    
    
    /// 触发应用的重开（Reopen）逻辑
    /// 这等同于点击 Dock 图标的行为，会触发 applicationShouldHandleReopen:hasVisibleWindows:
    private func reopenApplication(for app: NSRunningApplication) {
        guard let url = app.bundleURL else {
            app.activate(options: .activateIgnoringOtherApps)
            return
        }
        
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        config.addsToRecentItems = false
        
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, error in
            if let error = error {
                DebugLogger.shared.log("⚠️ [WindowManager] Failed to reopen app \(app.bundleIdentifier ?? "unknown"): \(error)")
                // Fallback to basic activation
                DispatchQueue.main.async {
                    app.activate(options: .activateIgnoringOtherApps)
                }
            }
        }
    }
}

// MARK: - ShakeFocusToast
/// 「再次摇晃恢复窗口」触发时显示的轻量浮窗。
///
/// 视觉与定位都对齐 `DockOwnershipTipController`「检测到复杂窗口环境」提示：
/// - 位置：底部 Dock 上方居中；左/右 Dock 贴 Dock 内侧
/// - 样式：HUD 材质 + 蓝色描边 + 蓝色阴影 + 圆角
/// - 1.4 秒后自动淡出，连续触发会复用同一面板
final class ShakeFocusToast {
    static let shared = ShakeFocusToast()

    private let panelWidth: CGFloat = 300
    private let panelHeight: CGFloat = 60

    private var panel: NSPanel?
    private var dismissWorkItem: DispatchWorkItem?
    /// 每次 present 自增的令牌，用于让旧 dismiss 的动画完成回调识别自己是否过期。
    /// 避免「panel 复用 + 旧淡出回调 orderOut」把新一次的 toast 误隐藏。
    private var presentationToken: UInt64 = 0

    private init() {}

    static func show(count: Int) {
        DispatchQueue.main.async {
            shared.present(count: count)
        }
    }

    private func present(count: Int) {
        dismissWorkItem?.cancel()
        presentationToken &+= 1
        let token = presentationToken

        let message = SettingsManager.shared.t(
            "已恢复 \(count) 个窗口",
            count == 1 ? "Restored 1 window" : "Restored \(count) windows"
        )

        ensurePanel()
        guard let panel = self.panel else { return }
        panel.contentView = NSHostingView(rootView: ShakeFocusToastView(message: message))
        updatePanelPosition(panel)

        panel.alphaValue = 0
        panel.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.18
            panel.animator().alphaValue = 1
        })

        let dismiss = DispatchWorkItem { [weak self] in
            guard let self,
                  self.presentationToken == token,
                  let win = self.panel else { return }
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.22
                win.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                guard let self,
                      self.presentationToken == token else { return }
                // 复用 panel：仅在没有更新的 present 发生时才隐藏
                win.orderOut(nil)
            })
        }
        dismissWorkItem = dismiss
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4, execute: dismiss)
    }

    private func ensurePanel() {
        guard panel == nil else { return }

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.ignoresMouseEvents = true
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isReleasedWhenClosed = false
        panel.alphaValue = 0
        panel.becomesKeyOnlyIfNeeded = true

        self.panel = panel
    }

    private func updatePanelPosition(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }

        let dockPosition = DockPositionManager.shared.currentPosition
        let dockThickness = max(DockPositionManager.shared.realDockThickness, 24)
        let horizontalPadding: CGFloat = 20
        let verticalPadding: CGFloat = 18

        let origin: CGPoint
        switch dockPosition {
        case .bottom:
            origin = CGPoint(
                x: screen.frame.midX - panelWidth / 2,
                y: screen.frame.minY + dockThickness + verticalPadding
            )
        case .left:
            origin = CGPoint(
                x: screen.frame.minX + dockThickness + horizontalPadding,
                y: screen.frame.maxY - panelHeight - 56
            )
        case .right:
            origin = CGPoint(
                x: screen.frame.maxX - dockThickness - panelWidth - horizontalPadding,
                y: screen.frame.maxY - panelHeight - 56
            )
        }

        panel.setFrame(NSRect(origin: origin, size: NSSize(width: panelWidth, height: panelHeight)),
                       display: false)
    }
}

private struct ShakeFocusToastView: View {
    let message: String

    var body: some View {
        ZStack {
            VisualEffectView(material: .hudWindow, blendingMode: .behindWindow)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color.blue.opacity(0.85), lineWidth: 1.4)
                }

            HStack(spacing: 10) {
                Image(systemName: "arrow.uturn.backward.circle.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Color.blue)

                Text(message)
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .frame(width: 300, height: 60)
        .shadow(color: Color.blue.opacity(0.18), radius: 16, x: 0, y: 8)
    }
}
