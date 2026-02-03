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
            // 原生 Liquid Glass 材质背景 (底层安全加固版)
            LiquidGlassView()
                .clipShape(RoundedRectangle(cornerRadius: 16))
            
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
                                }
                            )
                            .id(window.windowId)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
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
        .frame(height: 180)
        .frame(maxWidth: viewModel.maxWidth)
        .onAppear {
            viewModel.onAppear()
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
    var body: some View {
        ZStack {
            // 底层：材质 17 (System Dark)
            VisualEffectVariantView(variantID: 17, alpha: 0.65)
            
            // 顶层：材质 19 (Liquid Glass)
            VisualEffectVariantView(variantID: 19, alpha: 1.0)
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
    
    /// 用于触发上抬动画
    @Published var bumpTriggers: [CGWindowID: Date] = [:]
    
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
            
            let shouldMinimize = (action == "toggle")
            
            // 批量应用状态
            for i in 0..<self.windows.count {
                var window = self.windows[i]
                let wasHidden = window.isMinimized
                
                // 设置新状态
                window.isMinimized = shouldMinimize
                
                // 触发动画
                if !shouldMinimize {
                    // 如果是变显示 (Blue)
                    if !wasHidden {
                        // 之前就是显示的 -> 触发上抬 (Bump)
                        self.bumpTriggers[window.windowId] = Date()
                        self.log.log("⚡️ Dock Click: Bumping window \(window.windowId)")
                    } else {
                        // 之前是隐藏的 -> 伸展 (Expand) - 无需额外 Trigger，isMinimized 变化自带动画
                        self.log.log("⚡️ Dock Click: Expanding window \(window.windowId)")
                    }
                } else {
                    self.log.log("⚡️ Dock Click: Shrinking window \(window.windowId)")
                }
                
                self.windows[i] = window
            }
            
            // 稍后刷新缩略图确保 UI 同步
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                self.refreshThumbnails(forceRefresh: true)
            }
        }
    }
    
    func loadWindows(for bundleId: String) {
        currentBundleId = bundleId
        currentApp = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first
        
        let newWindows = thumbnailService.getWindows(for: bundleId)
        // 只有窗口列表真的变了才重刷，防止滚动中重置
        if newWindows.count != windows.count || newWindows.map({$0.windowId}) != windows.map({$0.windowId}) {
            windows = newWindows
            refreshThumbnails(forceRefresh: true)
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
    
    func isWindowActive(_ windowId: CGWindowID) -> Bool { stateManager.isWindowActive(windowId) }
    
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
