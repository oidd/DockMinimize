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
    
    /// 缩略图尺寸
    private let thumbnailWidth: CGFloat = 160
    private let thumbnailHeight: CGFloat = 100
    
    @State private var isBumping: Bool = false
    
    var body: some View {
        VStack(spacing: 6) {
            // 窗口标题
            Text(windowInfo.title.isEmpty ? windowInfo.ownerName : windowInfo.title)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.white.opacity(0.9))
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
            }
            .scaleEffect(isHovered ? 1.05 : 1.0)
            .shadow(color: .black.opacity(isHovered ? 0.4 : 0.2), radius: isHovered ? 10 : 5)
            .animation(.easeInOut(duration: 0.15), value: isHovered)
            
            // ⭐️ Peek 状态指示条 (仿 Windows 风格)
            // 隐藏状态：短灰条
            // 显示状态：长蓝条
            Capsule()
                .fill(windowInfo.isMinimized ? Color.secondary.opacity(0.5) : Color(nsColor: .controlAccentColor))
                .frame(width: windowInfo.isMinimized ? 16 : 42, height: 4)
                .offset(y: isBumping ? -8 : 0) // ⭐️ 上抬动画
                .animation(.spring(response: 0.3, dampingFraction: 0.6), value: isBumping) // 弹性动画
                .animation(.spring(response: 0.3, dampingFraction: 0.7), value: windowInfo.isMinimized)
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
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .onTapGesture {
            onClick()
        }
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
                onHover: { _ in }
            )
            
            ThumbnailCardView(
                windowInfo: windowInfo,
                thumbnail: nil,
                isActive: true,
                isHovered: true,
                onClick: {},
                onHover: { _ in }
            )
        }
        .padding()
        .background(Color.black.opacity(0.5))
    }
}
#endif
