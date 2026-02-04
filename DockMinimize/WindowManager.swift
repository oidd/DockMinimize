//
//  WindowManager.swift
//  DockMinimize
//
//  Created by Dock Minimize
//

import Cocoa
import ApplicationServices

class WindowManager {
    static let shared = WindowManager()
    
    /// 存储已最小化的应用
    private var minimizedApps: Set<String> = []
    
    /// 递归检查是否正在进行窗口操作，防止连击导致的竞态和崩溃
    var isTransitioning: Bool = false
    
    /// 切换窗口显示状态
    func toggleWindows(for app: NSRunningApplication) {
        guard let bundleId = app.bundleIdentifier else { return }
        
        let wasHidden = app.isHidden
        let wasActive = app.isActive
        
        // 1. 唤醒阶段 (Wake Up Phase)
        // 如果 App 是隐藏的 (Cmd+H) 或 后台的 (Not Active)
        // ⭐️ Finder 特殊处理：跳过 !wasActive 检查，因为 Finder 在只有桌面时可能报告 inactive
        let shouldWakeUp = wasHidden || (bundleId != "com.apple.finder" && !wasActive)
        
        if shouldWakeUp {
            // 直接由系统接管。
            if wasHidden {
                app.unhide()
            }
            app.activate(options: .activateIgnoringOtherApps)
            // 早期返回，不执行任何自定义 Restore 逻辑，完全信任系统。
            return
        }
        
        // 2. 交互阶段 (Active App Click)
        // 只有 App 已经是前台活跃时，点击才是 "Toggle" 意图。
        
        // ⭐️ 极致性能优化：先获取窗口数量
        let windows = WindowThumbnailService.shared.getWindows(for: bundleId)
        let windowCount = windows.count
        
        // 防止连击 (Debounce)，但单窗口允许极速响应
        if windowCount > 1 && bundleId != "com.apple.finder" {
            guard !isTransitioning else { return }
        }
        
        isTransitioning = true
        
        // 0. 无窗口 (Finder/Safari 后台运行)
        if windowCount == 0 {
            if let url = app.bundleURL {
                let config = NSWorkspace.OpenConfiguration()
                config.activates = true
                NSWorkspace.shared.openApplication(at: url, configuration: config, completionHandler: nil)
            } else {
                app.activate(options: .activateIgnoringOtherApps)
            }
            // 立即解除锁定，因为没有动画
            isTransitioning = false
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

            // 极速解锁
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.isTransitioning = false 
            }
            return
        }
        
        // 强制使用 "Hide" 模式 (其他应用)
        toggleHide(for: app, bundleId: bundleId)
        
        // 极速解锁
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.isTransitioning = false 
        }
    }
    
    /// 确保所有窗口可见 (由 DockEventMonitor 在应用切到前台时调用)
    func ensureWindowsVisible(for app: NSRunningApplication) {
        guard !isTransitioning, let bundleId = app.bundleIdentifier else { return }
        
        isTransitioning = true
        
        // 还原所有窗口
        let pid = app.processIdentifier
        let appElement = AXUIElementCreateApplication(pid)
        restoreAllWindows(appElement: appElement, app: app)
        minimizedApps.remove(bundleId)
        
        // ⭐️ 固定延时解锁：Finder 缩短为 0.1s 以实现极致丝滑，其他应用维持 0.5s
        let delay = (bundleId == "com.apple.finder") ? 0.1 : 0.5
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
    
    private func toggleHide(for app: NSRunningApplication, bundleId: String) {
        if app.isHidden {
            app.unhide()
            app.activate(options: .activateIgnoringOtherApps)
        } else {
            app.hide()
        }
    }
    
    // MARK: - 恢复逻辑
    
    /// 恢复所有真实窗口
    private func restoreAllWindows(windows: [WindowThumbnailService.WindowInfo], app: NSRunningApplication) {
        // 首先强制激活应用
        app.activate(options: .activateIgnoringOtherApps)
        
        // 后台异步执行 AX 指令，防止阻塞主线程
        DispatchQueue.global(qos: .userInteractive).async {
            for window in windows {
                if window.isMinimized {
                    _ = AXUIElementSetAttributeValue(window.axElement, kAXMinimizedAttribute as CFString, false as CFTypeRef)
                }
                _ = AXUIElementPerformAction(window.axElement, kAXRaiseAction as CFString)
            }
        }
    }
    
    /// 兜底方法：恢复该应用的所有窗口（带基础过滤，用于未知状态）
    private func restoreAllWindows(appElement: AXUIElement, app: NSRunningApplication) {
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
    
    // MARK: - 状态监测 (Removed: Polling unstable with Finder/System apps)
}
