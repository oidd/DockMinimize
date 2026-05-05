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
    
    // ⭐️ 多桌面（Spaces）修复 v2：合法 windowId 白名单缓存
    //
    // 背景：
    //   切到非主 Space 时，AX (kAXWindowsAttribute) 会返回 -25211 (cannot complete)，
    //   完全拿不到该 App 的任何 AX 窗口，于是无法用 AX 过滤掉"非标准窗口"
    //   （如微信 280×380 的搜索浮窗、各类小组件等）。CG 单独不可靠，
    //   会把这些浮窗也当成可预览窗口，导致出现额外的空白预览小窗。
    //
    // 解法：
    //   每当我们处于"AX 还能用"的状态（主桌面、且 AX 返回非空列表），
    //   就把这一刻 AX 校验通过的 windowId 集合按 bundleId 缓存下来。
    //   等到跨 Space、AX 失效时，**严格** 只放行白名单里的 windowId，
    //   其余 CG 窗口一律丢弃 —— 这样两个桌面看到的窗口数量/集合完全一致。
    //
    // 缓存条目本身没有设过期：白名单只会被新一次成功的 AX 查询覆盖，
    //   App 退出 / 我们进程重启时自然清掉。
    private struct AXWindowAllowlist {
        let windowIds: Set<CGWindowID>
        let updatedAt: Date
    }
    private var axAllowlist: [String: AXWindowAllowlist] = [:]   // key: bundleId
    private let axAllowlistQueue = DispatchQueue(label: "com.dockminimize.axAllowlist")
    
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
    func getWindows(for bundleId: String, respectDockExclusions: Bool = true) -> [WindowInfo] {
        // 找到对应的运行中应用
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first else {
            log.log("⚠️ No running app found for bundle ID: \(bundleId)")
            return []
        }
        
        // 检查黑名单 + SideBar 联动排除：如果命中，直接返回空，彻底不碰
        if respectDockExclusions && SettingsManager.shared.shouldSkipDockHandling(bundleID: bundleId) {
            return []
        }
        
        let pid = app.processIdentifier
        
        // 首先通过 AXUIElement 获取有效窗口列表（核心过滤）
        let validAXWindows = getValidAXWindows(for: pid)
        
        // ⭐️ 多桌面修复 v2：维护 / 读取 AX 窗口白名单
        //  - AX 拿得到 → 用本次结果**覆盖更新**白名单（最权威）
        //  - AX 拿不到 → 读取上次缓存的白名单作为兜底过滤依据
        let axAllowlistSnapshot: Set<CGWindowID>?
        if !validAXWindows.isEmpty {
            let ids = Set(validAXWindows.map { $0.windowId })
            axAllowlistQueue.sync {
                axAllowlist[bundleId] = AXWindowAllowlist(windowIds: ids, updatedAt: Date())
            }
            axAllowlistSnapshot = ids
        } else {
            log.log("ℹ️ No valid AX windows for \(bundleId). Falling back to CGWindowList only.")
            axAllowlistSnapshot = axAllowlistQueue.sync { axAllowlist[bundleId]?.windowIds }
            if let snap = axAllowlistSnapshot {
                log.log("🛡️ Using cached AX allowlist for \(bundleId): \(snap.count) ids → \(snap.sorted())")
            }
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
            
            // ⭐️ Zombie 窗口过滤（关键根因修复）：
            //   症状：WPS / 微信 / 移动云盘 / QQ 音乐更新提示 等 App 用一段时间后，
            //   预览小窗里出现一堆「黑屏 + 同名（如『首页』）+ 显示为已最小化」的鬼影窗口。
            //
            //   根因：这些 App 关闭某个内部窗口后，没有及时释放对应的 AXUIElement，
            //   导致 AX 枚举（kAXWindowsAttribute）依然能拿到「亡魂」，CGWindowList 也
            //   还残留这条记录，于是穿透了我们之前所有过滤层（尺寸/role/subrole/title/AX 匹配）。
            //
            //   过滤指标：kCGWindowSharingState
            //     - 0 (.none)      → 系统已停止把该窗口内容共享给其他进程 = zombie
            //     - 1 (.readOnly)  → 正常窗口（最小化窗口仍保留 readOnly 用作 Dock 缩略图）
            //     - 2 (.readWrite) → 正常窗口
            //   真实最小化窗口至少是 readOnly（系统要 keep 窗口的 last frame 给 Dock 用），
            //   而 zombie 窗口的 sharingState 一定是 0。这条过滤不会误伤任何真实窗口。
            if let sharingState = windowInfo[kCGWindowSharingState as String] as? Int,
               sharingState == 0 {
                // 静默丢弃（出现频率高，避免日志刷屏）
                continue
            }

            
            let isOnScreen = windowInfo[kCGWindowIsOnscreen as String] as? Bool ?? false
            
            let bounds = CGRect(x: x, y: y, width: width, height: height)
            
            let matchedAXWindow = matchAXWindow(windowId: windowId, bounds: bounds, in: validAXWindows)
            
            let title = windowInfo[kCGWindowName as String] as? String ?? ""
            let ownerName = windowInfo[kCGWindowOwnerName as String] as? String ?? ""
            
            let isMinimized = (matchedAXWindow?.isMinimized ?? false) || app.isHidden
            
            // --- 核心优化 (DockDoor 逻辑 + 多桌面 Spaces 修复) ---
            //
            // ⭐️ 多桌面修复的核心思路：
            //   当用户切到非主 Space 后，原本「在另一个 Space 的合法窗口」会出现：
            //     - CGWindowList: isOnScreen == false（系统不把它列为当前屏幕可见）
            //     - AX:           kAXWindowsAttribute 通常拿不到 → matchedAXWindow == nil
            //   旧逻辑会把这种窗口当"幽灵窗口"全部丢弃 → 第二桌面 hover 大量 App 没预览。
            //
            //   但是「更新弹窗 / 小组件 / 隐形窗口」也可能符合 isOnScreen==false 这个特征，
            //   所以必须用 AX 来辅助甄别合法性，单看 CG 标志会误放一大堆垃圾窗口。
            //
            //   收紧后的判定：
            //     - 当 AX **能** 拿到窗口列表（validAXWindows 非空）：
            //         必须 matchedAXWindow != nil，否则一律丢弃（彻底挡住小组件/弹窗）。
            //     - 当 AX **完全** 拿不到窗口列表（validAXWindows 为空，老旧应用 / 当前 Space 无窗口）：
            //         CG 兜底必须满足：layer==0 + alpha≥0.1 + 尺寸 ≥ 200×200 + 有非空 title，
            //         以最大可能挡住 sheet/popover/widget。
            //
            //   isOffCurrentSpace 现在只描述"窗口位置不在当前 Space"这一物理特征，不直接决定放行；
            //   放行决策完全由 AX/CG 兜底逻辑负责。
            
            // 1. 当 AX 报告了有效窗口列表，但这个 CG 窗口没匹配到任何 AX 窗口 → 一律丢弃。
            //    （这里不再为跨 Space 开例外：因为如果 AX 拿得到列表，说明 AX 知道这个 App
            //     在当前 Space 有窗口；那些跨 Space 窗口在 AX 里就是查不到的，本来也不该放。
            //     真正需要放跨 Space 的场景，会走到下面 validAXWindows.isEmpty 那个分支。）
            if !validAXWindows.isEmpty && matchedAXWindow == nil {
                continue
            }
            
            // 2. AX 兜底：当 AX 拿不到任何窗口（典型场景：跨 Space 时整个 App 在当前 Space 没窗口），
            //    走纯 CG 路径。
            //
            //    ⭐️ 多桌面修复 v2 的关键：优先用「上次 AX 留下来的白名单」做精准过滤。
            //      白名单存在 → 严格只放行白名单里的 windowId，
            //                 这样跨 Space 看到的窗口集合 = 上次主桌面 AX 看到的集合，
            //                 完美避免微信浮窗 / 小组件等被误放。
            //      白名单为空（首次启动就在非 App 所在 Space 等极端情况）→
            //                 退化为旧的尺寸/标题启发式，仍能给用户一个"差不多对"的预览，
            //                 等用户回到主桌面让 AX 跑过一次，下次就准了。
            if validAXWindows.isEmpty {
                if let allowlist = axAllowlistSnapshot {
                    if !allowlist.contains(windowId) {
                        continue
                    }
                    // 命中白名单 → 直接放行，不再做尺寸/标题启发式判断
                } else {
                    // 启发式兜底（仅在从未拿到过 AX 列表时使用）
                    if title.isEmpty { continue }
                    if width < 200 || height < 200 { continue }
                }
            }
            
            // 3. 幽灵窗口过滤：到这里还没被剔除的窗口，要么 AX 通过了（matchedAXWindow != nil），
            //    要么走的是 AX 空 + CG 严格兜底（已经过 step 2 校验）。
            //    剩下唯一要挡的是 isOnScreen==false && !isMinimized && !app.isHidden 且
            //    AX 也匹配不上的"幽灵态"——但这种已经在 step 1 被挡掉了，这里保留一道兜底。
            if !isOnScreen && !isMinimized && !app.isHidden && matchedAXWindow == nil && !validAXWindows.isEmpty {
                 continue
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
