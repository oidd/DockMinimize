//
//  WindowThumbnailService.swift
//  DockMinimize
//
//  窗口缩略图服务 - 获取应用窗口列表和缩略图（带智能缓存）
//

import Cocoa
import ApplicationServices

class WindowThumbnailService {
    static let shared = WindowThumbnailService()
    
    private let log = DebugLogger.shared
    private let captureManager = ScreenCaptureManager.shared
    
    /// 缓存过期时间（秒）
    private let cacheExpiration: TimeInterval = 2.0
    
    /// 缩略图缓存
    private var thumbnailCache: [CGWindowID: CachedThumbnail] = [:]
    
    /// 缓存条目
    private struct CachedThumbnail {
        let image: NSImage
        let captureTime: Date
    }
    
    private init() {}
    
    /// 窗口信息结构（保存 AXUIElement 避免重复查找 - 参考 DockDoor 实现）
    struct WindowInfo: Identifiable {
        let id: CGWindowID
        let windowId: CGWindowID
        let title: String
        let ownerPID: pid_t
        let ownerName: String
        let bounds: CGRect
        var isMinimized: Bool
        var isActive: Bool
        var thumbnail: NSImage?
        
        // ⭐️ 直接保存 AXUIElement，避免每次操作时重新查找
        let axElement: AXUIElement
        let appAxElement: AXUIElement
        let closeButton: AXUIElement?
        
        init(windowId: CGWindowID, title: String, ownerPID: pid_t, ownerName: String, bounds: CGRect, isMinimized: Bool = false, isActive: Bool = false, thumbnail: NSImage? = nil, axElement: AXUIElement, appAxElement: AXUIElement, closeButton: AXUIElement? = nil) {
            self.id = windowId
            self.windowId = windowId
            self.title = title
            self.ownerPID = ownerPID
            self.ownerName = ownerName
            self.bounds = bounds
            self.isMinimized = isMinimized
            self.isActive = isActive
            self.thumbnail = thumbnail
            self.axElement = axElement
            self.appAxElement = appAxElement
            self.closeButton = closeButton
        }
    }
    
    /// 获取指定应用的所有窗口信息（参考 DockDoor 实现）
    func getWindows(for bundleId: String) -> [WindowInfo] {
        // 找到对应的运行中应用
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first else {
            log.log("⚠️ No running app found for bundle ID: \(bundleId)")
            return []
        }
        
        // 检查黑名单 + SideBar 联动排除：如果命中，直接返回空，彻底不碰
        if SettingsManager.shared.shouldSkipApp(bundleID: bundleId) {
            return []
        }
        
        let pid = app.processIdentifier
        
        // 首先通过 AXUIElement 获取有效窗口列表（核心过滤）
        let validAXWindows = getValidAXWindows(for: pid)
        
        if validAXWindows.isEmpty {
            log.log("ℹ️ No valid AX windows for \(bundleId). Falling back to CGWindowList only.")
        }
        
        // 获取 CG 窗口列表用于匹配
        guard let windowList = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] else {
            log.log("⚠️ Failed to get window list")
            return []
        }
        
        var windows: [WindowInfo] = []
        
        // 遍历 CG 窗口，与有效的 AX 窗口匹配
        for windowInfo in windowList {
            guard let ownerPID = windowInfo[kCGWindowOwnerPID as String] as? pid_t,
                  ownerPID == pid else {
                continue
            }
            
            guard let windowId = windowInfo[kCGWindowNumber as String] as? CGWindowID else {
                continue
            }
            
            guard let boundsDict = windowInfo[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = boundsDict["X"],
                  let y = boundsDict["Y"],
                  let width = boundsDict["Width"],
                  let height = boundsDict["Height"] else {
                continue
            }
            
            // 基础过滤：尺寸、层级、透明度
            if width < 100 || height < 100 { continue }
            if let layer = windowInfo[kCGWindowLayer as String] as? Int, layer != 0 { continue }
            if let alpha = windowInfo[kCGWindowAlpha as String] as? CGFloat, alpha < 0.1 { continue }
            
            let isOnScreen = windowInfo[kCGWindowIsOnscreen as String] as? Bool ?? false
            
            let bounds = CGRect(x: x, y: y, width: width, height: height)
            
            let matchedAXWindow = matchAXWindow(windowId: windowId, bounds: bounds, in: validAXWindows)
            
            // --- 核心优化 (DockDoor 逻辑) ---
            
            // 1. 如果辅助功能 (AX) 报告了有效窗口列表...
            if !validAXWindows.isEmpty && matchedAXWindow == nil {
                continue
            }
            
            let isMinimized = (matchedAXWindow?.isMinimized ?? false) || app.isHidden
            
            // 2. 幽灵窗口过滤：如果不在屏幕上，且没有最小化，且应用没有被隐藏，视为无效（过滤 QSpace/Finder 幽灵窗口）
            // 修正：如果 App 处于 Hidden 状态 (Cmd+H)，它的窗口自然不在屏幕上，必须保留，否则预览图会消失。
            if !isOnScreen && !isMinimized && !app.isHidden {
                 continue
            }

            // 3. 老旧应用兜底
            let title = windowInfo[kCGWindowName as String] as? String ?? ""
            let ownerName = windowInfo[kCGWindowOwnerName as String] as? String ?? ""
            
            if validAXWindows.isEmpty {
                 if title.isEmpty { continue }
            }
            
            // (Removed redundant 40px/50px check since we have global 100px check above)
            
            // let isMinimized = matchedAXWindow?.isMinimized ?? false (Removed duplicate)
            
            let info = WindowInfo(
                windowId: windowId,
                title: title.isEmpty ? ownerName : title,
                ownerPID: ownerPID,
                ownerName: ownerName,
                bounds: bounds,
                isMinimized: isMinimized,
                axElement: matchedAXWindow?.element ?? AXUIElementCreateApplication(pid), 
                appAxElement: matchedAXWindow?.appElement ?? AXUIElementCreateApplication(pid),
                closeButton: matchedAXWindow?.closeButton
            )
            
            windows.append(info)
        }
        
        log.log("📋 Found \(windows.count) valid windows for \(bundleId) (from \(validAXWindows.count) AX windows)")
        return windows
    }
    
    /// AX 窗口信息（用于匹配）
    private struct AXWindowInfo {
        let element: AXUIElement
        let appElement: AXUIElement  // 应用的 AXUIElement
        let windowId: CGWindowID     // 使用 _AXUIElementGetWindow 获取的精确 ID
        let position: CGPoint
        let size: CGSize
        let isMinimized: Bool
        let closeButton: AXUIElement?  // 关闭按钮
    }
    
    /// 获取应用的所有有效 AX 窗口（DockDoor 核心过滤逻辑）
    private func getValidAXWindows(for pid: pid_t) -> [AXWindowInfo] {
        let appElement = AXUIElementCreateApplication(pid)
        
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement] else {
            return []
        }
        
        var validWindows: [AXWindowInfo] = []
        
        for window in windows {
            // 0. ⭐️ 使用私有 API 获取精确的 CGWindowID
            var windowId: CGWindowID = 0
            let result = _AXUIElementGetWindow(window, &windowId)
            guard result == .success, windowId != 0 else {
                continue
            }
            
            // 1. 检查窗口角色必须是 kAXWindowRole
            var roleRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(window, kAXRoleAttribute as CFString, &roleRef) == .success,
               let role = roleRef as? String {
                if role != kAXWindowRole as String {
                    continue
                }
            }
            
            // 2. 检查子角色必须是标准窗口或对话框
            var subroleRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(window, kAXSubroleAttribute as CFString, &subroleRef) == .success,
               let subrole = subroleRef as? String {
                // 只接受标准窗口、对话框和浮动窗口
                if subrole != kAXStandardWindowSubrole as String && 
                   subrole != kAXDialogSubrole as String &&
                   subrole != kAXFloatingWindowSubrole as String {
                    continue
                }
            }
            
            // 3. ⭐️ 核心：检查是否有关闭按钮或最小化按钮
            var closeButtonRef: CFTypeRef?
            var minimizeButtonRef: CFTypeRef?
            let hasCloseButton = AXUIElementCopyAttributeValue(window, kAXCloseButtonAttribute as CFString, &closeButtonRef) == .success && closeButtonRef != nil
            let hasMinimizeButton = AXUIElementCopyAttributeValue(window, kAXMinimizeButtonAttribute as CFString, &minimizeButtonRef) == .success && minimizeButtonRef != nil
            
            // 必须有关闭按钮、最小化按钮或者是具有标题的窗口
            var titleRef: CFTypeRef?
            let hasTitle = AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleRef) == .success && !(titleRef as? String ?? "").isEmpty
            
            if !hasCloseButton && !hasMinimizeButton && !hasTitle {
                continue
            }
            
            // 4. 获取窗口位置和尺寸
            var posRef: CFTypeRef?
            var sizeRef: CFTypeRef?
            var position = CGPoint.zero
            var size = CGSize.zero
            
            if AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &posRef) == .success,
               let posValue = posRef {
                AXValueGetValue(posValue as! AXValue, .cgPoint, &position)
            }
            
            if AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeRef) == .success,
               let sizeValue = sizeRef {
                AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
            }
            
            // 5. 检查是否最小化
            var minimizedRef: CFTypeRef?
            var isMinimized = false
            if AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &minimizedRef) == .success,
               let minimized = minimizedRef as? Bool {
                isMinimized = minimized
            }
            
            validWindows.append(AXWindowInfo(
                element: window,
                appElement: appElement,
                windowId: windowId,
                position: position,
                size: size,
                isMinimized: isMinimized,
                closeButton: hasCloseButton ? (closeButtonRef as! AXUIElement) : nil
            ))
        }
        
        return validWindows
    }
    
    /// 将 CG 窗口与 AX 窗口匹配（通过 _AXUIElementGetWindow 获取的精确 ID）
    private func matchAXWindow(windowId: CGWindowID, bounds: CGRect, in axWindows: [AXWindowInfo]) -> AXWindowInfo? {
        // 1. 优先通过 windowId 匹配
        for axWindow in axWindows {
            if axWindow.windowId == windowId {
                return axWindow
            }
        }
        
        // 2. 备选方案：通过位置和尺寸模糊匹配 (容错处理)
        for axWindow in axWindows {
            let threshold: CGFloat = 2.0
            if abs(axWindow.position.x - bounds.origin.x) < threshold &&
               abs(axWindow.position.y - bounds.origin.y) < threshold &&
               abs(axWindow.size.width - bounds.width) < threshold &&
               abs(axWindow.size.height - bounds.height) < threshold {
                return axWindow
            }
        }
        
        return nil
    }
    
    /// 截取指定窗口的缩略图（带缓存）
    func captureThumbnail(for windowId: CGWindowID, forceRefresh: Bool = false) -> NSImage? {
        // 1. 检查内存缓存
        if !forceRefresh, let cached = thumbnailCache[windowId] {
            let age = Date().timeIntervalSince(cached.captureTime)
            if age < cacheExpiration {
                return cached.image
            }
        }
        
        // 2. 检查磁盘缓存 (New V5.11)
        if !forceRefresh, let diskImage = CacheManager.shared.loadThumbnail(windowId: windowId) {
            // 更新内存缓存
            thumbnailCache[windowId] = CachedThumbnail(image: diskImage, captureTime: Date())
            return diskImage
        }
        
        // 3. 截取新图
        guard let image = captureManager.captureWindow(windowId: windowId) else {
            return nil
        }
        
        // 生成缩略图（缩放到合适尺寸）
        let thumbnail = createThumbnail(from: image, maxWidth: 320, maxHeight: 200)
        
        // 4. 更新内存与磁盘缓存
        // 4. 更新内存与磁盘缓存
        thumbnailCache[windowId] = CachedThumbnail(image: thumbnail, captureTime: Date())
        CacheManager.shared.saveThumbnail(image: thumbnail, windowId: windowId)
        
        // 5. 内存保护：LRU 淘汰 (防止无限增长)
        // 如果缓存超过 50 张，清理最旧的 20 张
        if thumbnailCache.count > 50 {
            let sortedKeys = thumbnailCache.keys.sorted {
                (thumbnailCache[$0]?.captureTime ?? Date.distantPast) < (thumbnailCache[$1]?.captureTime ?? Date.distantPast)
            }
            // 删除前 20 个（最旧的）
            for i in 0..<20 {
                if i < sortedKeys.count {
                    thumbnailCache.removeValue(forKey: sortedKeys[i])
                }
            }
            log.log("🧹 Pruned thumbnail cache (size: \(thumbnailCache.count))")
        }
        
        return thumbnail
    }
    
    /// 获取窗口的完整截图（不缩放，用于原位预览）
    func captureFullImage(for windowId: CGWindowID) -> NSImage? {
        return captureManager.captureWindow(windowId: windowId)
    }
    
    /// 批量获取窗口缩略图
    func captureAllThumbnails(for windows: [WindowInfo], forceRefresh: Bool = false) -> [CGWindowID: NSImage] {
        var result: [CGWindowID: NSImage] = [:]
        
        for window in windows {
            if let thumbnail = captureThumbnail(for: window.windowId, forceRefresh: forceRefresh) {
                result[window.windowId] = thumbnail
            }
        }
        
        return result
    }
    
    /// 清理指定应用的缓存
    func invalidateCache(for bundleId: String) {
        let windows = getWindows(for: bundleId)
        for window in windows {
            thumbnailCache.removeValue(forKey: window.windowId)
        }
        log.log("🧹 Invalidated cache for \(bundleId)")
    }
    
    /// 清理指定窗口的缓存
    func invalidateCache(for windowId: CGWindowID) {
        thumbnailCache.removeValue(forKey: windowId)
    }
    
    /// 清理所有缓存
    func clearAllCache() {
        thumbnailCache.removeAll()
        log.log("🧹 Cleared all thumbnail cache")
    }
    
    // MARK: - Private Methods
    
    /// 创建缩略图（线程安全版本，不使用 lockFocus/unlockFocus）
    private func createThumbnail(from image: NSImage, maxWidth: CGFloat, maxHeight: CGFloat) -> NSImage {
        let originalSize = image.size
        
        // 计算缩放比例
        let widthRatio = maxWidth / originalSize.width
        let heightRatio = maxHeight / originalSize.height
        let ratio = min(widthRatio, heightRatio, 1.0) // 不放大
        
        let newSize = NSSize(
            width: originalSize.width * ratio,
            height: originalSize.height * ratio
        )
        
        // ⭐️ 使用 NSBitmapImageRep + NSGraphicsContext 替代 lockFocus
        // lockFocus/unlockFocus 必须在主线程调用，而此方法可能在后台线程被调用
        guard let bitmapRep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(newSize.width),
            pixelsHigh: Int(newSize.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            // 回退：返回原图
            return image
        }
        
        bitmapRep.size = newSize
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmapRep)
        NSGraphicsContext.current?.imageInterpolation = .high
        
        image.draw(
            in: NSRect(origin: .zero, size: newSize),
            from: NSRect(origin: .zero, size: originalSize),
            operation: .copy,
            fraction: 1.0
        )
        
        NSGraphicsContext.restoreGraphicsState()
        
        let thumbnail = NSImage(size: newSize)
        thumbnail.addRepresentation(bitmapRep)
        
        return thumbnail
    }
}
