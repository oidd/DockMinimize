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
    
    // ⭐️ 大图预览的最长存活定时器（兜底，防止任何异常时序下大图遗留在桌面）
    private var largePreviewWatchdog: DispatchWorkItem?
    private let largePreviewMaxLifetime: TimeInterval = 5.0
    
    private override init() {
        super.init()
        
        hoverMonitor.delegate = self
        stateManager.delegate = self
        
        // 监听强制关闭通知（处理 Dock 右键点击）
        NotificationCenter.default.addObserver(forName: NSNotification.Name("HidePreviewBarForcefully"), object: nil, queue: .main) { [weak self] _ in
            self?.stateManager.hidePreview()
        }

        // ⭐️ 「保持小窗显示」开关：关闭时，点击任意 Dock 图标后立即隐藏预览。
        // 现有 DockIconClicked 通知由 DockEventMonitor 在用户左键点击 Dock 图标时发出，
        // PreviewBarViewModel.handleDockClick 也监听同一通知做指示条预测式翻转——这两条互不冲突。
        //
        // ⚠️ 时序关键：DockEventMonitor 用 10ms 超时保险箱包裹 post() 之后的所有工作。
        // 若 post() 本身因为我们的观察者多做了额外调度（例如 queue:.main 会触发 OperationQueue
        // 内部锁/run loop 调度），就可能把整体推过 10ms 超时阈值，导致 Dock 点击被系统放行、
        // WindowManager.toggleWindows 不被调用（症状：指示条翻色但窗口不最小化）。
        // 因此这里采用与现有 handleDockClick 一致的「无队列同步观察者 + 内部 async to main」
        // 模式，使得 post() 的开销与改动前几乎相同。
        NotificationCenter.default.addObserver(forName: NSNotification.Name("DockIconClicked"), object: nil, queue: nil) { [weak self] _ in
            // 同步在 post 的后台线程内立刻 dispatch_async 到主线程，避免阻塞 10ms 时序窗口。
            DispatchQueue.main.async {
                guard let self = self else { return }
                guard !SettingsManager.shared.previewStaysVisible else { return }
                guard self.stateManager.currentState != .hidden else { return }
                self.log.log("🪟 DockIconClicked + previewStaysVisible=false → hidePreview")
                self.stateManager.hidePreview()
            }
        }
        
        // ⭐️ 多桌面（Spaces）修复：切换 Space 时主动清场，避免预览小窗带着旧 Space 的坐标
        // 残留在新 Space 上（或因 Space 归属错乱而完全不显示）
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
            if self.stateManager.currentState != .hidden {
                self.log.log("🪟 Active Space changed → hide preview to avoid stale coordinates")
                self.stateManager.hidePreview()
            }
        }
        
        // ⭐️ 全局点击隐藏：监听系统任何地方的点击事件
        NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self = self, self.stateManager.currentState != .hidden else { return }
            
            // 采用 AppKit 全局坐标（多屏下：主屏左下为原点；副屏 origin 反映其相对位置）
            let mouseLocation = NSEvent.mouseLocation
            
            // A. 如果点击在预览条内，不隐藏（虽然 Global Monitor 理论上不报本应用的点击，但这里加一层保险）
            if let window = self.previewWindow, window.frame.contains(mouseLocation) {
                return
            }
            
            // B. 如果点击在「鼠标所在屏幕」的 Dock 区域内，不隐藏
            // ⭐️ 多显示器修复：基于鼠标所在屏幕判断，不再用 NSScreen.main
            let mouseScreen = ScreenLocator.screenContainingAppKit(point: mouseLocation) ?? NSScreen.main
            let screenFrame = mouseScreen?.frame ?? CGRect(x: 0, y: 0, width: 1200, height: 800)
            let dockPos = DockPositionManager.shared.position(for: mouseScreen)
            let thickness = DockPositionManager.shared.dockDetectionThickness
            
            let clickedInDock: Bool = {
                switch dockPos {
                case .bottom:
                    // AppKit y 越小越靠下；底部 Dock 占据屏幕底部 thickness 高度
                    return mouseLocation.y >= screenFrame.minY && mouseLocation.y < (screenFrame.minY + thickness)
                case .left:
                    return mouseLocation.x >= screenFrame.minX && mouseLocation.x < (screenFrame.minX + thickness)
                case .right:
                    return mouseLocation.x > (screenFrame.maxX - thickness) && mouseLocation.x <= screenFrame.maxX
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
        // ⭐️ 兜底：彻底清理大图预览，避免应用退出/停服后桌面上仍遗留大图
        forceHideLargePreview()
        isStarted = false
        
        log.log("🛑 Preview bar controller stopped")
    }
    
    /// ⭐️ 强制隐藏大图预览（兜底方法）
    /// 用于：hidePreviewBar 完成后、stop()、watchdog 触发等所有需要确保大图消失的场景
    /// 同步执行，不带动画，确保 100% 关闭
    private func forceHideLargePreview() {
        unpeekWorkItem?.cancel()
        unpeekWorkItem = nil
        largePreviewWatchdog?.cancel()
        largePreviewWatchdog = nil
        
        if let largeWindow = largePreviewWindow {
            largeWindow.orderOut(nil)
            largeWindow.contentView = nil
            largeWindow.alphaValue = 1   // 重置 alpha，下次复用时不会还是 0
        }
        currentPeekWindowId = nil
        
        // ⭐️ 聚焦预览：兜底关闭遮罩，绝不让毛玻璃残留在桌面
        FocusPreviewMaskController.shared.hide(animated: false)
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
        // ⭐️ 多桌面（Spaces）修复：用 orderFrontRegardless()，
        //    强制把小窗顶到当前活跃 Space 的最前。
        //    普通 orderFront 在切到新 Space 后偶尔会被系统判定为属于旧 Space 而不显示。
        window.orderFrontRegardless()
        
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
        
        // ⭐️ 聚焦预览：预览条隐藏时，遮罩也必须随之消失（用户已离开 hover 区域）
        FocusPreviewMaskController.shared.hide(animated: true)

        
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
                // ⚠️ 这里"曾经"加过 self.forceHideLargePreview()，但它会在某些时序下与 hover 后台
                //    线程产生 retain/release 数据竞争（SIGSEGV）。
                //    大图的兜底关闭由 showLargePreview 末尾的 5s watchdog 负责，已足够。
            }
        }
    }
    
    /// 让 WindowManager 访问 isTransitioning (Swift 属性默认 internal)
    /// 注意：如果 isTransitioning 是 private，需要修改 WindowManager.swift 
    
    /// 更新监听区域
    /// - Parameter frame: 预览条窗口在 AppKit 全局坐标系中的 Frame
    private func updateHoverMonitorFrame(windowFrame frame: CGRect) {
        // ⭐️ 多显示器修复：HoverEventMonitor 收到的 location 是 CG 全局坐标 (主屏左上为原点)，
        //    所以这里的 previewBarFrame 也必须是 CG 全局坐标。
        //    转换规则：cg.y = primaryScreen.maxY - appKit.y - height
        let primaryMaxY: CGFloat = NSScreen.screens.first.map { $0.frame.origin.y + $0.frame.height } ?? 1080
        hoverMonitor.previewBarFrame = CGRect(
            x: frame.origin.x,
            y: primaryMaxY - frame.origin.y - frame.height,
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
        // ⭐️ 关闭 AppKit 系统阴影：
        //  在 macOS 26+ 上 SwiftUI .glassEffect() 会自带液态玻璃的边缘折射光晕，
        //  AppKit 旧式 hasShadow 会贴着圆角矩形再画一圈灰阴影，
        //  既"压住"了液态玻璃自带的折射效果，也是浅色模式下灰描边的主要来源。
        //  老系统（macOS 13~15）的 NSVisualEffectView 也无需依赖 hasShadow，
        //  统一关掉视觉更干净。
        window.hasShadow = false
        window.isReleasedWhenClosed = false
        // ⭐️ 多桌面（Spaces）修复：
        //  - 移除 .stationary：它表示窗口"贴在屏幕上不跟随 Space 切换"，
        //    在与 .canJoinAllSpaces 同时使用时，普通 Space 切换后系统会出现
        //    Space 归属错乱，导致预览小窗在新 Space 上彻底不显示。
        //  - 加上 .fullScreenAuxiliary：让悬浮窗能正确出现在全屏 App 形成的独立 Space。
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        
        // 忽略鼠标事件透传（让 SwiftUI 处理）
        window.ignoresMouseEvents = false
        
        previewWindow = window
        
        log.log("✅ Created preview window")
    }
    
    /// 计算窗口尺寸
    private func calculateWindowSize(windowCount: Int) -> NSSize {
        // ThumbnailCardView: 180 width + 8*2 horizontal padding = 196
        // HStack spacing: 8
        // ⭐️ 与 ThumbnailCardView 中放大后的 thumbnailWidth(180) 保持同步，
        //    否则窗口宽度会比内容窄，导致 ScrollView 首屏偏移（截图偏右 bug）
        let cardFullWidth: CGFloat = 196 + 8
        // ⭐️ 与 PreviewBarView 中 HStack.padding(.horizontal, 10) 同步：10×2 = 20
        let viewPadding: CGFloat = 20
        let maxWidth = (NSScreen.main?.frame.width ?? 1200) * 0.95
        
        // 我们要窗口大小精准包裹内容，才能实现完美居中
        let contentWidth = CGFloat(windowCount) * cardFullWidth - 8 + viewPadding
        let width = min(contentWidth, maxWidth)
        
        // ⭐️ 容器高度 182 → 166：上下两层 vertical padding 进一步压到 2/2，整体小窗更紧凑
        return NSSize(width: width, height: 166)
    }
    
    /// 计算窗口位置（多显示器感知）
    /// - Parameters:
    ///   - iconPosition: Dock 图标在 CG 全局坐标系下的中心点 (主屏左上为原点)
    ///   - windowSize: 预览窗口尺寸
    /// - Returns: NSWindow setFrameOrigin 期望的 AppKit 全局坐标 (主屏左下为原点)
    private func calculateWindowPosition(iconPosition: CGPoint, windowSize: NSSize) -> NSPoint {
        // ⭐️ 多显示器修复：以「Dock 图标所在的屏幕」作为参考，而不是 NSScreen.main
        // iconPosition 是 CG 坐标 (Dock 图标 axElement 给的也是 CG 坐标)，先定位屏幕
        let iconScreen = ScreenLocator.screenContainingCG(point: iconPosition)
            ?? NSScreen.main
        
        guard let screen = iconScreen else {
            return NSPoint(x: 100, y: 100)
        }
        
        let screenFrame = screen.frame  // AppKit 坐标，包含该屏的相对位置
        let dockPos = DockPositionManager.shared.position(for: screen)
        let dockThickness = DockPositionManager.shared.realDockThickness(for: screen)
        
        // 把 CG 图标坐标转换为 AppKit 全局坐标
        let iconAK = ScreenLocator.appKitPoint(fromCGGlobal: iconPosition)
        
        var x: CGFloat = 0
        var y: CGFloat = 0
        
        switch dockPos {
        case .bottom:
            // X 与图标水平居中对齐
            x = iconAK.x - windowSize.width / 2
            // Y 紧贴 Dock 顶部：以该屏底边 + dockThickness 为 baseline
            y = screenFrame.minY + dockThickness
            
        case .left:
            // X：紧贴左侧 Dock 右沿 + 10px
            x = screenFrame.minX + dockThickness + 10
            // Y 与图标垂直居中对齐
            y = iconAK.y - windowSize.height / 2
            
        case .right:
            // X：紧贴右侧 Dock 左沿 - windowSize.width - 10px
            x = screenFrame.maxX - dockThickness - 10 - windowSize.width
            y = iconAK.y - windowSize.height / 2
        }
        
        // 确保不超出该屏幕边界（不再用主屏宽高）
        let clampedX = max(screenFrame.minX + 10, min(x, screenFrame.maxX - windowSize.width - 10))
        let clampedY = max(screenFrame.minY + 10, min(y, screenFrame.maxY - windowSize.height - 10))
        
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
            
            // ⭐️ 多显示器修复：用 ScreenLocator 把 AppKit 鼠标坐标转 CG，再与 previewBarFrame (CG) 比较
            let mouseLocation = NSEvent.mouseLocation
            let cgMousePos = ScreenLocator.cgPoint(fromAppKitGlobal: mouseLocation)
            
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
            // ⭐️ 多显示器修复：同上
            let mouseLocation = NSEvent.mouseLocation
            let cgMousePos = ScreenLocator.cgPoint(fromAppKitGlobal: mouseLocation)
            
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

    func previewStateManager(_ manager: PreviewStateManager,
                             dwellProgressChanged progress: CGFloat,
                             forWindowId windowId: CGWindowID) {
        guard SettingsManager.shared.enableFocusPreview else { return }

        if let bundleId = manager.currentAppBundleId,
           let info = WindowThumbnailService.shared.getWindows(for: bundleId).first(where: { $0.windowId == windowId }) {
            let primaryScreenHeight = NSScreen.screens.first?.frame.height ?? 1080
            var targetFrame = info.bounds
            let appKitY = primaryScreenHeight - targetFrame.origin.y - targetFrame.height
            targetFrame.origin.y = appKitY

            let centerAK = CGPoint(x: targetFrame.midX, y: targetFrame.midY)
            let targetScreen = ScreenLocator.screenContainingAppKit(point: centerAK) ?? NSScreen.main ?? NSScreen()

            FocusPreviewMaskController.shared.fadeInProgressively(progress: progress, on: targetScreen)
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

        // ⭐️ 方案二兜底：peek 触发时确保遮罩渐进到完全显示
        if SettingsManager.shared.enableFocusPreview {
            if let bundleId = manager.currentAppBundleId,
               let info = WindowThumbnailService.shared.getWindows(for: bundleId).first(where: { $0.windowId == windowId }) {
                let primaryScreenHeight = NSScreen.screens.first?.frame.height ?? 1080
                var targetFrame = info.bounds
                let appKitY = primaryScreenHeight - targetFrame.origin.y - targetFrame.height
                targetFrame.origin.y = appKitY
                let centerAK = CGPoint(x: targetFrame.midX, y: targetFrame.midY)
                let targetScreen = ScreenLocator.screenContainingAppKit(point: centerAK) ?? NSScreen.main ?? NSScreen()
                FocusPreviewMaskController.shared.fadeInProgressively(progress: 1.0, on: targetScreen)
            }
        }
        
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
        
        // ⭐️ 聚焦预览：与大图同步淡出（动画时长一致，视觉同节奏）
        FocusPreviewMaskController.shared.hide(animated: true)
        
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
            // ⭐️ 聚焦预览：随大图一同消失（动画淡出，避免突兀）
            FocusPreviewMaskController.shared.hide(animated: true)
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

        // ⭐️ 「聚焦预览」遮罩：在显示大图前/同时铺设全屏毛玻璃，并在截图所在位置挖洞
        // 仅当用户开启了 enableFocusPreview 才生效；遮罩 level 比 .floating 低 1，
        // 保证大图始终浮在毛玻璃之上。
        if settings.enableFocusPreview {
            // 选择截图主要落在的那块屏幕（用截图中心点定位，避免出界时误判）
            let centerAK = CGPoint(x: targetFrame.midX, y: targetFrame.midY)
            let targetScreen = ScreenLocator.screenContainingAppKit(point: centerAK)
                ?? screen
            FocusPreviewMaskController.shared.update(
                holeRectInAppKit: targetFrame,
                on: targetScreen
            )
        } else {
            // 用户已关闭聚焦预览：保险起见隐藏一下，覆盖运行时切换的边缘场景
            FocusPreviewMaskController.shared.hide(animated: false)
        }


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
        
        // ⭐️ 「聚焦预览」配套：给截图加 12pt 圆角，避免方角矩形浮在毛玻璃上视觉突兀。
        //   - 仅在 enableFocusPreview 开启时生效（普通预览维持原样，避免对正常透视引入视觉变化）
        //   - 12pt 与 macOS Big Sur+ 标准窗口外圆角一致，对绝大多数 App 视觉自然贴合
        //   - 用 wantsLayer + cornerRadius，AppKit 会自动裁切 NSImageView 渲染的图像
        if settings.enableFocusPreview {
            imageView.wantsLayer = true
            imageView.layer?.cornerRadius = 12
            imageView.layer?.masksToBounds = true
            if #available(macOS 10.15, *) {
                imageView.layer?.cornerCurve = .continuous   // 苹果"超椭圆"圆角，更接近系统窗口
            }
        } else {
            // 关闭聚焦预览时确保不残留圆角（窗口可能被复用）
            imageView.layer?.cornerRadius = 0
            imageView.layer?.masksToBounds = false
        }
        
        window.contentView = imageView
        log.log("🖼 Image size (Point): \(displayImage.size) set to Content View")
        
        if !window.isVisible {
            window.alphaValue = 0
            window.orderFront(nil)
            window.animator().alphaValue = 1
        }
        
        // ⭐️ 兜底 watchdog：5 秒后无论如何都强制关闭大图
        // 防御任何时序异常导致大图遗留在桌面（用户必须强制退出 App 才能消失）
        // 实际正常使用中，鼠标移开/点击/隐藏等所有正常路径都会更早地关闭大图，
        // 这只是最后一道保险。
        largePreviewWatchdog?.cancel()
        let watchdog = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            // 只有大图还可见时才触发强制隐藏，避免误关闭
            if self.largePreviewWindow?.isVisible == true {
                self.log.log("⏰ Large preview watchdog fired (\(self.largePreviewMaxLifetime)s elapsed), forcing close")
                self.forceHideLargePreview()
            }
        }
        largePreviewWatchdog = watchdog
        DispatchQueue.main.asyncAfter(deadline: .now() + largePreviewMaxLifetime, execute: watchdog)
    }
}
