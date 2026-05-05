//
//  PreviewBarView.swift
//  DockMinimize
//
//  预览条主容器视图
//

import SwiftUI

struct PreviewBarView: View {
    @ObservedObject var viewModel: PreviewBarViewModel
    
    /// 渐变遮罩宽度
    private let fadeMaskWidth: CGFloat = 40
    
    var body: some View {
        ZStack {
            // 背景：
            // - macOS 26+（Tahoe）：使用 SwiftUI 原生 .glassEffect() 实现真·液态玻璃
            // - 旧系统：回退到 NSVisualEffectView 自定义磨砂玻璃（LiquidGlassView）
            backgroundLayer
            
            // 水平滚动视图
            ScrollViewReader { scrollProxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(viewModel.windows) { window in
                            ThumbnailCardView(
                                windowInfo: window,
                                thumbnail: viewModel.thumbnails[window.windowId],
                                isActive: viewModel.isWindowActive(window.windowId),
                                isHovered: viewModel.hoveredWindowId == window.windowId,
                                bumpTrigger: viewModel.bumpTriggers[window.windowId],
                                onClick: {
                                    viewModel.clickWindow(window)
                                },
                                onHover: { isHovered in
                                    viewModel.hoverWindow(window, isHovered: isHovered)
                                },
                                onClose: {
                                    viewModel.closeWindow(window)
                                }
                            )
                            .id(window.windowId)
                        }
                    }
                    // ⭐️ 缩小外层留白，让中央截图视觉占比更大、整体小窗更紧凑
                    .padding(.horizontal, 10)
                    // ⭐️ 上下 padding 6 → 2：标题/指示条本行已含天然留白，再加 padding 会显得上下偏多
                    .padding(.vertical, 2)
                }
                .coordinateSpace(name: "scroll")
                .overlay(
                    // ⭐️ 全局滚动捕捉层（透传点击，仅收割滚轮）
                    ScrollGestureHandler { delta in
                        viewModel.handleManualScroll(delta: delta)
                    }
                )
                .onChange(of: viewModel.scrollTargetId) { targetId in
                    if let id = targetId {
                        withAnimation {
                            scrollProxy.scrollTo(id, anchor: .center)
                        }
                    }
                }
            }
            
            // 边缘渐变遮罩 (优化后的视觉效果：更通透、非阴影感)
            HStack(spacing: 0) {
                // 左侧渐变
                if viewModel.canScrollLeft {
                    LinearGradient(
                        gradient: Gradient(colors: [
                            Color.black.opacity(0.15),
                            Color.black.opacity(0.05),
                            Color.clear
                        ]),
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: fadeMaskWidth)
                    .allowsHitTesting(false)
                }
                
                Spacer(minLength: 0)
                
                // 右侧渐变
                if viewModel.canScrollRight {
                    LinearGradient(
                        gradient: Gradient(colors: [
                            Color.clear,
                            Color.black.opacity(0.05),
                            Color.black.opacity(0.15)
                        ]),
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: fadeMaskWidth)
                    .allowsHitTesting(false)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 16))
        }
        // ⭐️ 容器高度 182 → 166：进一步压缩上下两层 vertical padding（卡片 6→2、外层 6→2，共 -16pt）
        //    与 PreviewBarController.calculateWindowSize 中的 height 保持同步
        .frame(height: 166)
        .frame(maxWidth: viewModel.maxWidth)
        .onAppear {
            viewModel.onAppear()
        }
    }
    
    /// 背景层：在 macOS 26+（Tahoe）上使用 SwiftUI 原生 .glassEffect()，
    /// 在更早的系统上回退到自定义的 NSVisualEffectView 磨砂玻璃。
    ///
    /// ⭐️ 因为 NSWindow 会裁切 frame 之外的内容，传统的 .shadow（外发光）会被切掉。
    ///    所以这里改用"内发光描边"方案：
    ///    在玻璃层之上覆盖一个圆角矩形描边，stroke 颜色按外观自适应，
    ///    再用 .blur(radius:) 让描边渐变模糊，营造温柔的内辉光效果。
    ///    描边完全在小窗轮廓内侧（不超出 frame），永远不会被裁断。
    @ViewBuilder
    private var backgroundLayer: some View {
        let glassShape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        
        ZStack {
            // 1) 真正的玻璃层
            if #available(macOS 26.0, *) {
                // macOS 26+: 真·液态玻璃。
                // 用一个透明形状承载 .glassEffect，由系统去渲染液态玻璃材质（含动态高光、折射）。
                // .regular 在浅色/深色模式下系统会自动调色，无需我们再做适配，也不会有"灰色描边"。
                Color.clear
                    .glassEffect(.regular, in: glassShape)
            } else {
                // macOS 13 ~ 15：使用现有的自定义 LiquidGlassView（NSVisualEffectView 磨砂玻璃）
                LiquidGlassView()
                    .clipShape(glassShape)
            }
            
            // 2) ⭐️ 内发光描边层：紧贴小窗轮廓内侧的一圈柔和辉光。
            //    - 描边线本身用 LinearGradient 上浅下深，模拟自然光照
            //    - 然后整个描边再裁剪到圆角矩形内（避免线宽外溢出去再被 NSWindow 裁掉）
            //    - 不使用 .blur，避免破坏 .glassEffect 的折射效果
            glassShape
                .strokeBorder(haloStroke, lineWidth: 1)
                // 用形状本身遮罩，确保描边即使有亚像素抗锯齿溢出，
                // 也不会跑到圆角外形成方角
                .allowsHitTesting(false)
        }
    }
    
    // MARK: - 自适应光晕配色
    
    @Environment(\.colorScheme) private var colorScheme
    
    /// 内发光描边：上→下渐变，贴合自然光从上方打下来的视觉习惯。
    /// 整体不透明度调淡：让光晕只是若隐若现的"质感细节"，不抢焦点。
    private var haloStroke: LinearGradient {
        if colorScheme == .dark {
            // 深色模式：上方淡白高光（小窗"边缘亮起来"），下方更弱
            return LinearGradient(
                colors: [
                    Color.white.opacity(0.16),
                    Color.white.opacity(0.06),
                    Color.white.opacity(0.02)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        } else {
            // 浅色模式：上方淡灰高光，下方更深一点 → 与白底产生区隔但仍温柔
            return LinearGradient(
                colors: [
                    Color.black.opacity(0.06),
                    Color.black.opacity(0.035),
                    Color.black.opacity(0.02)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }
}

// MARK: - 滚轮事件处理器
struct ScrollGestureHandler: NSViewRepresentable {
    var onScroll: (CGFloat) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = ScrollTrackingView()
        view.onScroll = onScroll
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    class ScrollTrackingView: NSView {
        var onScroll: ((CGFloat) -> Void)?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window = self.window {
                // ⭐️ 使用 Local Monitor 在本窗口范围内全局捕捉滚轮
                // 这样我们可以让 hitTest 返回 nil（透传点击），但依然能“闻到”滚轮事件
                monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel]) { [weak self] event in
                    guard let self = self, self.window == window else { return event }
                    
                    // 检查鼠标是否在当前视图范围内
                    let point = self.convert(event.locationInWindow, from: nil)
                    if self.bounds.contains(point) {
                        let delta = event.scrollingDeltaX == 0 ? event.scrollingDeltaY : event.scrollingDeltaX
                        self.onScroll?(delta)
                        return nil // 拦截事件，防止 ScrollView 产生不必要的原生干扰
                    }
                    return event
                }
            } else {
                if let monitor = monitor {
                    NSEvent.removeMonitor(monitor)
                    self.monitor = nil
                }
            }
        }

        // 核心：永远返回 nil，确保缩略图的点击、悬停（onHover）都能正常接收
        override func hitTest(_ point: NSPoint) -> NSView? {
            return nil
        }
    }
}

// MARK: - Liquid Glass Implementation (Safe Unsafe Version)

struct LiquidGlassView: View {
    /// ⭐️ 跟随系统外观自适应：
    /// - 深色模式：保持原 (17 + 19) 双层叠加，视觉效果不变
    /// - 浅色模式：大幅降低顶层 Liquid Glass (19) 的不透明度（甚至关闭底层 17），
    ///   削弱它在浅色背景下边缘的灰色描边/高光，让小窗轮廓更柔和、更"通透"
    @Environment(\.colorScheme) private var colorScheme
    
    var body: some View {
        ZStack {
            if colorScheme == .dark {
                // 深色模式：维持原视觉
                VisualEffectVariantView(variantID: 17, alpha: 0.65)
                VisualEffectVariantView(variantID: 19, alpha: 1.0)
            } else {
                // 浅色模式：
                // 1) 底层 17 (System Dark) 在浅色下会贡献一圈深灰描边，关掉
                // 2) 顶层 19 (Liquid Glass) 进一步降到 0.25，仅保留极淡的玻璃质感
                VisualEffectVariantView(variantID: 19, alpha: 0.25)
            }
        }
    }
}

/// 这是一个为了绕过 KVC 崩溃而设计的底层实现
struct VisualEffectVariantView: NSViewRepresentable {
    let variantID: Int
    let alpha: CGFloat
    
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = .behindWindow
        view.state = .active
        
        // --- 核心修复：绕过 KVC 崩溃 ---
        // 之前使用 setValue(NSNumber(value: variantID), forKey: "_variant") 会触发 NSUnknownKeyException 导致崩溃
        // 现在使用 unsafeBitCast 将整数直接强转为 material，直接写入内存枚举
        // 这种方式不经过 KVC 的 key 检查，极其稳定
        let material = unsafeBitCast(variantID, to: NSVisualEffectView.Material.self)
        view.material = material
        
        view.alphaValue = alpha
        return view
    }
    
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.alphaValue = alpha
    }
}

// MARK: - Visual Effect View (Standard)
struct VisualEffectView: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode
    
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }
    
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}

// MARK: - ViewModel & Infrastructure

struct ScrollViewOffsetPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

class PreviewBarViewModel: ObservableObject {
    @Published var windows: [WindowThumbnailService.WindowInfo] = []
    @Published var thumbnails: [CGWindowID: NSImage] = [:]
    @Published var hoveredWindowId: CGWindowID?
    @Published var canScrollLeft: Bool = false
    @Published var canScrollRight: Bool = false
    
    /// 用于通过 ScrollViewReader 控制偏移
    @Published var scrollTargetId: CGWindowID?
    
    /// ⭐️ 活跃窗口集合（用于驱动指示条透明度）
    @Published var activeWindowIds: Set<CGWindowID> = []
    
    /// 用于触发上抬动画
    @Published var bumpTriggers: [CGWindowID: Date] = [:]
    
    /// ⭐️ 用于观察窗口数量变化，通知 Controller 刷新 Frame
    @Published var lastWindowCount: Int = 0
    
    let log = DebugLogger.shared
    let thumbnailService = WindowThumbnailService.shared
    let stateManager: PreviewStateManager
    
    var currentApp: NSRunningApplication?
    var currentBundleId: String?
    
    var maxWidth: CGFloat { (NSScreen.main?.frame.width ?? 1200) * 0.95 }
    private var contentWidth: CGFloat = 0
    
    init(stateManager: PreviewStateManager) { 
        self.stateManager = stateManager
        setupDockClickObserver()
        setupWindowCloseObserver()
    }
    
    private func setupWindowCloseObserver() {
        NotificationCenter.default.addObserver(self, selector: #selector(handleWindowClose(_:)), name: NSNotification.Name("WindowDidClose"), object: nil)
    }
    
    @objc private func handleWindowClose(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let windowId = userInfo["windowId"] as? CGWindowID else { return }
        
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            // 从列表中移除关闭的窗口
            if let index = self.windows.firstIndex(where: { $0.windowId == windowId }) {
                self.log.log("🗑️ UI Sync: Window \(windowId) closed, removing from list")
                self.windows.remove(at: index)
                self.lastWindowCount = self.windows.count
                
                // 如果窗口列表变为空，通知管理器隐藏预览条
                if self.windows.isEmpty {
                    self.log.log("🗑️ All windows closed, hiding preview bar")
                    // 手动触发状态机退场
                    self.stateManager.hidePreview()
                }
                
                self.updateScrollIndicators()
            }
        }
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
    private func setupDockClickObserver() {
        NotificationCenter.default.addObserver(self, selector: #selector(handleDockClick(_:)), name: NSNotification.Name("DockIconClicked"), object: nil)
    }
    
    @objc private func handleDockClick(_ notification: Notification) {
        // 确保是当前预览的应用被点击
        guard let userInfo = notification.userInfo,
              let bundleId = userInfo["bundleId"] as? String,
              bundleId == currentBundleId,
              let action = userInfo["action"] as? String else { return }
        
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            // 预测逻辑：
            // Action "activate" -> 肯定是变显示 (Blue)
            // Action "toggle" -> 如果当前在前台，则是变隐藏 (Gray)；否则变显示
            
            // 注意：这里拿到的 frontmost 可能是旧的（点击瞬间），也可能是新的。
            // DockEventMonitor 发送通知是在调用 WindowManager 之前/同时也。
            // 所以此时的状态应该是“点击前”的状态。
            // DockEventMonitor 的逻辑是：
            // Case A (Frontmost): Toggle -> Minimize
            // Case B (Background): Ensure Visible -> Activate
            
            // 所以，如果 action 是 "toggle"，说明它判定为前台 -> 我们预测为 Minimize
            // 如果 action 是 "activate"，说明它判定为后台 -> 我们预测为 Activate
            
            let shouldMinimize: Bool
            if action == "activate" {
                // 背景切前台：意图肯定是 Restore/Activate (变为蓝色)
                shouldMinimize = false
            } else {
                // 当前已在前台：执行 Toggle
                if let first = self.windows.first {
                    shouldMinimize = !first.isMinimized
                } else {
                    shouldMinimize = false
                }
            }
            
            self.log.log("⚡️ UI Sync: Bundle=\(bundleId), Action=\(action), IdentifyingShouldMinimize=\(shouldMinimize)")

            // 1. 瞬间翻转所有指示条最小化状态
            for i in 0..<self.windows.count {
                var window = self.windows[i]
                window.isMinimized = shouldMinimize
                self.windows[i] = window
            }
            
            // 2. ⭐️ 核心修复：不要在循环中盲目 addActiveWindow（会导致所有条都亮蓝）
            // 如果是还原操作，在一段极短的延时后同步真实焦点，确保只有一个条是高亮的
            if !shouldMinimize {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    self.stateManager.syncFocusState(for: bundleId)
                }
            } else {
                // 如果是全部最小化，直接清空活跃状态
                self.stateManager.setSingleActiveWindow(nil)
            }
            
            // 3. ⭐️ 精准动画逻辑 (Bump)
            if action == "activate" {
                for window in self.windows {
                    if !window.isMinimized {
                        self.bumpTriggers[window.windowId] = Date()
                    }
                }
            }
            
            // 稍后刷新以补获最终稳定的缩略图
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.refreshThumbnails(forceRefresh: true)
            }
        }
    }
    
    func loadWindows(for bundleId: String) {
        currentBundleId = bundleId
        currentApp = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first
        
        // ⭐️ 同步加载元数据，确保 Controller 逻辑能立即看到窗口数量
        let newWindows = thumbnailService.getWindows(for: bundleId)
        
        // ⭐️ 状态比对逻辑
        let hasCountOrIdChange = newWindows.count != windows.count || 
                                 newWindows.map({$0.windowId}) != windows.map({$0.windowId})
        let hasStateChange = zip(newWindows, windows).contains { $0.0.isMinimized != $0.1.isMinimized }
        
        if hasCountOrIdChange || hasStateChange {
            windows = newWindows
            // 刷新缩略图 (内部已是异步或轻量检查)
            refreshThumbnails(forceRefresh: true)
            
            // ⭐️ 通知数量变化，触发外部布局刷新
            lastWindowCount = newWindows.count
            updateScrollIndicators()
        }
    }
    
    func refreshThumbnails(forceRefresh: Bool = false) {
        thumbnails = thumbnailService.captureAllThumbnails(for: windows, forceRefresh: forceRefresh)
    }
    
    func clickWindow(_ window: WindowThumbnailService.WindowInfo) {
        if !SettingsManager.shared.enableIndependentWindowControl { return }
        
        let wasHidden = window.isMinimized
        
        // 1. 先执行后端操作，并获取准确的结果 (True=Minimize, False=Activate)
        // 这一步是同步的，所以我们可以立即获得结果
        let didMinimize = stateManager.clickThumbnail(windowInfo: window)
        
        // 2. 根据准确结果更新 UI
        if let index = windows.firstIndex(where: { $0.windowId == window.windowId }) {
            var updatedInfo = windows[index]
            
            // 同步状态
            updatedInfo.isMinimized = didMinimize
            
            // 3. 决定动画类型
            if didMinimize {
                // A. 执行了最小化 -> 收缩动画 (Blue -> Gray)
                log.log("⚡️ UI Update: Minimized window \(window.windowId) (Shrink)")
            } else {
                // B. 执行了激活/置顶 -> 显示状态 (Blue)
                
                if wasHidden {
                    // B1. 之前是隐藏的 -> 伸展动画 (Gray -> Blue)
                    log.log("⚡️ UI Update: Unminimized window \(window.windowId) (Expand)")
                } else {
                    // B2. 之前就是显示的 -> 上抬动画 (Blue -> Blue + Bump)
                    bumpTriggers[window.windowId] = Date()
                    log.log("⚡️ UI Update: Bumping window \(window.windowId) (Lift Up)")
                }
            }
            
            windows[index] = updatedInfo
        }
        
        // 延时刷新以确保缩略图更新
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in 
            self?.refreshThumbnails(forceRefresh: true) 
        }
    }
    
    func closeWindow(_ window: WindowThumbnailService.WindowInfo) {
        log.log("🖱️ User clicked close button for window \(window.windowId)")
        WindowManager.shared.closeWindow(window)
    }
    
    func hoverWindow(_ window: WindowThumbnailService.WindowInfo, isHovered: Bool) {
        if isHovered {
            hoveredWindowId = window.windowId
            stateManager.hoverOnThumbnail(windowId: window.windowId)
        } else {
            if hoveredWindowId == window.windowId {
                hoveredWindowId = nil
                stateManager.exitThumbnail()
            }
        }
    }
    
    private var scrollAccumulator: CGFloat = 0
    private var lastScrollTime: Date = Date.distantPast

    /// 解决滚轮只动一次的问题：引入累积量机制和冷却控制
    func handleManualScroll(delta: CGFloat) {
        guard windows.count > 1 else { return }
        
        let now = Date()
        // 如果两次滚动间隔太久，重置累计值（防止下次操作时瞬间跳动）
        if now.timeIntervalSince(lastScrollTime) > 0.3 {
            scrollAccumulator = 0
        }
        
        scrollAccumulator += delta
        lastScrollTime = now
        
        let currentIndex = windows.firstIndex(where: { $0.windowId == scrollTargetId }) ?? 0
        
        // 当累积滑动量达到阈值（2.0）时，执行翻页
        if scrollAccumulator < -2.0 { // 向右扫 (滚轮向下)
            if currentIndex < windows.count - 1 {
                scrollTargetId = windows[currentIndex + 1].windowId
                scrollAccumulator = 0 // 翻页成功后清空，等待下次累积
            }
        } else if scrollAccumulator > 2.0 { // 向左扫 (滚轮向上)
            if currentIndex > 0 {
                scrollTargetId = windows[currentIndex - 1].windowId
                scrollAccumulator = 0
            }
        }
        
        // 关键：滚动后立即刷新遮罩状态
        DispatchQueue.main.async {
            self.updateScrollIndicators()
        }
    }
    
    func isWindowActive(_ windowId: CGWindowID) -> Bool { activeWindowIds.contains(windowId) }
    
    private func updateScrollIndicators() {
        // 使用实际窗口数量进行逻辑判定
        guard !windows.isEmpty else {
            canScrollLeft = false
            canScrollRight = false
            return
        }
        
        contentWidth = CGFloat(windows.count) * 180
        let viewWidth = maxWidth
        
        if contentWidth <= viewWidth {
            canScrollLeft = false
            canScrollRight = false
            return
        }
        
        // 判定：如果当前选中的 id 对应的索引不是 0，说明左边还有
        let currentIndex = windows.firstIndex(where: { $0.windowId == scrollTargetId }) ?? 0
        canScrollLeft = currentIndex > 0
        
        // 如果索引不是最后一个，说明右边还有
        canScrollRight = currentIndex < windows.count - 1
    }
    
    func onAppear() { 
        if let first = windows.first {
            scrollTargetId = first.windowId
        }
        updateScrollIndicators() 
    }
}

#if DEBUG
struct PreviewBarView_Previews: PreviewProvider {
    static var previews: some View {
        let stateManager = PreviewStateManager()
        let viewModel = PreviewBarViewModel(stateManager: stateManager)
        PreviewBarView(viewModel: viewModel)
            .frame(width: 800)
            .padding()
            .background(Color.gray)
    }
}
#endif
