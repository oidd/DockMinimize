//
//  LargePreviewView.swift
//  DockMinimize
//
//  屏幕中央大图预览视图
//

import SwiftUI

struct LargePreviewView: View {
    let image: NSImage
    let title: String
    let icon: NSImage?
    
    // 是否是低清预览图
    var isLowRes: Bool = false
    
    // ⭐️ 强制原位模式：无背景、无标题、纯图片
    var forceOriginalMode: Bool = false
    
    var body: some View {
        if forceOriginalMode {
            // 原位模式：极简渲染
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit) // 保持比例填充 Window (Window Frame 已设置为 exact bounds)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // 原位模式不需要额外的圆角裁剪，因为系统截图已经包含了窗口圆角（或透明区域）
                // 也不需要太重的阴影，因为截图里可能自带了系统阴影
                // 加一点点阴影防止截图里的阴影被裁减或者不明显
                .shadow(color: .black.opacity(0.2), radius: 10, x: 0, y: 5)
        } else {
            // 默认模式：居中大图 + 背景遮罩 + 标题栏
            ZStack {
                // 全屏背景
                Color.black.opacity(0.6)
                    .edgesIgnoringSafeArea(.all)
                
                VStack(spacing: 20) {
                    // 窗口截图
                    GeometryReader { geometry in
                        ZStack(alignment: .center) {
                            Image(nsImage: image)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(maxWidth: 650, maxHeight: 500)
                                .cornerRadius(12)
                                .shadow(color: .black.opacity(0.5), radius: 30, x: 0, y: 15)
                                .blur(radius: isLowRes ? 5 : 0)
                                .animation(.easeInOut(duration: 0.2), value: isLowRes)
                                
                            if isLowRes {
                                ProgressView()
                                    .scaleEffect(1.5)
                                    .colorScheme(.dark)
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    
                    // 下方信息条
                    HStack(spacing: 10) {
                        if let icon = icon {
                            Image(nsImage: icon)
                                .resizable()
                                .frame(width: 32, height: 32)
                        }
                        
                        Text(title)
                            .font(.system(size: 16, weight: .medium))
                            .foregroundColor(.white)
                            .shadow(radius: 2)
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
                    .background(VisualEffectView(material: .hudWindow, blendingMode: .withinWindow))
                    .cornerRadius(24)
                    .shadow(radius: 10)
                    .padding(.bottom, 40)
                }
            }
        }
    }
}
