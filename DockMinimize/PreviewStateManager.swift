//
//  PreviewStateManager.swift
//  DockMinimize
//
//  预览条交互状态机
//

import Cocoa

/// 预览状态
enum PreviewState: Equatable {
    case hidden                           // 预览条隐藏
    case showing(appBundleId: String)     // 预览条显示中
    case peeking(windowId: CGWindowID)    // 正在透视某个窗口
    
    static func == (lhs: PreviewState, rhs: PreviewState) -> Bool {
        switch (lhs, rhs) {
        case (.hidden, .hidden):
            return true
        case (.showing(let a), .showing(let b)):
            return a == b
        case (.peeking(let a), .peeking(let b)):
            return a == b
        default:
            return false
        }
    }
}

protocol PreviewStateManagerDelegate: AnyObject {
    /// 状态变化时调用
    func previewStateManager(_ manager: PreviewStateManager, didChangeState state: PreviewState)
    
    /// 请求显示预览条
    func previewStateManager(_ manager: PreviewStateManager, showPreviewFor bundleId: String, at position: CGPoint)
    
    /// 请求隐藏预览条
    func previewStateManager(_ manager: PreviewStateManager, hidePreview: Bool)
    
    /// 请求透视窗口（临时置顶）
    func previewStateManager(_ manager: PreviewStateManager, peekWindow windowId: CGWindowID)
    
    /// 请求取消透视
    func previewStateManager(_ manager: PreviewStateManager, unpeekWindow: Bool)
    
    /// 请求无缝退出（淡出动画）
    func previewStateManager(_ manager: PreviewStateManager, performSeamlessExit: Bool)
}

class PreviewStateManager {
    weak var delegate: PreviewStateManagerDelegate?
    
    private let log = DebugLogger.shared
    
    /// 当前状态
    private(set) var currentState: PreviewState = .hidden {
        didSet {
            if currentState != oldValue {
                log.log("📊 Preview state changed: \(oldValue) -> \(currentState)")
                delegate?.previewStateManager(self, didChangeState: currentState)
            }
        }
    }
    
    /// 当前显示的应用
    private(set) var currentAppBundleId: String?
    
    /// 当前激活的窗口（有蓝色边框）
    private(set) var activeWindowIds: Set<CGWindowID> = []
    
    /// 重置活跃窗口列表（当重新扫描到最新窗口状态时调用）
    func resetActiveWindows(_ ids: Set<CGWindowID>) {
        self.activeWindowIds = ids
    }
    
    /// 是否正在滚动
    var isScrolling: Bool = false {
        didSet {
            if isScrolling {
                // 滚动开始，取消悬停计时
                cancelPeekTimer()
            }
        }
    }
    
    /// 悬停计时器（用于透视防抖）
    private var peekTimer: DispatchWorkItem?
    
    /// 透视触发延迟（秒）
    private let peekDelay: TimeInterval = 0.1
    
    /// 最后一次由我们执行激活操作的窗口（持久保存直到隐藏）
    private var lastActivatedWindowId: CGWindowID?
    /// 最后一次通过系统查询到的焦点窗口 (在预览条显示时同步)
    private var lastFocusedWindowId: CGWindowID?
    
    /// 主动同步指定应用的焦点状态
    func syncFocusState(for bundleId: String) {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first else { return }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        
        var focusedWindow: AnyObject?
        let result = AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &focusedWindow)
        
        if result == .success, let focusedElement = focusedWindow {
            var focusedWindowId: CGWindowID = 0
            if _AXUIElementGetWindow(focusedElement as! AXUIElement, &focusedWindowId) == .success {
                self.lastFocusedWindowId = focusedWindowId
                log.log("🎯 Synced focus state: Window \(focusedWindowId) is frontmost for \(bundleId)")
            }
        }
    }
    
    /// 被透视的窗口所属应用（用于恢复焦点）
    private var peekedWindowApp: NSRunningApplication?
    
    /// 透视前的活跃应用
    private var previousActiveApp: NSRunningApplication?
    
    // MARK: - Public Methods
    
    /// 显示预览条
    func showPreview(for bundleId: String, at position: CGPoint) {
        // 如果切换了应用，清空置顶记忆
        if currentAppBundleId != bundleId {
            lastActivatedWindowId = nil
            lastFocusedWindowId = nil
        }
        
        currentAppBundleId = bundleId
        currentState = .showing(appBundleId: bundleId)
        
        // ⭐️ 显示前同步一次真实焦点
        syncFocusState(for: bundleId)
        
        delegate?.previewStateManager(self, showPreviewFor: bundleId, at: position)
    }
    
    /// 隐藏预览条
    func hidePreview() {
        cancelPeekTimer()
        
        // 如果正在透视，先取消透视
        if case .peeking = currentState {
            cancelPeek()
        }
        
        currentAppBundleId = nil
        currentState = .hidden
        
        // ⚠️ 不再在隐藏时立即清空内存，允许用户移开鼠标再回来点击依然生效
        // 只有在切换 Bundle ID 时才清空（在 showPreview 中处理）
        
        delegate?.previewStateManager(self, hidePreview: true)
    }
    
    /// 鼠标悬停在缩略图上
    func hoverOnThumbnail(windowId: CGWindowID) {
        // 如果正在滚动，不触发透视
        guard !isScrolling else { return }
        
        // 如果已经在透视同一个窗口，不需要重新计时
        if case .peeking(let currentWindowId) = currentState, currentWindowId == windowId {
            return
        }
        
        // 取消之前的计时器
        cancelPeekTimer()
        
        // 开始新的透视计时
        startPeekTimer(for: windowId)
    }
    
    /// 鼠标离开缩略图
    func exitThumbnail() {
        cancelPeekTimer()
        
        // 如果正在透视，取消透视
        if case .peeking = currentState {
            cancelPeek()
            
            // 回到 showing 状态
            if let bundleId = currentAppBundleId {
                currentState = .showing(appBundleId: bundleId)
            }
        }
    }
    
    /// 点击缩略图（使用 WindowInfo 中保存的 axElement 直接操作）
    /// 点击缩略图（使用 WindowInfo 中保存的 axElement 直接操作）
    /// - Returns: Bool, true if minimized, false if activated
    @discardableResult
    func clickThumbnail(windowInfo: WindowThumbnailService.WindowInfo) -> Bool {
        let windowId = windowInfo.windowId
        log.log("👆 Clicked thumbnail for window \(windowId)")
        
        // 取消透视计时
        cancelPeekTimer()
        
        // 如果正在透视，先取消透视
        if case .peeking = currentState {
            cancelPeek()
        }
        
        // ⭐️ 核心功能：点击展开/收回
        // 逻辑：只要 App 在前台，且窗口是我们认为的“最前窗口”，就执行最小化。
        
        var shouldMinimize = false
        
        // --- 判定前台状态 (放宽判定条件) ---
        // 只要前台是：目标 App、或者是 Dock、或者是我自己，就认为可以执行焦点检查
        let frontBundleId = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let isTargetApp = frontBundleId == currentAppBundleId
        let isDock = frontBundleId == "com.apple.dock"
        let isSelf = frontBundleId == Bundle.main.bundleIdentifier
        
        if isTargetApp || isDock || isSelf {
            
            // --- 智能多路状态判定 (不依赖定时器) ---
            
            // 轨道 1：内存置顶记录 (最强信任)
            // 只要我们刚才点过它，且中途没换过 App，无论等多久，它必然在最前面
            if lastActivatedWindowId == windowId {
                shouldMinimize = true
                log.log("✅ Match: Memory persist (last activated). Action: Minimize.")
            } 
            // 轨道 2：系统查询记录
            else if lastFocusedWindowId == windowId {
                shouldMinimize = true
                log.log("✅ Match: AX focus sync. Action: Minimize.")
            }
            // 轨道 3：实时补位检测 (应对用户手动点击窗口的情况)
            else {
                var focusedWindow: AnyObject?
                if AXUIElementCopyAttributeValue(windowInfo.appAxElement, kAXFocusedWindowAttribute as CFString, &focusedWindow) == .success,
                   let focusedElement = focusedWindow {
                    var focusedId: CGWindowID = 0
                    if _AXUIElementGetWindow(focusedElement as! AXUIElement, &focusedId) == .success && focusedId == windowId {
                        shouldMinimize = true
                        log.log("✅ Match: Real-time AX sync. Action: Minimize.")
                    }
                }
                
                if !shouldMinimize {
                    var isMain: CFTypeRef?
                    if AXUIElementCopyAttributeValue(windowInfo.axElement, kAXMainAttribute as CFString, &isMain) == .success,
                       let mainValue = isMain as? Bool, mainValue == true {
                        shouldMinimize = true
                        log.log("✅ Match: Window MainAttribute. Action: Minimize.")
                    }
                }
            }
        } else {
            log.log("📱 App not front (Current: \(frontBundleId ?? "none")). Action: Activate.")
        }
        
        // ⭐️ 修复 "隐藏下的死循环" (Click Deadlock Fix)
        // 用户反馈：第一次点击显示成功，第二次点击隐藏成功，第三次点击（想显示）时，
        // 由于 macOS 即使在 App 隐藏时也会保留 MainAttribute=true，导致上面判定为 shouldMinimize=true。
        // 结果：对一个 Hidden 的 App 执行 Minimize (即 Hide)，导致没反应。
        // 修复：显式检查 App.isHidden。如果是隐藏的，强制 shouldMinimize=false (执行显示)。
        if let app = NSRunningApplication(processIdentifier: windowInfo.ownerPID), app.isHidden {
            shouldMinimize = false
            log.log("🛑 App is hidden, forcing Activate (Overriding Minimize logic).")
        }
        
        if shouldMinimize {
            // 窗口已在最前，收回它
            minimizeWindow(windowInfo: windowInfo)
            activeWindowIds.remove(windowId)
            
            // 清除状态
            lastActivatedWindowId = nil
            lastFocusedWindowId = nil
            
            log.log("📉 Minimized window \(windowId)")
            
            // 保持在 showing 状态
            if let bundleId = currentAppBundleId {
                currentState = .showing(appBundleId: bundleId)
            }
            return true
        } else {
            // 窗口未在最前，展开它
            
            // 记录下这个窗口 ID，下次它在最前时点击它就执行最小化
            lastActivatedWindowId = windowId
            
            // 立即激活窗口 (先上车)
            self.activateWindow(windowInfo: windowInfo)
            self.activeWindowIds.insert(windowId) // 标记为活跃
            self.log.log("📈 Activated window \(windowId)")
            
            // 执行无缝退出动画 (后撤梯)
            // 不立即关闭大图，而是让它淡出，遮盖住窗口弹出的瞬间
            delegate?.previewStateManager(self, performSeamlessExit: true)
            
            // 保持在 showing 状态
            if let bundleId = currentAppBundleId {
                currentState = .showing(appBundleId: bundleId)
            }
            return false
        }
    }
    
    /// 兼容旧方法签名（向后兼容）
    func clickThumbnail(windowId: CGWindowID, app: NSRunningApplication) {
        log.log("⚠️ Using legacy clickThumbnail method for window \(windowId)")
        
        // 取消透视计时
        cancelPeekTimer()
        
        // 如果正在透视，先取消透视
        if case .peeking = currentState {
            cancelPeek()
        }
        
        // 切换窗口激活状态
        if activeWindowIds.contains(windowId) {
            // 窗口已激活，最小化它
            legacyMinimizeWindow(windowId: windowId, app: app)
            activeWindowIds.remove(windowId)
            log.log("📉 Minimized window \(windowId)")
        } else {
            // 窗口未激活，激活它
            legacyActivateWindow(windowId: windowId, app: app)
            activeWindowIds.insert(windowId)
            log.log("📈 Activated window \(windowId)")
        }
        
        // 保持在 showing 状态，不关闭预览条
        if let bundleId = currentAppBundleId {
            currentState = .showing(appBundleId: bundleId)
        }
    }
    
    /// 检查窗口是否已激活
    func isWindowActive(_ windowId: CGWindowID) -> Bool {
        return activeWindowIds.contains(windowId)
    }
    
    /// 滚动开始
    func scrollBegan() {
        isScrolling = true
    }
    
    /// 滚动结束
    func scrollEnded() {
        isScrolling = false
    }
    
    // MARK: - Private Methods
    
    /// 开始透视计时
    private func startPeekTimer(for windowId: CGWindowID) {
        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self, !self.isScrolling else { return }
            
            self.startPeek(windowId: windowId)
        }
        
        peekTimer = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + peekDelay, execute: workItem)
    }
    
    /// 取消透视计时
    private func cancelPeekTimer() {
        peekTimer?.cancel()
        peekTimer = nil
    }
    
    /// 开始透视
    private func startPeek(windowId: CGWindowID) {
        log.log("👁️ Starting peek for window \(windowId)")
        
        // 记录当前活跃应用（用于后续恢复焦点）
        previousActiveApp = NSWorkspace.shared.frontmostApplication
        
        currentState = .peeking(windowId: windowId)
        
        delegate?.previewStateManager(self, peekWindow: windowId)
        
        // 透视窗口：临时置顶但不抢焦点
        peekWindow(windowId: windowId)
    }
    
    /// 取消透视
    private func cancelPeek() {
        log.log("👁️ Cancelling peek")
        
        delegate?.previewStateManager(self, unpeekWindow: true)
        
        // 恢复之前的焦点
        if let previousApp = previousActiveApp {
            previousApp.activate(options: [])
        }
        
        previousActiveApp = nil
    }
    
    /// 透视窗口（临时置顶但不抢焦点）
    private func peekWindow(windowId: CGWindowID) {
        // 获取窗口所属的应用
        guard let windowList = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] else {
            return
        }
        
        for windowInfo in windowList {
            if let wid = windowInfo[kCGWindowNumber as String] as? CGWindowID, wid == windowId,
               let pid = windowInfo[kCGWindowOwnerPID as String] as? pid_t {
                
                let appElement = AXUIElementCreateApplication(pid)
                
                var windowsRef: CFTypeRef?
                guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef) == .success,
                      let windows = windowsRef as? [AXUIElement] else {
                    return
                }
                
                // ⭐️ 移除 Raise 操作，改为只准备大图预览状态
                // 之前这里会直接 raise 窗口，导致用户体验不佳
                // 现在我们只是确认窗口存在，真正的预览逻辑交给 UI 层的大图显示
                for window in windows {
                    var axWindowId: CGWindowID = 0
                    if _AXUIElementGetWindow(window, &axWindowId) == .success,
                       axWindowId == windowId {
                        // 找到窗口了，可以在这里做一些准备工作，比如预加载高清图
                        // 但绝对不要 Raise
                        log.log("👁️ Peek validated window \(windowId), ready for large preview")
                        break
                    }
                }
                
                // 立即将焦点还给之前的应用
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                    self?.previousActiveApp?.activate(options: [])
                }
                
                return
            }
        }
    }
    // MARK: - 窗口操作（新版本：使用 WindowInfo 中的 axElement）
    
    /// 激活窗口（展开）- 使用保存的 axElement 直接操作
    private func activateWindow(windowInfo: WindowThumbnailService.WindowInfo) {
        let windowId = windowInfo.windowId
        
        // 1. 基础唤醒：无论什么情况，先尝试解除隐藏和激活应用
        // 这对于 "Hide" 模式的应用是必须的，同时对普通应用也没有副作用
        if let app = NSRunningApplication(processIdentifier: windowInfo.ownerPID) {
            app.unhide()
            app.activate(options: .activateIgnoringOtherApps)
        }
        
        // 2. 移除之前的“单窗口早期返回”优化
        // 原因：如果状态判断失误（例如窗口实际是最小化的，但我们只做了 Unhide），就会导致点击无反应。
        // 现在采取“全套服务”策略：先 Unhide/Activate，然后继续执行下面的 AX 操作确保万无一失。
        // 由于我们有 isMinimized 检查，所以不会对非最小化窗口产生多余动画。

        let axElement = windowInfo.axElement
        
        // 1. 获取进程序列号
        var psn = ProcessSerialNumber()
        let psnResult = GetProcessForPID(windowInfo.ownerPID, &psn)
        
        if psnResult == noErr {
            // 2. 使用 SkyLight API 设置前台进程（针对特定窗口）
            _ = _SLPSSetFrontProcessWithOptions(&psn, windowId, SLPSMode.userGenerated.rawValue)
            
            // 3. 发送事件使其成为 key window
            makeKeyWindow(&psn, windowID: windowId)
        }
        
        // 4. 取消最小化
        if windowInfo.isMinimized {
            AXUIElementSetAttributeValue(axElement, kAXMinimizedAttribute as CFString, false as CFTypeRef)
        }
        
        // 5. Raise 窗口
        AXUIElementPerformAction(axElement, kAXRaiseAction as CFString)
        
        // 6. 设为主窗口
        AXUIElementSetAttributeValue(axElement, kAXMainAttribute as CFString, true as CFTypeRef)
        
        // 7. 激活应用
        if let app = NSRunningApplication(processIdentifier: windowInfo.ownerPID) {
            app.activate(options: .activateIgnoringOtherApps)
        }
        
        log.log("✅ Activated window \(windowId) using axElement")
    }
    
    /// 最小化窗口（收回）- 使用保存的 axElement 直接操作
    private func minimizeWindow(windowInfo: WindowThumbnailService.WindowInfo) {
        let windowId = windowInfo.windowId
        
        // ⭐️ 单窗口优化模式：直接 Hide App
        let allWindows = WindowThumbnailService.shared.getWindows(for: currentAppBundleId ?? "")
        if allWindows.count <= 1 {
             if let app = NSRunningApplication(processIdentifier: windowInfo.ownerPID) {
                app.hide()
                log.log("✅ Hidden app (Single Window Mode) for window \(windowId)")
                return
            }
        }

        let axElement = windowInfo.axElement
        
        // 直接使用保存的 axElement 设置最小化
        AXUIElementSetAttributeValue(axElement, kAXMinimizedAttribute as CFString, true as CFTypeRef)
        
        log.log("✅ Minimized window \(windowId) using axElement")
    }
    
    // MARK: - 窗口操作（旧版本：遍历查找）
    
    /// 激活窗口（旧版备选）
    private func legacyActivateWindow(windowId: CGWindowID, app: NSRunningApplication) {
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement] else {
            return
        }
        
        // ⭐️ 只操作匹配 windowId 的窗口
        for window in windows {
            var axWindowId: CGWindowID = 0
            if _AXUIElementGetWindow(window, &axWindowId) == .success,
               axWindowId == windowId {
                // 取消最小化
                AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, false as CFTypeRef)
                // Raise 窗口
                AXUIElementPerformAction(window, kAXRaiseAction as CFString)
                break
            }
        }
        
        // 激活应用
        app.activate(options: .activateIgnoringOtherApps)
    }
    
    /// 最小化窗口（旧版备选）
    private func legacyMinimizeWindow(windowId: CGWindowID, app: NSRunningApplication) {
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement] else {
            return
        }
        
        // ⭐️ 只操作匹配 windowId 的窗口
        for window in windows {
            var axWindowId: CGWindowID = 0
            if _AXUIElementGetWindow(window, &axWindowId) == .success,
               axWindowId == windowId {
                AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, true as CFTypeRef)
                break
            }
        }
    }
}
