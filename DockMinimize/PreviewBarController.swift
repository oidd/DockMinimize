//
//  PreviewBarController.swift
//  DockMinimize
//
//  预览条窗口控制器 - 整合所有模块
//

import Cocoa
import SwiftUI
import Combine

class PreviewBarController: NSObject {
    static let shared = PreviewBarController()
    
    private let log = DebugLogger.shared
    private var cancellables = Set<AnyCancellable>()
    
    /// 悬停事件监听器
    private let hoverMonitor = HoverEventMonitor()
    
    /// 状态管理器
    private let stateManager = PreviewStateManager()
    
    /// 缩略图服务
    private let thumbnailService = WindowThumbnailService.shared
    
    /// 权限管理器
    private let captureManager = ScreenCaptureManager.shared
    
    /// 预览条窗口
    private var previewWindow: NSWindow?
    
    /// 预览条视图模型
    private var viewModel: PreviewBarViewModel?
    
    /// 是否已启动
    private var isStarted: Bool = false
    
    /// 大图预览窗口
    private var largePreviewWindow: NSWindow?
    
    // 当前正在预览的窗口ID，用于防止时序错乱
    private var currentPeekWindowId: CGWindowID?
    
    // 隐藏去抖动任务
    private var unpeekWorkItem: DispatchWorkItem?
    
    private override init() {
        super.init()
        
        hoverMonitor.delegate = self
        stateManager.delegate = self
        
        // 监听强制关闭通知（处理 Dock 右键点击）
        NotificationCenter.default.addObserver(forName: NSNotification.Name("HidePreviewBarForcefully"), object: nil, queue: .main) { [weak self] _ in
            self?.stateManager.hidePreview()
        }
        
        // ⭐️ 全局点击隐藏：监听系统任何地方的点击事件
        NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self = self, self.stateManager.currentState != .hidden else { return }
            
            // 采用全局坐标（(0,0) 为左下角）
            let mouseLocation = NSEvent.mouseLocation
            
            // A. 如果点击在预览条内，不隐藏（虽然 Global Monitor 理论上不报本应用的点击，但这里加一层保险）
            if let window = self.previewWindow, window.frame.contains(mouseLocation) {
                return
            }
            
            // B. 如果点击在 Dock 区域内，不隐藏
            let dockPos = DockPositionManager.shared.currentPosition
            let thickness = DockPositionManager.shared.dockDetectionThickness
            
            let clickedInDock: Bool = {
                switch dockPos {
                case .bottom: return mouseLocation.y < thickness
                case .left:   return mouseLocation.x < thickness
                case .right:  let screenW = NSScreen.main?.frame.width ?? 1200
                               return mouseLocation.x > (screenW - thickness)
                }
            }()
            
            if clickedInDock {
                return
            }
            
            // C. 只有点击桌面、其他窗口等真正“离开”的操作，才立刻强制关闭
            self.stateManager.hidePreview()
        }
    }
    
    /// 启动预览功能
    func start() {
        guard !isStarted else { return }
        
        // 检查是否启用了悬停预览
        guard SettingsManager.shared.hoverPreviewEnabled else {
            log.log("⚠️ Hover preview is disabled in settings")
            return
        }
        
        // 检查屏幕录制权限
        if !captureManager.hasScreenCapturePermission() {
            log.log("⚠️ Screen capture permission not granted")
            // 不阻止启动，但功能可能受限
        }
        
        hoverMonitor.start()
        isStarted = true
        
        log.log("✅ Preview bar controller started")
    }
    
    /// 停止预览功能
    func stop() {
        guard isStarted else { return }
        
        hoverMonitor.stop()
        hidePreviewBar()
        isStarted = false
        
        log.log("🛑 Preview bar controller stopped")
    }
    
    /// 重新启动（用于设置变更后）
    func restart() {
        stop()
        start()
    }
    
    /// 检查内部的 HoverEventMonitor 是否还活着
    func isHoverMonitorAlive() -> Bool {
        guard isStarted else { return true } // 未启动时不视为异常
        return hoverMonitor.isAlive()
    }
    
    /// 显示预览条
    private func showPreviewBar(for bundleId: String, at position: CGPoint) {
        log.log("📺 Showing preview bar for \(bundleId)")
        
        // ⭐️ 同步系统焦点状态，确保 clickThumbnail 逻辑判定准确
        stateManager.syncFocusState(for: bundleId)
        
        // 检查权限
        guard captureManager.hasScreenCapturePermission() else {
            log.log("❌ Cannot show preview: no screen capture permission")
            captureManager.requestPermission()
            return
        }
        
        // ⭐️ 高级优化：复用机制，彻底解决快速移动鼠标导致的 SwiftUI 崩溃
        if let existingVM = viewModel, existingVM.currentBundleId == bundleId {
            log.log("📺 Reusing existing VM for \(bundleId)")
            existingVM.loadWindows(for: bundleId)
        } else {
            log.log("📺 Creating new VM for \(bundleId)")
            // 创建新视图模型前，彻底切断旧视图树，防止由于视图复用导致的内存冲突
            if let window = previewWindow {
                window.contentView = nil
            }
            
            let vm = PreviewBarViewModel(stateManager: stateManager)
            vm.loadWindows(for: bundleId)
            viewModel = vm
            
            if let window = previewWindow {
                // 确保 vm 没有因为 loadWindows 失败变为空（虽然逻辑上不会，但加个保险）
                window.contentView = NSHostingView(rootView: PreviewBarView(viewModel: vm))
            }
            
            // ⭐️ 订阅窗口数量变化，动态调整容器尺寸
            cancellables.removeAll()
            vm.$lastWindowCount
                .dropFirst() // 忽略初始加载
                .sink { [weak self] count in
                    guard let self = self, count > 0, let window = self.previewWindow else { return }
                    
                    self.log.log("📏 Window count changed to \(count), resizing container")
                    let newSize = self.calculateWindowSize(windowCount: count)
                    let newPos = self.calculateWindowPosition(iconPosition: position, windowSize: newSize)
                    
                    NSAnimationContext.runAnimationGroup { context in
                        context.duration = 0.2
                        context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                        window.animator().setFrame(CGRect(origin: newPos, size: newSize), display: true)
                    }
                    
                    // 同步更新监听区域
                    self.updateHoverMonitorFrame(windowFrame: CGRect(origin: newPos, size: newSize))
                }
                .store(in: &cancellables)
        }
        
        // 确保 vm 存在且有窗口
        guard let vm = viewModel, !vm.windows.isEmpty else {
            log.log("⚠️ No windows to preview for \(bundleId)")
            hidePreviewBar()
            return
        }
        
        // 创建或复用窗口
        if previewWindow == nil {
            createPreviewWindow()
        }
        
        guard let window = previewWindow else { return }
        
        // 计算窗口位置（在 Dock 图标上方）
        let windowSize = calculateWindowSize(windowCount: vm.windows.count)
        let windowPosition = calculateWindowPosition(iconPosition: position, windowSize: windowSize)
        
        window.setContentSize(windowSize)
        window.setFrameOrigin(windowPosition)
        
        // 更新预览条区域（用于鼠标检测）- 扩大检测区域，包含到 Dock 的过渡空间
        updateHoverMonitorFrame(windowFrame: window.frame)
        hoverMonitor.isPreviewBarVisible = true
        
        // 显示窗口
        window.orderFront(nil)
        
        // 动画效果
        window.alphaValue = 0
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.08
            window.animator().alphaValue = 1
        }
    }
    
    /// 隐藏预览条
    private func hidePreviewBar() {
        guard let window = previewWindow else { return }
        
        log.log("📺 Hiding preview bar")
        
        hoverMonitor.isPreviewBarVisible = false
        hoverMonitor.previewBarFrame = .zero
        
        // 动画效果
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.1
            window.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            guard let self = self else { return }
            
            // ⭐️ 核心修复：防止时序倒放导致的崩溃
            // 只有当鼠标真的不再悬停（isPreviewBarVisible 为 false）且没有新任务时，才清理。
            // 如果动画结束时，用户已经又移回了图标（isPreviewBarVisible 变回了 true），
            // 那么绝对不能清理 viewModel，否则会导致新开始的预览界面直接崩溃。
            if !self.hoverMonitor.isPreviewBarVisible {
                window.contentView = nil 
                window.orderOut(nil)
                self.viewModel = nil
            }
        }
    }
    
    /// 让 WindowManager 访问 isTransitioning (Swift 属性默认 internal)
    /// 注意：如果 isTransitioning 是 private，需要修改 WindowManager.swift 
    
    /// 更新监听区域
    private func updateHoverMonitorFrame(windowFrame frame: CGRect) {
        let screenHeight = NSScreen.main?.frame.height ?? 1080
        
        // ⭐️ 极致修复：预览条判定区域严格等于窗口物理区域
        // 不再向 Dock 图标区进行物理扩张，防止在侧边 Dock 上滑动时产生“检测短路”
        // 窗口与图标间的“空隙保护”完全交由 HoverEventMonitor 的安全走廊 (Safe Corridor) 处理
        hoverMonitor.previewBarFrame = CGRect(
            x: frame.origin.x,
            y: screenHeight - frame.origin.y - frame.height,
            width: frame.width,
            height: frame.height
        )
    }
    
    /// 创建预览窗口
    private func createPreviewWindow() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 180),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        
        window.isOpaque = false
        window.backgroundColor = .clear
        window.level = .popUpMenu // 设为更高层级，在遮罩之上
        window.hasShadow = true
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .stationary]
        
        // 忽略鼠标事件透传（让 SwiftUI 处理）
        window.ignoresMouseEvents = false
        
        previewWindow = window
        
        log.log("✅ Created preview window")
    }
    
    /// 计算窗口尺寸
    private func calculateWindowSize(windowCount: Int) -> NSSize {
        // ThumbnailCardView: 160 width + 8*2 horizontal padding = 176
        // HStack spacing: 8
        let cardFullWidth: CGFloat = 176 + 8 
        let viewPadding: CGFloat = 40 // HStack padding (20*2)
        let maxWidth = (NSScreen.main?.frame.width ?? 1200) * 0.95
        
        // 我们要窗口大小精准包裹内容，才能实现完美居中
        let contentWidth = CGFloat(windowCount) * cardFullWidth - 8 + viewPadding
        let width = min(contentWidth, maxWidth)
        
        return NSSize(width: width, height: 180)
    }
    
    /// 计算窗口位置
    private func calculateWindowPosition(iconPosition: CGPoint, windowSize: NSSize) -> NSPoint {
        guard let screen = NSScreen.main else {
            return NSPoint(x: 100, y: 100)
        }
        
        let dockPos = DockPositionManager.shared.currentPosition
        let screenHeight = screen.frame.height
        let screenWidth = screen.frame.width
        let appKitY = screenHeight - iconPosition.y
        
        var x: CGFloat = 0
        var y: CGFloat = 0
        
        switch dockPos {
        case .bottom:
            x = iconPosition.x - windowSize.width / 2
            // ⭐️ 紧贴模式：底部 Dock 需要完全盖住系统标签 (带箭头胶囊)，所以偏移设为 0
            y = DockPositionManager.shared.realDockThickness
            
        case .left:
            // ⭐️ 呼吸模式：侧边 Dock 用户反馈 10px 间距良好
            x = DockPositionManager.shared.realDockThickness + 10
            y = appKitY - windowSize.height / 2 // 与图标垂直居中对齐
            
        case .right:
            // ⭐️ 呼吸模式：右侧同理
            let thickness = DockPositionManager.shared.realDockThickness
            x = screenWidth - thickness - 10 - windowSize.width
            y = appKitY - windowSize.height / 2 // 与图标垂直居中对齐
        }
        
        // 确保不超出屏幕边界
        let clampedX = max(10, min(x, screenWidth - windowSize.width - 10))
        let clampedY = max(80, min(y, screenHeight - windowSize.height - 10))
        
        return NSPoint(x: clampedX, y: clampedY)
    }
}

// MARK: - HoverEventMonitorDelegate

extension PreviewBarController: HoverEventMonitorDelegate {
    func hoverEventMonitor(_ monitor: HoverEventMonitor, didHoverOnApp bundleId: String, at position: CGPoint) {
        // 获取 Dock 图标位置
        let iconPosition = monitor.getDockIconPosition(for: bundleId) ?? position
        
        stateManager.showPreview(for: bundleId, at: iconPosition)
    }
    
    func hoverEventMonitorDidExitDock(_ monitor: HoverEventMonitor) {
        // 如果预览条没有显示，不需要处理
        if case .hidden = stateManager.currentState {
            return
        }
        
        // 延迟点再隐藏，给用户移动到预览条的时间
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self = self else { return }
            
            // 检查鼠标当前位置
            let mouseLocation = NSEvent.mouseLocation
            let screenHeight = NSScreen.main?.frame.height ?? 0
            let cgMouseY = screenHeight - mouseLocation.y
            let cgMousePos = CGPoint(x: mouseLocation.x, y: cgMouseY)
            
            // ⭐️ 核心修复：移除 redundant 的 inDock 判定
            // 如果鼠标不在预览条内，且 monitor 已经报告退出了 App（这就是此回调触发的原因），就应该关掉。
            // 不再检查是否在 Dock 区域内，因为“废纸篓”或“Dock 空隙”虽然在 Dock 区域，但不是有效的 App 悬停。
            let inPreviewBar = self.hoverMonitor.previewBarFrame.contains(cgMousePos)
            
            if !inPreviewBar {
                self.stateManager.hidePreview()
            }
        }
    }
    
    func hoverEventMonitor(_ monitor: HoverEventMonitor, didMoveInPreviewBar position: CGPoint) {
        // 鼠标在预览条内移动，不需要特殊处理
        // 实际的悬停检测由 SwiftUI 的 onHover 处理
    }
    
    func hoverEventMonitorDidExitPreviewBar(_ monitor: HoverEventMonitor) {
        // 增加延迟（300ms），防止鼠标在缩略图间切换或快速移动时误触发隐藏
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self = self else { return }
            // 再次检查鼠标是否真的离开了
            let mouseLocation = NSEvent.mouseLocation
            let screenHeight = NSScreen.main?.frame.height ?? 0
            let cgMouseY = screenHeight - mouseLocation.y
            let cgMousePos = CGPoint(x: mouseLocation.x, y: cgMouseY)
            
            if !self.hoverMonitor.previewBarFrame.contains(cgMousePos) {
                self.stateManager.hidePreview()
            }
        }
    }
    
}

// MARK: - PreviewStateManagerDelegate

extension PreviewBarController: PreviewStateManagerDelegate {
    func previewStateManager(_ manager: PreviewStateManager, didChangeState state: PreviewState) {
        // 状态变化日志已在 PreviewStateManager 中处理
    }
    
    func previewStateManager(_ manager: PreviewStateManager, showPreviewFor bundleId: String, at position: CGPoint) {
        showPreviewBar(for: bundleId, at: position)
    }
    
    func previewStateManager(_ manager: PreviewStateManager, hidePreview: Bool) {
        hidePreviewBar()
    }
    
    func previewStateManager(_ manager: PreviewStateManager, didUpdateActiveWindows activeIds: Set<CGWindowID>) {
        DispatchQueue.main.async { [weak self] in
            self?.viewModel?.activeWindowIds = activeIds
        }
    }
    

    

    
    func previewStateManager(_ manager: PreviewStateManager, peekWindow windowId: CGWindowID) {
        // 取消挂起的隐藏任务（实现无缝切换）
        unpeekWorkItem?.cancel()
        unpeekWorkItem = nil
        
        // 防止重复触发导致闪烁/重刷
        if currentPeekWindowId == windowId {
            return
        }
        
        // 检查设置：是否启用原位预览
        if !SettingsManager.shared.enableOriginalPreview {
            return
        }
        
        // 更新当前目标ID
        currentPeekWindowId = windowId
        
        // 1. 尝试获取缓存的缩略图（用于立即显示）
        var title = "Window Preview"
        var initialImage: NSImage?
        var appIcon: NSImage?
        
        if let bundleId = manager.currentAppBundleId {
            // ⭐️ 核心修复：安全获取图标，彻底避免触碰“下载”文件夹
            if let runningApp = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first {
                appIcon = runningApp.icon
            } else if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
                // 检查是否在敏感路径
                let downloadsPath = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first?.path ?? "/Downloads/"
                if !appURL.path.contains(downloadsPath) && !appURL.path.contains("/Downloads/") {
                    appIcon = NSWorkspace.shared.icon(forFile: appURL.path)
                } else {
                    // 如果在下载文件夹，使用通用占位图，严禁调用 icon(forFile:)
                    appIcon = NSWorkspace.shared.icon(for: .application)
                }
            } else {
                appIcon = NSWorkspace.shared.icon(for: .application)
            }
            
            // 获取 WindowInfo
            if let windowInfo = WindowThumbnailService.shared.getWindows(for: bundleId).first(where: { $0.windowId == windowId }) {
                title = windowInfo.title.isEmpty ? windowInfo.ownerName : windowInfo.title
                // 如果有缩略图，先显示缩略图
                if let thumb = windowInfo.thumbnail {
                    initialImage = thumb
                }
            }
        }
        
        // 2. 立即显示（如果有低清图）
        if let image = initialImage {
            DispatchQueue.main.async {
                // 再次检查 ID
                guard self.currentPeekWindowId == windowId else { return }
                self.showLargePreview(windowId: windowId, image: image, title: title, icon: appIcon, isLowRes: true)
            }
        }
        
        // 3. 异步获取高清截图
        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            guard let self = self else { return }
            
            // 检查 ID 是否还在
            if self.currentPeekWindowId != windowId { return }
            
            // 获取高清截图
            guard let image = ScreenCaptureManager.shared.captureWindow(windowId: windowId) else {
                return
            }
            
            // 4. 回到主线程更新为高清图
            DispatchQueue.main.async {
                guard self.currentPeekWindowId == windowId else { return }
                // 更新为高清，不模糊
                self.showLargePreview(windowId: windowId, image: image, title: title, icon: appIcon, isLowRes: false)
            }
        }
    }
    
    func previewStateManager(_ manager: PreviewStateManager, performSeamlessExit: Bool) {
        log.log("✨ Maintaining preview for seamless exit animation...")
        
        // 取消挂起的隐藏任务
        unpeekWorkItem?.cancel()
        unpeekWorkItem = nil
        
        guard let largeWindow = largePreviewWindow else { return }
        
        // 确保窗口是可见的（alpha=1），准备淡出
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            largeWindow.animator().alphaValue = 0
            
            // 可选：同时也淡出缩略图条，让整个界面一起消失
            // self.previewWindow?.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            guard let self = self else { return }
            
            // 动画结束，清理现场
            largeWindow.orderOut(nil)
            largeWindow.contentView = nil
            self.currentPeekWindowId = nil
            
            // 如果缩略图条也被淡出了，需要清理
            // 这里我们保持缩略图条显示（因为它可能还在 hover），只淡出大图
            // 除非状态已经变成 hidden
            if self.stateManager.currentState == .hidden {
                self.hidePreviewBar()
            }
        }
    }
    
    // unpeekWindow 参数说明：
    // true -> 正常透视结束（如鼠标移开） -> 需要延时关闭以支持平滑切换
    // false -> 强制立即结束（如点击） -> 立即关闭
    func previewStateManager(_ manager: PreviewStateManager, unpeekWindow: Bool) {
        log.log("👁️ Request hiding large preview (graceful: \(unpeekWindow))")
        
        // 取消之前的任务
        unpeekWorkItem?.cancel()
        unpeekWorkItem = nil
        
        let closeAction: () -> Void = { [weak self] in
            _ = self?.largePreviewWindow?.orderOut(nil)
            self?.currentPeekWindowId = nil
        }
        
        if unpeekWindow {
            // 优雅关闭：延时执行，给下一个 peek 机会取消它
            let item = DispatchWorkItem {
                closeAction()
            }
            unpeekWorkItem = item
            // 0.15秒延迟，足够鼠标从一个图标滑到另一个
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: item)
        } else {
            // 强制关闭：立即执行
            if Thread.isMainThread {
                closeAction()
            } else {
                DispatchQueue.main.async(execute: closeAction)
            }
        }
    }
    
    /// 显示大图预览窗口（兼容 原位预览 和 居中预览）
    private func showLargePreview(windowId: CGWindowID, image: NSImage? = nil, title: String? = nil, icon: NSImage? = nil, isLowRes: Bool = false) {
        // 0. 准备基础数据
        guard let screen = NSScreen.main else { return }
        let screenFrame = screen.frame
        let settings = SettingsManager.shared
        
        // 检查是否启用“原位预览”
        guard settings.enableOriginalPreview else { return }
        
        // 获取窗口信息（如果是原位预览，必须有）
        var targetFrame = screenFrame
        var finalImage = image
        var finalTitle = title ?? "Preview"
        let finalIcon = icon
        
        let service = WindowThumbnailService.shared
        
        // 需要找到对应的 WindowInfo 来获取 Frame
        // WindowThumbnailService 需要稍微扩展一下支持通过 ID 查信息，或者我们遍历一下
        // 由于这里没有 bundleId 上下文，我们只能全搜索或传参进来。
        // 优化：previewStateManager 已经知道 bundleId，传进来最好。
        // 暂时：用 SettingsManager 或 WindowThumbnailService 现有的数据
        // 为了简单，我们刚才在 peekWindow 里已经有了 id，我们其实可以在那里获取 info
        // 但为了架构干净，我们假设 image 已经传进来了，或者在这里获取。
        
        // 针对原位预览，我们需要高清原图（如果外面没传）
        if finalImage == nil || isLowRes {
            if let fullImg = service.captureFullImage(for: windowId) {
                finalImage = fullImg
            }
        }
        
        // 获取 Frame
        var foundBounds = false
        if let bundleId = stateManager.currentAppBundleId,
           let info = service.getWindows(for: bundleId).first(where: { $0.windowId == windowId }) {
            targetFrame = info.bounds
            
            // ⭐️ 核心修正：使用主屏幕（Index 0）的高度作为坐标翻转基准，确保在任何屏幕上行为一致
            let primaryScreenHeight = NSScreen.screens.first?.frame.height ?? 1080
            let appKitY = primaryScreenHeight - targetFrame.origin.y - targetFrame.height
            
            log.log("📐 Original Bounds (CG): \(targetFrame)")
            targetFrame.origin.y = appKitY
            log.log("📐 Final Frame (AppKit): \(targetFrame) on Primary Height: \(primaryScreenHeight)")
            
            finalTitle = info.title
            foundBounds = true
        }
        
        // 如果找不到 Bounds，无法原位预览，直接放弃
        guard foundBounds else { 
            log.log("⚠️ Could not find bounds for window \(windowId), aborting original preview")
            return 
        }
        
        // 如果没有图像，无法显示
        guard let displayImage = finalImage else { 
            log.log("⚠️ No image captured for window \(windowId)")
            return 
        }
        
        // 复用或创建窗口
        let window: NSWindow
        if let existing = largePreviewWindow {
            window = existing
        } else {
            window = NSWindow(
                contentRect: .zero,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            window.isOpaque = false
            window.backgroundColor = .clear
            window.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
            window.ignoresMouseEvents = true 
            largePreviewWindow = window
        }
        
        // 设置 Frame 和 Level
        log.log("📐 Setting Large Preview frame: \(targetFrame)")
        window.setFrame(targetFrame, display: true)
        window.level = .floating

        // ⭐️ 核心修正：改用原生 NSImageView 以获得像素级的对齐支持
        // SwiftUI 的容器在处理出界 Frame 时会有难以预料的居中行为，底层 NSImageView 更可控。
        let imageView = NSImageView(frame: NSRect(origin: .zero, size: targetFrame.size))
        imageView.image = displayImage
        imageView.imageScaling = .scaleNone // 禁止任何缩放，保持 1:1
        
        // 计算对齐方式
        if targetFrame.origin.x < 0 {
            // 窗口左侧出界：截图只有右半部 -> 内容右对齐
            imageView.imageAlignment = .alignTopRight
            log.log("📐 Alignment: .alignTopRight (Window left out)")
        } else {
            // 正常 或 窗口右侧出界：截图从左侧起算 -> 内容左对齐
            imageView.imageAlignment = .alignTopLeft
            log.log("📐 Alignment: .alignTopLeft (Window normal or right out)")
        }
        
        // 垂直方向统一置顶（因为我们的 Frame 已经 flip 过了）
        // 如果是 imageAlignRight，会自动组合成右上对齐
        
        window.contentView = imageView
        log.log("🖼 Image size (Point): \(displayImage.size) set to Content View")
        
        if !window.isVisible {
            window.alphaValue = 0
            window.orderFront(nil)
            window.animator().alphaValue = 1
        }
    }
}
