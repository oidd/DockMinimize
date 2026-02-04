//
//  DockEventMonitor.swift
//  DockMinimize
//
//  Created by Dock Minimize
//

import Cocoa
import ApplicationServices

// --- 嵌入式 Dock 图标缓存管理器 ---
class DockIconCacheManager {
    static let shared = DockIconCacheManager()
    
    struct DockIconInfo {
        let frame: CGRect
        let bundleId: String
    }
    
    private(set) var cachedIcons: [DockIconInfo] = []
    private var lastUpdate: TimeInterval = 0
    private let queue = DispatchQueue(label: "com.dockminimize.dockcache", qos: .background)
    private var isUpdating = false
    
    private init() {
        startAutoUpdate()
    }
    
    private func startAutoUpdate() {
        // 降低频率，降低系统压力
        queue.async { [weak self] in
            while true {
                self?.updateCache()
                Thread.sleep(forTimeInterval: 3.0) 
            }
        }
    }
    
    func updateCache() {
        guard !isUpdating else { return }
        isUpdating = true
        defer { isUpdating = false }
        
        // --- 核心改动：所有的系统调用都在后台线程 ---
        guard let dockApp = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else { return }
        let dockElement = AXUIElementCreateApplication(dockApp.processIdentifier)
        
        var childrenRef: CFTypeRef?
        // 如果这里卡住，也只是后台线程卡住，不会卡死 UI
        guard AXUIElementCopyAttributeValue(dockElement, kAXChildrenAttribute as CFString, &childrenRef) == .success,
              let children = childrenRef as? [AXUIElement] else { return }
        
        var newIcons: [DockIconInfo] = []
        for child in children {
            var roleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(child, kAXRoleAttribute as CFString, &roleRef)
            if let role = roleRef as? String, role == "AXList" {
                var listChildrenRef: CFTypeRef?
                if AXUIElementCopyAttributeValue(child, kAXChildrenAttribute as CFString, &listChildrenRef) == .success,
                   let listChildren = listChildrenRef as? [AXUIElement] {
                    for iconElement in listChildren {
                        var positionRef: CFTypeRef?
                        var sizeRef: CFTypeRef?
                        if AXUIElementCopyAttributeValue(iconElement, kAXPositionAttribute as CFString, &positionRef) == .success,
                           AXUIElementCopyAttributeValue(iconElement, kAXSizeAttribute as CFString, &sizeRef) == .success {
                            var position = CGPoint.zero
                            var size = CGSize.zero
                            AXValueGetValue(positionRef as! AXValue, .cgPoint, &position)
                            AXValueGetValue(sizeRef as! AXValue, .cgSize, &size)
                            
                            var bundleId: String? = nil
                            
                            // 1. 优先尝试直接从 AXUIElement 获取标识符 (最快最安全，不触碰文件系统)
                            var bidRef: CFTypeRef?
                            if AXUIElementCopyAttributeValue(iconElement, "AXBundleIdentifier" as CFString, &bidRef) == .success,
                               let bid = bidRef as? String {
                                bundleId = bid
                            }
                            
                            // 2. 如果失败，尝试通过 URL 获取，但要避开敏感路径
                            if bundleId == nil {
                                var urlRef: CFTypeRef?
                                if AXUIElementCopyAttributeValue(iconElement, "AXURL" as CFString, &urlRef) == .success,
                                   let url = urlRef as? URL {
                                    
                                    // 检查是否在“下载”文件夹中 (避雷针)
                                    let downloadsPath = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first?.path ?? "/Downloads/"
                                    let isSensitive = url.path.contains(downloadsPath) || url.path.contains("/Downloads/")
                                    
                                    if isSensitive {
                                        // 敏感路径：仅匹配运行中的应用，绝不调用 Bundle(path:)
                                        bundleId = NSWorkspace.shared.runningApplications.first(where: { 
                                            $0.bundleURL?.path == url.path || $0.executableURL?.path == url.path 
                                        })?.bundleIdentifier
                                    } else {
                                        // 安全路径：可以使用 Bundle(path:)
                                        bundleId = Bundle(path: url.path)?.bundleIdentifier
                                    }
                                }
                            }
                            
                            if let bid = bundleId {
                                // 检查黑名单，如果是黑名单软件，则不将其加入缩略图缓存，彻底不碰它
                                if !SettingsManager.shared.blacklistedBundleIDs.contains(bid) {
                                    newIcons.append(DockIconInfo(frame: CGRect(origin: position, size: size), bundleId: bid))
                                }
                            }
                        }
                    }
                }
            }
        }
        
        DispatchQueue.main.async {
            self.cachedIcons = newIcons
        }
    }
    
    func getBundleId(at point: CGPoint) -> String? {
        // 纯内存操作，绝对安全
        for icon in cachedIcons {
            if icon.frame.contains(point) { return icon.bundleId }
        }
        return nil
    }
}

class DockEventMonitor {
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var lastProcessedTime: Date = Date.distantPast
    
    private let log = DebugLogger.shared
    
    func start() {
        // 监听左键、右键、中键点击，用于拦截和隐藏预览
        let eventMask = (1 << CGEventType.leftMouseDown.rawValue) | 
                         (1 << CGEventType.rightMouseDown.rawValue) | 
                         (1 << CGEventType.otherMouseDown.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(eventMask),
            callback: { (proxy, type, event, refcon) -> Unmanaged<CGEvent>? in
                guard let refcon = refcon else { return Unmanaged.passRetained(event) }
                let monitor = Unmanaged<DockEventMonitor>.fromOpaque(refcon).takeUnretainedValue()
                return monitor.handleEvent(proxy: proxy, type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return }
        
        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }
    
    func stop() {
        if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source = runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes) }
        eventTap = nil
        runLoopSource = nil
    }
    
    private func handleEvent(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // --- 深度稳定性加固：严禁在回调中进行任何阻塞式系统调用 ---
        
        // 1. 系统禁用检查 (HID 链条安全检查)
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            // 被系统禁用时，通常是由于权限变更，直接退出是防止卡死的最优解
            exit(0) 
        }
        
        // 2. 避免在系统设置窗口活跃时进行任何操作
        // 如果这里卡住，通过 NSEvent 检查 frontmostApplication 可能也会锁
        // 所以我们只在非常确定的情况下继续
        
        // 核心：使用尝试性权限检查。如果权限没了，说明我们要退出了。
        // 但是 AXIsProcessTrusted() 本身在权限切换时可能也会死锁！！！
        // 解决方案：不在此处检查权限，只检查内存中的缓存
        
        // 2. 右键/中键点击立刻关闭预览 (Dock 的右键菜单优先级最高)
        if type == .rightMouseDown || type == .otherMouseDown {
            let location = event.location
            // 旧版本用“屏幕底部 100px”判定 Dock 区域，Dock 在左/右侧或在副屏时会失效。
            // 这里改为：命中任意 Dock 图标就认为在 Dock 区域（纯内存操作）。
            if DockIconCacheManager.shared.getBundleId(at: location) != nil {
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: NSNotification.Name("HidePreviewBarForcefully"), object: nil)
                }
            }
            return Unmanaged.passRetained(event)
        }
        
        guard type == .leftMouseDown else { return Unmanaged.passRetained(event) }
        
        let location = event.location
        
        // 3. 快速命中测试：是否点在 Dock 图标上（纯内存操作，不触碰任何系统调用）
        // 旧版本用“屏幕底部 100px”判定 Dock 区域，Dock 在左/右侧或在副屏时会完全失效。
        guard let clickedBundleId = DockIconCacheManager.shared.getBundleId(at: location) else {
            return Unmanaged.passRetained(event)
        }
        
        // 防抖：缩短至 0.1s，适应快速连击
        if Date().timeIntervalSince(lastProcessedTime) < 0.1 { return Unmanaged.passRetained(event) }
        
        // 4. --- 终极防御：给所有的业务逻辑加一个“超时保险箱” ---
        // 我们在后台线程执行业务代码，如果 10ms 内没跑完（说明系统 AX 或 Workspace 锁住了），
        // 那么主线程立即直接放通事件，不等待，不卡死系统。
        
        let semaphore = DispatchSemaphore(value: 0)
        var resultEvent: Unmanaged<CGEvent>? = Unmanaged.passRetained(event)
        
        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            guard let self = self else { 
                semaphore.signal()
                return 
            }
            
            // 下面的逻辑如果卡住了，也只卡在这个后台线程，主线程 10ms 后会直接跳过。
            do {
                // 不需要在这里额外检查黑名单，因为 DockIconCacheManager.updateCache 已经排除了黑名单应用。
                // 只要 clickedBundleId 有值，就说明它是我们负责的应用。
                
                let runningApps = NSRunningApplication.runningApplications(withBundleIdentifier: clickedBundleId)
                if let targetApp = runningApps.first {
                    self.lastProcessedTime = Date()
                    
                    // ⭐️ 核心通用修复：无论前台还是后台，只要判定为“无窗口且非隐藏”，必须放行。
                    // 这解决了 Finder/QSpace 在后台时点击需要两下（第一次被拦截）的问题。
                    
                    var hasVisibleWindows = false
                    // 如果 App 是隐藏的，我们认为它可能有窗口（只是不可见），所以不放行，让 EnsureVisible 处理
                    // 如果 App 不是隐藏的，我们检查屏幕上是否有窗口
                    if !targetApp.isHidden {
                        if let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] {
                            for info in windowList {
                                guard let ownerPID = info[kCGWindowOwnerPID as String] as? Int, ownerPID == targetApp.processIdentifier else { continue }
                                guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0 else { continue }
                                guard let alpha = info[kCGWindowAlpha as String] as? Double, alpha > 0.1 else { continue }
                                
                                if let bounds = info[kCGWindowBounds as String] as? [String: Double] {
                                    let w = bounds["Width"] ?? 0
                                    let h = bounds["Height"] ?? 0
                                    if w < 100 || h < 100 { continue }
                                }
                                
                                hasVisibleWindows = true
                                break
                            }
                        }
                        
                        // ⭐️ 核心修复：如果是 Finder，即便没有可见窗口也要继续逻辑（去恢复被缩小的窗口）。
                        // 如果是其他应用，确实没有窗口时才放行。
                        if !hasVisibleWindows && clickedBundleId != "com.apple.finder" {
                            // App 未隐藏，但在屏幕上找不到 >100x100 的窗口 -> 真正的无窗口状态 -> 放行给系统 Reopen
                            semaphore.signal()
                            return
                        }
                    }
                    
                    // ⭐️ UI 瞬间响应：先发通知，后调逻辑。保证指示条第一秒就变。
                    // 如果已经在前台，意图是 Toggle (最小化/恢复)
                    // 如果在后台，意图是 Activate (提升至最前)
                    let isAlreadyActive = NSWorkspace.shared.frontmostApplication?.bundleIdentifier == clickedBundleId
                    let action = isAlreadyActive ? "toggle" : "activate"
                    
                    NotificationCenter.default.post(
                        name: NSNotification.Name("DockIconClicked"),
                        object: nil,
                        userInfo: ["bundleId": clickedBundleId, "action": action]
                    )
                    
                    DispatchQueue.main.async {
                        if action == "toggle" {
                            WindowManager.shared.toggleWindows(for: targetApp)
                        } else {
                            WindowManager.shared.ensureWindowsVisible(for: targetApp)
                        }
                    }
                    resultEvent = nil
                } else {
                    // 2. 该应用未运行...
                }
            }
            semaphore.signal()
        }
        
        // 最多等 10 毫秒。如果系统没响应，说明环境危险，立即放手。
        let waitResult = semaphore.wait(timeout: .now() + 0.01)
        if waitResult == .timedOut {
            // 系统响应太慢（说明正在处理权限或忙碌），为了保命，这里直接放行所有点击事件。
            return Unmanaged.passRetained(event)
        }
        
        return resultEvent
    }
}
