//
//  DockIconCacheManager.swift
//  DockMinimize
//
//  管理 Dock 图标位置缓存，避免在事件流中进行同步 AX 调用导致死锁
//

import Cocoa
import ApplicationServices

class DockIconCacheManager {
    static let shared = DockIconCacheManager()
    
    struct DockIconInfo {
        let frame: CGRect
        let bundleId: String
    }
    
    private(set) var cachedIcons: [DockIconInfo] = []
    private var lastUpdate: TimeInterval = 0
    private let updateInterval: TimeInterval = 2.0
    private let queue = DispatchQueue(label: "com.dockminimize.dockcache", qos: .background)
    private var isUpdating = false
    
    private init() {
        startAutoUpdate()
    }
    
    /// 开始定期自动更新
    private func startAutoUpdate() {
        queue.async { [weak self] in
            while true {
                self?.updateCache()
                Thread.sleep(forTimeInterval: self?.updateInterval ?? 2.0)
            }
        }
    }
    
    /// 在后台更新 Dock 图标位置
    func updateCache() {
        guard !isUpdating else { return }
        isUpdating = true
        
        defer { isUpdating = false }
        
        guard let dockApp = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else {
            return
        }
        
        // 注意：权限丢失时，此处的 AX 调用可能会超时，但因为它在后台线程，不会卡死系统
        let dockElement = AXUIElementCreateApplication(dockApp.processIdentifier)
        
        var childrenRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(dockElement, kAXChildrenAttribute as CFString, &childrenRef) == .success,
              let children = childrenRef as? [AXUIElement] else {
            return
        }
        
        var newIcons: [DockIconInfo] = []
        
        for child in children {
            var roleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(child, kAXRoleAttribute as CFString, &roleRef)
            
            if let role = roleRef as? String, role == "AXList" {
                var listChildrenRef: CFTypeRef?
                guard AXUIElementCopyAttributeValue(child, kAXChildrenAttribute as CFString, &listChildrenRef) == .success,
                      let listChildren = listChildrenRef as? [AXUIElement] else {
                    continue
                }
                
                for iconElement in listChildren {
                    var positionRef: CFTypeRef?
                    var sizeRef: CFTypeRef?
                    
                    guard AXUIElementCopyAttributeValue(iconElement, kAXPositionAttribute as CFString, &positionRef) == .success,
                          AXUIElementCopyAttributeValue(iconElement, kAXSizeAttribute as CFString, &sizeRef) == .success else {
                        continue
                    }
                    
                    var position = CGPoint.zero
                    var size = CGSize.zero
                    AXValueGetValue(positionRef as! AXValue, .cgPoint, &position)
                    AXValueGetValue(sizeRef as! AXValue, .cgSize, &size)
                    
                    let iconRect = CGRect(origin: position, size: size)
                    
                    var urlRef: CFTypeRef?
                    if AXUIElementCopyAttributeValue(iconElement, "AXURL" as CFString, &urlRef) == .success,
                       let url = urlRef as? URL,
                       let bundle = Bundle(url: url),
                       let bundleId = bundle.bundleIdentifier {
                        newIcons.append(DockIconInfo(frame: iconRect, bundleId: bundleId))
                    }
                }
            }
        }
        
        DispatchQueue.main.async {
            self.cachedIcons = newIcons
            self.lastUpdate = Date().timeIntervalSince1970
        }
    }
    
    /// 同步获取指定位置的 Bundle ID (极速，仅内存操作)
    func getBundleId(at point: CGPoint) -> String? {
        // 由于 cachedIcons 在主线程更新，如果在主线程调用此方法是安全的
        for icon in cachedIcons {
            if icon.frame.contains(point) {
                return icon.bundleId
            }
        }
        return nil
    }
}
