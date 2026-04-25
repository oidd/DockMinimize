//
//  ScreenCaptureManager.swift
//  DockMinimize
//
//  屏幕录制权限管理
//

import Cocoa
import ScreenCaptureKit

class ScreenCaptureManager {
    static let shared = ScreenCaptureManager()
    
    private let log = DebugLogger.shared
    
    private init() {}
    
    /// 检查是否有屏幕录制权限
    func hasScreenCapturePermission() -> Bool {
        if #available(macOS 10.15, *) {
            // 使用系统推荐的 preflight 检查
            return CGPreflightScreenCaptureAccess()
        }
        
        // 兜底方案：尝试获取窗口列表名称
        guard let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else {
            return false
        }
        
        for windowInfo in windowList {
            if let windowName = windowInfo[kCGWindowName as String] as? String, !windowName.isEmpty {
                return true
            }
        }
        return false
    }
    
    /// 请求屏幕录制权限
    func requestPermission() {
        log.log("🔐 Requesting screen capture permission...")
        
        if #available(macOS 10.15, *) {
            // 直接调用系统 API 触发弹窗
            _ = CGRequestScreenCaptureAccess()
        } else {
            // 旧版方案：尝试执行需要权限的操作
            _ = CGWindowListCreateImage(
                CGRect(x: 0, y: 0, width: 1, height: 1),
                .optionOnScreenOnly,
                kCGNullWindowID,
                [.boundsIgnoreFraming]
            )
        }
        
        // 0.5秒后如果仍无权限，引导打开系统设置
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            if !(self?.hasScreenCapturePermission() ?? false) {
                self?.openPrivacySettings()
            }
        }
    }
    
    /// 打开系统偏好设置的隐私面板
    func openPrivacySettings() {
        log.log("📱 Opening Privacy Settings for Screen Recording...")
        
        // macOS 13+ 使用新的 URL scheme
        if #available(macOS 13.0, *) {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                NSWorkspace.shared.open(url)
            }
        } else {
            // macOS 12 使用旧的 URL scheme
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                NSWorkspace.shared.open(url)
            }
        }
    }
    /// 截取指定窗口的图像
    func captureWindow(windowId: CGWindowID, bounds: CGRect) -> NSImage? {
        guard hasScreenCapturePermission() else {
            log.log("❌ Cannot capture window: no permission")
            return nil
        }
        
        // 获取当前屏幕缩放系数
        let scale = NSScreen.main?.backingScaleFactor ?? 1.0
        
        // 使用 CGWindowListCreateImage 截取指定窗口
        guard let cgImage = CGWindowListCreateImage(
            bounds,
            .optionIncludingWindow,
            windowId,
            [.boundsIgnoreFraming, .bestResolution]
        ) else {
            log.log("⚠️ Failed to capture window \(windowId)")
            return nil
        }
        
        let size = NSSize(width: CGFloat(cgImage.width) / scale, height: CGFloat(cgImage.height) / scale)
        return NSImage(cgImage: cgImage, size: size)
    }
    
    /// 截取指定窗口（使用私有 API，支持最小化窗口）
    func captureWindow(windowId: CGWindowID) -> NSImage? {
        guard hasScreenCapturePermission() else {
            log.log("❌ Cannot capture window: no permission")
            return nil
        }
        
        // 使用 CGSHWCaptureWindowList 私有 API（参考 DockDoor 实现）
        // 优势：可以截取最小化窗口，避免 Stage Manager 干扰
        let connectionID = CGSMainConnectionID()
        var id = UInt32(windowId)
        
        // 获取当前屏幕缩放系数，用于将像素转换为 Point
        let scale = NSScreen.main?.backingScaleFactor ?? 1.0
        
        // 第一次尝试：最佳分辨率
        if let capturedWindows = CGSHWCaptureWindowList(
            connectionID,
            &id,
            1,
            [.ignoreGlobalClipShape, .bestResolution]
        ) as? [CGImage],
           let cgImage = capturedWindows.first {
            let size = NSSize(width: CGFloat(cgImage.width) / scale, height: CGFloat(cgImage.height) / scale)
            return NSImage(cgImage: cgImage, size: size)
        }
        
        // 第二次尝试：名义分辨率（有时对某些状态的窗口更有效）
        if let capturedWindows = CGSHWCaptureWindowList(
            connectionID,
            &id,
            1,
            [.ignoreGlobalClipShape, .nominalResolution]
        ) as? [CGImage],
           let cgImage = capturedWindows.first {
            let size = NSSize(width: CGFloat(cgImage.width) / scale, height: CGFloat(cgImage.height) / scale)
            return NSImage(cgImage: cgImage, size: size)
        }
        
        // 第三次尝试：仅忽略裁剪（最基础的私有 API 调用）
        if let capturedWindows = CGSHWCaptureWindowList(
            connectionID,
            &id,
            1,
            [.ignoreGlobalClipShape]
        ) as? [CGImage],
           let cgImage = capturedWindows.first {
            let size = NSSize(width: CGFloat(cgImage.width) / scale, height: CGFloat(cgImage.height) / scale)
            return NSImage(cgImage: cgImage, size: size)
        }
        
        // 备选方案：使用公共 API
        log.log("⚠️ Fallback to CGWindowListCreateImage for window \(windowId) (Scale: \(scale))")
        if let windowInfo = getWindowInfo(windowId: windowId) {
            return captureWindow(windowId: windowId, bounds: windowInfo.bounds)
        }
        
        return nil
    }
    
    /// 获取窗口信息
    private func getWindowInfo(windowId: CGWindowID) -> (bounds: CGRect, title: String)? {
        guard let windowList = CGWindowListCopyWindowInfo([.optionIncludingWindow], windowId) as? [[String: Any]],
              let windowInfo = windowList.first else {
            return nil
        }
        
        guard let boundsDict = windowInfo[kCGWindowBounds as String] as? [String: CGFloat],
              let x = boundsDict["X"],
              let y = boundsDict["Y"],
              let width = boundsDict["Width"],
              let height = boundsDict["Height"] else {
            return nil
        }
        
        let bounds = CGRect(x: x, y: y, width: width, height: height)
        let title = windowInfo[kCGWindowName as String] as? String ?? ""
        
        return (bounds, title)
    }
}
