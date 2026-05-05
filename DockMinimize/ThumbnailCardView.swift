//
//  ThumbnailCardView.swift
//  DockMinimize
//
//  单个缩略图卡片视图
//

import SwiftUI

struct ThumbnailCardView: View {
    let windowInfo: WindowThumbnailService.WindowInfo
    let thumbnail: NSImage?
    let isActive: Bool
    let isHovered: Bool
    // ⭐️ 新增：动画触发器
    var bumpTrigger: Date? = nil
    
    let onClick: () -> Void
    let onHover: (Bool) -> Void
    let onClose: () -> Void
    
    /// 缩略图尺寸
    /// ⭐️ 在 HEAD 基础上放大 +12.5%：160→180，100→110（10 的倍数，避免亚像素边界引发的渲染问题）
    /// 容器高度同步从 180 → 200（在 PreviewBarView .frame 与 PreviewBarController.calculateWindowSize 中），
    /// 保持整个卡片布局是 HEAD 的等比例放大，不引入相对位置变化，最大程度避免 SwiftUI 渲染 bug。
    private let thumbnailWidth: CGFloat = 180
    private let thumbnailHeight: CGFloat = 110
    
    @State private var isBumping: Bool = false
    
    /// ⭐️ 跟随系统外观的标题颜色：
    /// - 深色模式：白色（90% 不透明度），保持原视觉效果
    /// - 浅色模式：浅灰色，避免在浅色 Liquid Glass 背景上看不清
    @Environment(\.colorScheme) private var colorScheme
    private var adaptiveTitleColor: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.9)
            : Color(nsColor: .secondaryLabelColor)
    }
    
    var body: some View {
        VStack(spacing: 6) {
            // 窗口标题
            // ⭐️ 跟随系统主题：浅色模式下使用浅灰色，深色模式下保持白色，避免在浅色背景上看不清
            Text(windowInfo.title.isEmpty ? windowInfo.ownerName : windowInfo.title)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(adaptiveTitleColor)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: thumbnailWidth)
            
            // 缩略图
            ZStack {
                // 背景
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.black.opacity(0.3))
                    .frame(width: thumbnailWidth, height: thumbnailHeight)
                
                // 缩略图内容
                if let thumbnail = thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: thumbnailWidth, height: thumbnailHeight)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                } else {
                    // 占位符
                    Image(systemName: "rectangle.on.rectangle")
                        .font(.system(size: 32))
                }
                
                // ⭐️ 新增：一键关闭按钮
                // 仅在鼠标悬浮时出现
                if isHovered {
                    VStack {
                        HStack {
                            Spacer()
                            Button(action: {
                                onClose()
                            }) {
                                ZStack {
                                    Circle()
                                        .fill(Color.gray.opacity(0.8))
                                        .frame(width: 20, height: 20)
                                    
                                    Image(systemName: "xmark")
                                        .font(.system(size: 10, weight: .bold))
                                        .foregroundColor(.white)
                                }
                            }
                            .buttonStyle(PlainButtonStyle())
                            // ⭐️ padding 6 → 8：让关闭按钮离缩略图边缘稍远一些，
                            //    hover 时整体 scale 放大也不会显得"跑出"图片范围
                            .padding([.top, .trailing], 8)
                        }
                        Spacer()
                    }
                }
            }
            // ⭐️ hover 动画优化：
            // 1) .frame 在 scaleEffect 之前：锁定 ZStack 的布局尺寸为 thumbnailWidth×thumbnailHeight
            //    这样缩放只是"视觉鼓胀"，不会推动 VStack 上下的标题/指示条
            // 2) scale 1.04 → 1.03：更克制的反馈
            // 3) anchor: .center：从中心点缩放，避免视觉上向某方向位移
            // 4) dampingFraction 0.72 → 0.85：减少弹簧过冲/回弹，动画更稳定平滑
            .frame(width: thumbnailWidth, height: thumbnailHeight)
            .scaleEffect(isHovered ? 1.03 : 1.0, anchor: .center)
            .animation(.spring(response: 0.32, dampingFraction: 0.85), value: isHovered)
            .shadow(color: .black.opacity(isHovered ? 0.4 : 0.2), radius: isHovered ? 10 : 5)
            
            // ⭐️ Peek 状态指示条 (仿 Windows 风格)
            // 隐藏状态：短灰条
            // 显示状态：长蓝条
            Capsule()
                .fill(windowInfo.isMinimized ? Color.secondary.opacity(0.5) : Color(nsColor: .controlAccentColor))
                .opacity(windowInfo.isMinimized ? 1.0 : (isActive ? 1.0 : 0.5)) // ⭐️ 非活跃显示窗口设置为 50% 透明度
                .frame(width: windowInfo.isMinimized ? 16 : 42, height: 4)
                .offset(y: isBumping ? -8 : 0) // ⭐️ 上抬动画
                .animation(.spring(response: 0.3, dampingFraction: 0.6), value: isBumping) // 弹性动画
                .animation(.spring(response: 0.3, dampingFraction: 0.7), value: windowInfo.isMinimized)
                .animation(.easeInOut(duration: 0.2), value: isActive) // ⭐️ 透明度平滑切换
                .padding(.top, 2)
                .onChange(of: bumpTrigger) { _ in
                    // 触发上抬 -> 下落动画
                    isBumping = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        isBumping = false
                    }
                }
        }
        .padding(.horizontal, 8)
        // ⭐️ 卡片上下 padding 6 → 2：进一步压缩。标题/指示条这一行本身有半行天然留白，
        // 此处再放过多 padding 会让上下视觉留白比左右明显大；2pt 仅作为 hover 放大的安全余量
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        // ⭐️ 核心修复：使用 DragGesture(minimumDistance: 0) 替代 onTapGesture
        // 这样即使鼠标在点击过程中发生了移动（在 bounds 范围内），也能正确识别为点击
        // 解决了“移动中点击失效”的问题
        .gesture(
            DragGesture(minimumDistance: 0)
                .onEnded { value in
                    // 简单的判定：如果释放点还在视图范围内（允许少量溢出容差），就认为是点击
                    // 这里的 value.location 是相对于视图左上角的
                    // 缩略图宽度约 176 (160+16padding)，高度约 150
                    // 我们给一个宽松的判定区域
                    let x = value.location.x
                    let y = value.location.y
                    
                    // 容差 20px
                    if x > -20 && x < 200 && y > -20 && y < 180 {
                        onClick()
                    }
                }
        )
        .onHover { hovering in
            onHover(hovering)
        }
    }
}

// MARK: - Preview

#if DEBUG
struct ThumbnailCardView_Previews: PreviewProvider {
    static var previews: some View {
        // 创建一个 dummy AXUIElement 用于预览
        let dummyAppElement = AXUIElementCreateApplication(getpid())
        let windowInfo = WindowThumbnailService.WindowInfo(
            windowId: 1,
            title: "Google - 首页",
            ownerPID: getpid(),
            ownerName: "Google Chrome",
            bounds: .zero,
            axElement: dummyAppElement,
            appAxElement: dummyAppElement
        )
        
        HStack {
            ThumbnailCardView(
                windowInfo: windowInfo,
                thumbnail: nil,
                isActive: false,
                isHovered: false,
                onClick: {},
                onHover: { _ in },
                onClose: {}
            )
            
            ThumbnailCardView(
                windowInfo: windowInfo,
                thumbnail: nil,
                isActive: true,
                isHovered: true,
                onClick: {},
                onHover: { _ in },
                onClose: {}
            )
        }
        .padding()
        .background(Color.black.opacity(0.5))
    }
}
#endif
