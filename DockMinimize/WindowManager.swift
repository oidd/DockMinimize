//
//  WindowManager.swift
//  DockMinimize
//
//  Created by Dock Minimize
//

import Cocoa
import ApplicationServices

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

class WindowManager {
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
        // ⭐️ Finder 特殊处理：跳过 !wasActive 检查，因为 Finder 在只有桌面时可能报告 inactive
        let shouldWakeUp = wasHidden || (bundleId != "com.apple.finder" && !wasEffectivelyActive)
        
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
        let windowCount = windows.count
        
        // 防止连击 (Debounce)，所有应用均需遵循（除 Finder 外）
        if bundleId != "com.apple.finder" {
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
        
        // Finder 特殊逻辑：使用第一个窗口作为“确定性锚点”进行切换
        if bundleId == "com.apple.finder" {
            // ⭐️ 核心改进：不再使用 allSatisfy，而是直接以第一个窗口的状态作为基准。
            // 这样能保证每次点击都有明确的切换方向，且与指示条同步。
            let isFirstMinimized = windows.first?.isMinimized ?? true

            if isFirstMinimized {
                // 如果第一个是缩小的 -> 全部恢复
                restoreAllWindows(windows: windows, app: app)
                minimizedApps.remove(bundleId)
            } else {
                // 如果第一个是展开的 -> 全部缩小
                DispatchQueue.global(qos: .userInteractive).async {
                    for window in windows {
                        if !window.isMinimized {
                            _ = AXUIElementSetAttributeValue(window.axElement, kAXMinimizedAttribute as CFString, true as CFTypeRef)
                        }
                    }
                }
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
        
        // ⭐️ 固定延时解锁：Finder 缩短为 0.1s 以实现极致丝滑，其他应用维持 0.5s
        // 固定延时解锁：Finder 0.05s，其他应用 0.1s (显著缩短以防止连点失效)
        let delay = (bundleId == "com.apple.finder") ? 0.05 : 0.1
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
