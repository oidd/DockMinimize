//
//  FocusPreviewMaskController.swift
//  DockMinimize
//
//  「聚焦预览」全屏遮罩控制器（v2 简化版）
//
//  设计：
//    1. 本控制器在「截图所在的那一块屏幕」上覆盖一层全屏毛玻璃 + 半透明色调
//    2. 截图（largePreviewWindow，level=.floating）以更高 level 浮在毛玻璃之上
//       截图自身在 PreviewBarController 中已加 12pt 圆角（layer.cornerRadius）
//
//  ⭐️ 重构说明（v2，遮罩不再挖洞）：
//    旧实现：用 CAShapeLayer + evenOdd 在毛玻璃上"挖一个洞"，让真实窗口像素穿透。
//      问题：每个 App 的窗口圆角不同（10/12/不规则），洞的圆角永远难以完美适配，
//      会在洞边露出窗口圆角外的小三角灰色色块。
//    新实现：毛玻璃整屏覆盖，截图直接作为带圆角的位图浮在最上层。
//      - 不再依赖窗口真实圆角，所有 App 视觉一致。
//      - 实现更简单：本控制器只是一块半透明毛玻璃，不需要 mask 路径。
//
//  关键点：
//    - 遮罩窗口 level = .floating - 1，永远低于 largePreviewWindow，让大图浮在上面
//    - 遮罩颜色随系统外观自适应：浅色模式偏白半透明，深色模式更深
//    - ignoresMouseEvents = true，绝不能拦截 hover/点击事件
//    - 仅覆盖截图所在屏幕，副屏保持原样
//    - 所有显示/更新/隐藏均带淡入淡出动画
//

import Cocoa

final class FocusPreviewMaskController {
    static let shared = FocusPreviewMaskController()
    
    private let log = DebugLogger.shared
    
    /// 遮罩窗口（每个 Controller 同时只持有一个，跨屏切换时直接重定位 + 重建 contentView）
    private var window: NSWindow?
    
    /// 遮罩自定义视图
    private var maskView: FocusMaskView?
    
    /// 当前遮罩所在屏幕（用于判断是否需要切屏重建）
    private weak var currentScreen: NSScreen?
    
    private init() {}
    
    // MARK: - Public API
    
    /// 显示遮罩
    /// - Parameter screen: 截图所在的屏幕（遮罩仅覆盖该屏幕）
    ///
    /// 注：v2 起遮罩不再需要挖洞参数 holeRect，毛玻璃整屏覆盖即可。
    /// 为了保持调用方语义清晰、并兼容旧的多屏定位逻辑，仍保留 screen 参数。
    func show(on screen: NSScreen) {
        ensureWindowAndView(on: screen)
        guard let window = window else { return }
        
        if !window.isVisible {
            window.alphaValue = 0
            window.orderFront(nil)
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.18
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                window.animator().alphaValue = 1
            }
            log.log("🌫️ Focus mask shown on screen \(screen.localizedName)")
        } else if window.alphaValue < 1 {
            // 处于淡出途中再次被唤起：直接淡回去，避免黑屏闪烁
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.12
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                window.animator().alphaValue = 1
            }
        }
    }

    /// ⭐️ 聚焦预览优化（方案二）：渐进式淡入遮罩
    /// - Parameters:
    ///   - progress: 0.0 ~ 1.0，遮罩目标透明度
    ///   - screen: 遮罩所在屏幕
    ///
    /// 与 show() 不同：此方法允许部分透明度，用于在 peek timer 期间逐步显示遮罩。
    /// 调用频率可达 60fps，每次调用都通过极短动画平滑过渡。
    func fadeInProgressively(progress: CGFloat, on screen: NSScreen) {
        let clamped = min(max(progress, 0), 1)

        ensureWindowAndView(on: screen)
        guard let window = window else { return }

        if !window.isVisible && clamped > 0 {
            window.alphaValue = 0
            window.orderFront(nil)
        }

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.05
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            window.animator().alphaValue = clamped
        }
    }

    /// 更新遮罩位置 / 触发显示。
    ///
    /// ⭐️ v2 起遮罩不再依赖 holeRect 挖洞，holeRectInAppKit 仅用来判断目标屏幕。
    /// 保留此方法签名是为了兼容已有调用方（PreviewBarController.showLargePreview）。
    ///
    /// 行为：
    ///   - 跨屏切换：销毁旧窗口、在新屏上重建并淡入。
    ///   - 同屏：若窗口当前不可见或正在淡出，重新触发淡入；否则保持现状。
    func update(holeRectInAppKit: NSRect, on screen: NSScreen) {
        // 跨屏切换：直接重建（罕见）
        if currentScreen !== screen {
            hide(animated: false)
            show(on: screen)
            return
        }
        
        guard let window = window else {
            show(on: screen)
            return
        }
        
        // 窗口处于不可见或淡出中：重新淡入
        if !window.isVisible || window.alphaValue < 1 {
            show(on: screen)
            return
        }
        
        // 同屏 + 已可见：什么都不用做（毛玻璃不需要随窗口挪动）
    }
    
    /// 隐藏遮罩
    func hide(animated: Bool = true) {
        guard let window = window, window.isVisible else { return }
        
        if !animated {
            window.orderOut(nil)
            log.log("🌫️ Focus mask hidden (immediate)")
            return
        }
        
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            guard let self else { return }
            // 只有当 alpha 仍为 0 时才真正 orderOut，避免被新一轮 show 中途覆盖
            if let w = self.window, w.alphaValue == 0 {
                w.orderOut(nil)
            }
        }
        log.log("🌫️ Focus mask fading out")
    }
    
    // MARK: - Private
    
    private func ensureWindowAndView(on screen: NSScreen) {
        // 跨屏切换：旧窗口直接销毁重建（多显示器很少跨屏 peek，简单可靠）
        if let existingWindow = window, currentScreen !== screen {
            existingWindow.orderOut(nil)
            existingWindow.contentView = nil
            self.window = nil
            self.maskView = nil
        }
        
        if window == nil {
            let frame = screen.frame
            let w = NSWindow(
                contentRect: frame,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            w.isOpaque = false
            w.backgroundColor = .clear
            w.hasShadow = false
            w.ignoresMouseEvents = true
            w.isReleasedWhenClosed = false
            // 永远低于 largePreviewWindow（.floating），让截图浮在遮罩之上
            w.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue - 1)
            // 多桌面 / 全屏 App 兼容
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
            w.alphaValue = 0
            
            let view = FocusMaskView(frame: NSRect(origin: .zero, size: frame.size))
            w.contentView = view
            
            self.window = w
            self.maskView = view
            self.currentScreen = screen
        } else {
            // 同屏复用：保证 frame 跟随屏幕（Spaces / 分辨率变化时）
            let frame = screen.frame
            window?.setFrame(frame, display: false)
            maskView?.frame = NSRect(origin: .zero, size: frame.size)
        }
    }
}

// MARK: - FocusMaskView

/// 全屏毛玻璃遮罩视图（v2 简化版，不再挖洞）。
///
/// 结构：
/// - 底层：NSVisualEffectView（系统级毛玻璃，跟随系统外观）
/// - 上层：CALayer 半透明色调（浅色模式：白；深色模式：黑），让聚焦感更强
///
/// 截图浮在更高 level 的窗口（largePreviewWindow）中，自身已自带圆角，
/// 无需在本视图中做 mask 路径。
private final class FocusMaskView: NSView {
    /// 毛玻璃层（系统级，跟随外观）
    private let blurView: NSVisualEffectView = {
        let v = NSVisualEffectView()
        v.material = .fullScreenUI
        v.blendingMode = .behindWindow
        v.state = .active
        v.autoresizingMask = [.width, .height]
        return v
    }()
    
    /// 上层色调叠加（让聚焦感更强）
    private let tintLayer = CALayer()
    
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }
    
    private func setup() {
        wantsLayer = true
        autoresizingMask = [.width, .height]
        
        // 底层：毛玻璃
        addSubview(blurView)
        blurView.frame = bounds
        
        // 上层：色调（CALayer 直接挂在 self.layer 上）
        tintLayer.frame = bounds
        tintLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        layer?.addSublayer(tintLayer)
        
        applyTintColor()
    }
    
    override func layout() {
        super.layout()
        blurView.frame = bounds
        tintLayer.frame = bounds
    }
    
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTintColor()
    }
    
    /// 根据系统外观应用色调：
    /// - 浅色模式：白色，opacity = 0.30（保持轻盈，避免过度压暗内容）
    /// - 深色模式：黑色，opacity = 0.55（更深，让聚焦感更强）
    private func applyTintColor() {
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .vibrantDark, .aqua]) == .darkAqua
            || effectiveAppearance.bestMatch(from: [.darkAqua, .vibrantDark, .aqua]) == .vibrantDark
        
        // 关闭隐式动画，避免外观切换时闪烁
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if isDark {
            tintLayer.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        } else {
            tintLayer.backgroundColor = NSColor.white.withAlphaComponent(0.30).cgColor
        }
        CATransaction.commit()
    }
}
