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
    
    /// ⭐️ 新增：同步活跃窗口集合
    func previewStateManager(_ manager: PreviewStateManager, didUpdateActiveWindows activeIds: Set<CGWindowID>)

    /// ⭐️ 聚焦预览优化：渐进遮罩进度回调（0.0 ~ 1.0）
    func previewStateManager(_ manager: PreviewStateManager,
                             dwellProgressChanged progress: CGFloat,
                             forWindowId windowId: CGWindowID)
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
    private(set) var activeWindowIds: Set<CGWindowID> = [] {
        didSet {
            if activeWindowIds != oldValue {
                delegate?.previewStateManager(self, didUpdateActiveWindows: activeWindowIds)
            }
        }
    }
    
    /// 重置活跃窗口列表
    func resetActiveWindows(_ ids: Set<CGWindowID>) {
        self.activeWindowIds = ids
    }
    
    /// ⭐️ 统一更新活跃状态的方法
    func setSingleActiveWindow(_ id: CGWindowID?) {
        if let id = id {
            self.activeWindowIds = [id]
        } else {
            self.activeWindowIds = []
        }
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

    // MARK: - 聚焦预览优化（方案一 + 方案二 + 方案三）

    /// 当前会话是否已触发过至少一次 peek（区分"首次进入"和"跨缩略图切换"）
    private var hasPeekedInCurrentSession: Bool = false

    /// 首次 peek 延迟（长一些，防误触）
    private let firstPeekDelay: TimeInterval = 0.22

    /// 后续 peek 延迟（保持原有极速响应）
    private let normalPeekDelay: TimeInterval = 0.1

    /// 方案二：渐进遮罩驻留进度与定时器
    private var dwellProgress: CGFloat = 0
    private var dwellTimer: Timer?
    private var dwellRampWorkItem: DispatchWorkItem?
    private let dwellRampDuration: TimeInterval = 0.30
    private let dwellRampStartDelay: TimeInterval = 0.10

    /// 方案三：快速切换检测
    private var rapidSwitchCount: Int = 0
    private var rapidSwitchWindowStart: Date = .distantPast
    private let rapidSwitchThreshold: Int = 3
    private let rapidSwitchWindow: TimeInterval = 0.4

    /// 最后一次由我们执行激活操作的窗口（持久保存直到隐藏）
    private var lastActivatedWindowId: CGWindowID?
    /// 最后一次通过系统查询到的焦点窗口 (在预览条显示时同步)
    private var lastFocusedWindowId: CGWindowID?
    
    /// 主动同步指定应用的焦点状态
    func syncFocusState(for bundleId: String) {
        // ⭐️ 核心修正：首先重置活跃集合
        self.activeWindowIds = []
        
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first else { return }
        
        // ⭐️ 关键判别：如果该应用本身不是系统最前端应用，那么它的所有窗口都不应该是“活跃颜色”
        // 即使它内部有一个“最后焦点记录”，由于它在后台，指示条也应该统一表现为 50% 透明度
        let frontmostApp = NSWorkspace.shared.frontmostApplication
        guard frontmostApp?.bundleIdentifier == bundleId else {
            log.log("📱 App \(bundleId) is in background (Frontmost: \(frontmostApp?.bundleIdentifier ?? "none")). All indicators will be 50% opacity.")
            // ⭐️ Bug 修复：App 在后台时，必须清掉 lastFocusedWindowId / lastActivatedWindowId 这些 stale 状态。
            //    否则 clickThumbnail 的「轨道 2」会用陈旧的 lastFocusedWindowId 误判 → 错误执行 Minimize。
            //    正确语义：只要目标 App 不是前台，它就不存在「当前焦点窗口」概念，必须清空。
            self.lastFocusedWindowId = nil
            self.lastActivatedWindowId = nil
            return
        }

        
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        var focusedWindow: AnyObject?
        let result = AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &focusedWindow)
        
        if result == .success, let focusedElement = focusedWindow {
            // ⭐️ 防御性修复：用 CFGetTypeID 验证 + unsafeBitCast 转型，
            // 避免在某些极端情况下（焦点对象不是 AXUIElement）触发 SIGABRT 的 force cast 崩溃。
            // (AXUIElement 是 CoreFoundation 类型，Swift 的 as? 对它无法做实际类型检查、永远成功)
            if CFGetTypeID(focusedElement) == AXUIElementGetTypeID() {
                let element = unsafeBitCast(focusedElement, to: AXUIElement.self)
                var focusedWindowId: CGWindowID = 0
                if _AXUIElementGetWindow(element, &focusedWindowId) == .success {
                    self.lastFocusedWindowId = focusedWindowId
                    self.activeWindowIds = [focusedWindowId]
                    log.log("🎯 Synced focus state: Window \(focusedWindowId) is top-level focus.")
                }
            } else {
                log.log("⚠️ syncFocusState: focusedWindow is not an AXUIElement, skipping")
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
        // 如果切换了应用，清空置顶记忆 + 聚焦预览会话状态
        if currentAppBundleId != bundleId {
            lastActivatedWindowId = nil
            lastFocusedWindowId = nil
            hasPeekedInCurrentSession = false
            rapidSwitchCount = 0
            rapidSwitchWindowStart = .distantPast
            cancelDwellRamp()
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
        guard !isScrolling else { return }

        // 如果已经在透视同一个窗口，不需要重新计时
        if case .peeking(let currentWindowId) = currentState, currentWindowId == windowId {
            return
        }

        cancelPeekTimer()
        cancelDwellRamp()

        // ⭐️ 方案三：快速切换检测 —— 区分"扫视"和"有意停留"
        let now = Date()

        if now.timeIntervalSince(rapidSwitchWindowStart) < rapidSwitchWindow {
            rapidSwitchCount += 1
        } else {
            rapidSwitchCount = 1
            rapidSwitchWindowStart = now
        }

        // 如果正在快速扫视且尚未触发过 peek → 抑制触发
        if rapidSwitchCount >= rapidSwitchThreshold && !hasPeekedInCurrentSession {
            log.log("⏩ Rapid switching detected (\(rapidSwitchCount) in window), suppressing peek")
            // ramp 可能已残留部分透明度，显式隐藏遮罩避免闪动残留
            FocusPreviewMaskController.shared.hide(animated: true)
            return
        }

        // ⭐️ 区分首次 / 后续 peek 延迟
        let delay = hasPeekedInCurrentSession ? normalPeekDelay : firstPeekDelay
        log.log("⏱️ Starting peek timer with delay: \(delay)s (hasPeeked: \(hasPeekedInCurrentSession))")

        // ⭐️ 方案二：首次进入延迟 100ms 后才启动渐进遮罩 ramp
        // 静默期过滤掉鼠标无意划过（<100ms），避免遮罩闪动
        if !hasPeekedInCurrentSession {
            dwellRampWorkItem?.cancel()
            let workItem = DispatchWorkItem { [weak self] in
                self?.startDwellRamp(for: windowId)
            }
            dwellRampWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + dwellRampStartDelay, execute: workItem)
        }

        startPeekTimer(for: windowId, delay: delay)
    }
    
    /// 鼠标离开缩略图
    func exitThumbnail() {
        cancelDwellRamp()
        cancelPeekTimer()

        // 如果正在透视，取消透视
        if case .peeking = currentState {
            cancelPeek()

            // 回到 showing 状态
            if let bundleId = currentAppBundleId {
                currentState = .showing(appBundleId: bundleId)
            }
        } else {
            // ramp 进行中但 peek 未触发：显式隐藏遮罩，避免残留部分透明度
            FocusPreviewMaskController.shared.hide(animated: true)
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
            cancelPeek(restorePreviousApp: false)
        }
        
        // ⭐️ 核心功能：点击展开/收回
        // 逻辑：只要 App 在前台，且窗口是我们认为的“最前窗口”，就执行最小化。
        
        var shouldMinimize = false
        
        // ⭐️ Bug④ 修复：Finder 必须走「二态判定」短路，跳过下面的四轨道。
        // 原因：Finder 桌面窗口永远 Main=true、frontmost 经常不是 Finder，
        // 老逻辑会把蓝色（已展开在桌面）的窗口误判成「该最小化」。
        // 见 FinderSpecialHandler.swift 头部 Invariant I2。
        if FinderSpecialHandler.handles(currentAppBundleId) {
            shouldMinimize = FinderSpecialHandler.shouldMinimizeOnClick(
                window: windowInfo,
                lastActivatedWindowId: lastActivatedWindowId
            )
            log.log("✅ [Finder] Click decision: shouldMinimize=\(shouldMinimize) (isMinimized=\(windowInfo.isMinimized), lastActivated=\(String(describing: lastActivatedWindowId)))")
        } else {
            // ⭐️ 顺序重构（修复「点击桌面上显示的窗口反被隐藏」+「点完第二次仍 raise」连环回归）：
            //
            // 新优先级顺序：
            //   轨道 1（最强信任）：lastActivatedWindowId == windowId
            //     —— 我们刚才点过这个窗口、它必在最前 → 直接 Minimize。
            //     不依赖 frontmost/isActive，避免 hover 时 frontmost 漂移到 Dock/我们自己导致误判。
            //
            //   Activate-only path（轨道 1 未命中时的「后台 App 兜底」）：
            //     如果目标 App 不是 frontmost 且 .isActive==false，那么它内部的 stale
            //     lastFocusedWindowId/kAXMain/kAXFocused 都不能信，必然走 Activate。
            //
            //   轨道 2/3（兜底）：目标 App 是前台 → 用 lastFocusedWindowId/AX 实时判定。
            
            // 轨道 1：内存置顶记录（最强信任）
            // 只要我们刚才点过它，且中途没换过 App，无论现在 frontmost 是谁，它必然在最前面 → Minimize
            if lastActivatedWindowId == windowId {
                shouldMinimize = true
                log.log("✅ Match: Memory persist (last activated). Action: Minimize.")
            } else {
                // 判定目标 App 是否实际在前台（任一条件满足即可）：
                //   - frontmost == 目标 App
                //   - NSRunningApplication.isActive == true（更稳，覆盖 frontmost 漂移到 Dock/我们的瞬态）
                let targetApp = NSRunningApplication(processIdentifier: windowInfo.ownerPID)
                let targetAppIsFront =
                    NSWorkspace.shared.frontmostApplication?.bundleIdentifier == currentAppBundleId ||
                    targetApp?.isActive == true
                
                if !targetAppIsFront {
                    // Activate-only 兜底：目标 App 在后台时（半透明蓝指示条），意图必为 Activate。
                    // 这条路径解决了「lastFocusedWindowId/AX 在后台 App 上保留 stale 状态导致误最小化」的回归。
                    log.log("📱 Target app not active (Activate-only path).")
                    shouldMinimize = false
                } else {
                    // 目标 App 在前台 → 走原始的轨道 2/3 兜底
                    let frontBundleId = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
                    
                    // 轨道 2：系统查询记录
                    if lastFocusedWindowId == windowId {
                        shouldMinimize = true
                        log.log("✅ Match: AX focus sync. Action: Minimize.")
                    }
                    // 轨道 3：实时补位检测（应对用户手动点击窗口的情况）
                    else {
                        var focusedWindow: AnyObject?
                        if AXUIElementCopyAttributeValue(windowInfo.appAxElement, kAXFocusedWindowAttribute as CFString, &focusedWindow) == .success,
                           let focusedElement = focusedWindow,
                           CFGetTypeID(focusedElement) == AXUIElementGetTypeID() {
                            // ⭐️ 防御性：用 CFGetTypeID 验证 + unsafeBitCast，避免 force cast 崩溃
                            let element = unsafeBitCast(focusedElement, to: AXUIElement.self)
                            var focusedId: CGWindowID = 0
                            if _AXUIElementGetWindow(element, &focusedId) == .success && focusedId == windowId {
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
                        
                        if !shouldMinimize {
                            log.log("📱 App front but no track matched (front=\(frontBundleId ?? "none")). Action: Activate.")
                        }
                    }
                }
            }
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
            self.activeWindowIds = [windowId] // ⭐️ 切换焦点：清空旧的，仅保留当前点击的
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
    private func startPeekTimer(for windowId: CGWindowID, delay: TimeInterval? = nil) {
        let effectiveDelay = delay ?? peekDelay
        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self, !self.isScrolling else { return }

            self.startPeek(windowId: windowId)
        }

        peekTimer = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + effectiveDelay, execute: workItem)
    }
    
    /// 取消透视计时
    private func cancelPeekTimer() {
        peekTimer?.cancel()
        peekTimer = nil
    }

    // MARK: - 方案二：渐进遮罩

    /// 启动渐进遮罩驻留 ramp（0→1，共 dwellRampDuration 秒）
    private func startDwellRamp(for windowId: CGWindowID) {
        dwellProgress = 0
        dwellTimer?.invalidate()

        let stepInterval: TimeInterval = 1.0 / 60.0
        let stepIncrement = CGFloat(stepInterval / dwellRampDuration)

        let timer = Timer(fire: Date(), interval: stepInterval, repeats: true) { [weak self] timer in
            guard let self = self else { timer.invalidate(); return }
            guard !self.isScrolling else { timer.invalidate(); return }

            self.dwellProgress = min(1.0, self.dwellProgress + stepIncrement)

            DispatchQueue.main.async {
                self.delegate?.previewStateManager(self,
                                                   dwellProgressChanged: self.dwellProgress,
                                                   forWindowId: windowId)
            }

            if self.dwellProgress >= 1.0 {
                timer.invalidate()
            }
        }

        dwellTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func cancelDwellRamp() {
        dwellRampWorkItem?.cancel()
        dwellRampWorkItem = nil
        dwellTimer?.invalidate()
        dwellTimer = nil
        dwellProgress = 0
    }
    
    /// 开始透视
    private func startPeek(windowId: CGWindowID) {
        hasPeekedInCurrentSession = true
        cancelDwellRamp()

        log.log("👁️ Starting peek for window \(windowId)")
        
        // 记录当前活跃应用（用于后续恢复焦点）
        previousActiveApp = NSWorkspace.shared.frontmostApplication
        
        currentState = .peeking(windowId: windowId)
        
        delegate?.previewStateManager(self, peekWindow: windowId)
        
        // 透视窗口：临时置顶但不抢焦点
        peekWindow(windowId: windowId)
    }
    
    /// 取消透视
    private func cancelPeek(restorePreviousApp: Bool = true) {
        log.log("👁️ Cancelling peek")
        
        delegate?.previewStateManager(self, unpeekWindow: true)
        
        // 恢复之前的焦点
        if restorePreviousApp, let previousApp = previousActiveApp {
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
                    guard let self = self else { return }
                    guard case .peeking(let currentWindowId) = self.currentState, currentWindowId == windowId else { return }
                    self.previousActiveApp?.activate(options: [])
                }
                
                return
            }
        }
    }
    // MARK: - 窗口操作（新版本：使用 WindowInfo 中的 axElement）
    
    /// 激活窗口（展开）- 使用保存的 axElement 直接操作
    private func activateWindow(windowInfo: WindowThumbnailService.WindowInfo) {
        let windowId = windowInfo.windowId
        
        // ⭐️ Bug② 修复（二轮加强版）：
        // 用户反馈：仅 NSApp.deactivate() 不够 —— 设置面板还是会被弹到最前。
        // 根因：app.activate(.activateIgnoringOtherApps) 会让系统在切到目标 App 前
        // 把调用方（DockMinimize）所有 normal level 的窗口顺手 orderFront 一遍。
        // NSApp.deactivate() 只把"App 焦点"释放了，并没有把窗口降序。
        //
        // 真正可靠的做法：在抢焦点之前，把所有自己的 normal level 可见窗口
        // **临时降级到 .floating - 1**（一个不会被系统抬起的低 level），
        // 等 1.5s 后再恢复回 .normal。这样系统找不到它们去 orderFront，
        // 它们就乖乖留在原 Z-order 上。
        //
        // 注意：1.5s 只是 macOS 切 App 的窗口浮起动作的时间窗，过后恢复完全无视觉差异。
        let demotedWindows: [(NSWindow, NSWindow.Level)] = self.demoteOwnNormalWindows()
        if !demotedWindows.isEmpty {
            log.log("🔇 Bug② fix: demoted \(demotedWindows.count) own window(s) below normal before activate target.")
            // 1.5s 后恢复 level
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self = self else { return }
                for (window, originalLevel) in demotedWindows {
                    window.level = originalLevel
                }
                self.log.log("🔊 Bug② fix: restored \(demotedWindows.count) own window level(s).")
            }
        }
        
        // ⭐️ Bug① 缓解：Finder 走轻量激活序列，避免给 Finder 主循环密集推 7 个状态变更
        // 详见 FinderSpecialHandler.swift 头部 Invariant I1
        if FinderSpecialHandler.handles(currentAppBundleId) {
            FinderSpecialHandler.activateWindow(windowInfo, log: log)
            return
        }
        
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
    
    /// 检查 DockMinimize 自己是否存在 normal level 的可见窗口（如设置面板）。
    /// 用于 Bug② 修复：决定是否需要在 activateWindow 前调用 NSApp.deactivate()。
    /// 排除 popUpMenu / floating 等高 level 的预览窗口（它们不会被 macOS 顺势抬起）。
    private func hasVisibleNormalLevelWindow() -> Bool {
        for window in NSApp.windows {
            guard window.isVisible else { continue }
            // 只关心 .normal level 的窗口（设置面板就是这个 level）
            if window.level == .normal {
                return true
            }
        }
        return false
    }
    
    /// Bug② 修复辅助：把所有自己 .normal level 的可见窗口临时降级，
    /// 防止下面 app.activate(.activateIgnoringOtherApps) 让系统顺手 orderFront 它们。
    /// 返回 [(window, originalLevel)]，调用方负责在合适时机恢复。
    ///
    /// 降级目标：用 .init(rawValue: NSWindow.Level.normal.rawValue - 100)，
    /// 这是一个比 .normal 低、但仍在所有桌面壁纸/Dock 窗口之上的 level。
    /// 视觉上完全等同于 .normal（依然在桌面之上），系统在切 App 时不会拉它们。
    private func demoteOwnNormalWindows() -> [(NSWindow, NSWindow.Level)] {
        var result: [(NSWindow, NSWindow.Level)] = []
        let demotedLevel = NSWindow.Level(rawValue: NSWindow.Level.normal.rawValue - 100)
        for window in NSApp.windows {
            guard window.isVisible else { continue }
            guard window.level == .normal else { continue }
            result.append((window, window.level))
            window.level = demotedLevel
        }
        return result
    }
    
    /// 最小化窗口（收回）- 使用保存的 axElement 直接操作
    private func minimizeWindow(windowInfo: WindowThumbnailService.WindowInfo) {
        let windowId = windowInfo.windowId
        
        // ⭐️ 单窗口优化模式：直接 Hide App
        let appBundleId = currentAppBundleId ?? ""
        let allWindows = WindowThumbnailService.shared.getWindows(for: appBundleId)
        
        // Finder 特殊处理（I1）：即使是单窗口，也绝不隐藏应用，而是最小化窗口。
        // 因为 Finder 的桌面也是它的窗口，hide 会让桌面消失。详见 FinderSpecialHandler。
        if FinderSpecialHandler.handles(appBundleId) {
            // 继续执行下面的 AX 最小化逻辑
        } else if allWindows.count <= 1 {
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
