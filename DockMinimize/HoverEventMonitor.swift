//
//  HoverEventMonitor.swift
//  DockMinimize
//
//  鼠标悬停事件监听器 - 监听 Dock 图标悬停
//

import Cocoa
import ApplicationServices

protocol HoverEventMonitorDelegate: AnyObject {
    func hoverEventMonitor(_ monitor: HoverEventMonitor, didHoverOnApp bundleId: String, at position: CGPoint)
    func hoverEventMonitorDidExitDock(_ monitor: HoverEventMonitor)
    func hoverEventMonitor(_ monitor: HoverEventMonitor, didMoveInPreviewBar position: CGPoint)
    func hoverEventMonitorDidExitPreviewBar(_ monitor: HoverEventMonitor)
}

class HoverEventMonitor {
    private struct SafeTransitionZone {
        let p1: CGPoint
        let p2: CGPoint
        let p3: CGPoint
        let p4: CGPoint

        func contains(_ point: CGPoint) -> Bool {
            let edges = [(p1, p2), (p2, p3), (p3, p4), (p4, p1)]
            var hasPositive = false
            var hasNegative = false
            
            for (start, end) in edges {
                let cross = (end.x - start.x) * (point.y - start.y) - (end.y - start.y) * (point.x - start.x)
                if cross > 0.0001 { hasPositive = true }
                if cross < -0.0001 { hasNegative = true }
                if hasPositive && hasNegative {
                    return false
                }
            }
            return true
        }
    }
    
    weak var delegate: HoverEventMonitorDelegate?
    
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var hoverTimer: DispatchWorkItem?
    private var lastHoveredApp: String?
    private var lastMousePosition: CGPoint = .zero
    
    var previewBarFrame: CGRect = .zero
    var isPreviewBarVisible: Bool = false
    private let hoverDelay: TimeInterval = 0.02 // 降低延迟实现丝滑响应
    
    private let log = DebugLogger.shared
    
    func start() {
        let eventMask = (1 << CGEventType.mouseMoved.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(eventMask),
            callback: { (proxy, type, event, refcon) -> Unmanaged<CGEvent>? in
                guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<HoverEventMonitor>.fromOpaque(refcon).takeUnretainedValue()
                monitor.handleMouseMoved(event: event)
                return Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return }
        
        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }
    
    func stop() {
        hoverTimer?.cancel()
        hoverTimer = nil
        if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source = runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes) }
        eventTap = nil
        runLoopSource = nil
    }
    
    /// 检查 EventTap 是否还活着
    func isAlive() -> Bool {
        guard let tap = eventTap else { return false }
        return CGEvent.tapIsEnabled(tap: tap)
    }
    
    /// 最后一次触发悬停的时间（用于防抖）
    private var lastHoverTriggerTime: Date = Date.distantPast

    private func handleMouseMoved(event: CGEvent) {
        let location = event.location
        lastMousePosition = location
        
        if event.type == .tapDisabledByTimeout || event.type == .tapDisabledByUserInput {
            // ⚠️ 严禁 exit(0)！EventTap 超时是常见事件（截图阻塞等），重新启用即可恢复
            log.log("⚠️ [HoverMonitor] EventTap disabled by \(event.type == .tapDisabledByTimeout ? "timeout" : "user input"), re-enabling...")
            if let tap = self.eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return
        }
        
        if WindowManager.shared.isTransitioning {
            return
        }
        
        let semaphore = DispatchSemaphore(value: 0)
        
        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            autoreleasepool {
                guard let self = self else { 
                    semaphore.signal()
                    return 
                }
                
                // 1. 基础状态计算 (提前计算以供后续决策)
                let screen = NSScreen.main?.frame ?? CGRect(x: 0, y: 0, width: 1200, height: 800)
                let dockPos = DockPositionManager.shared.currentPosition
                let thickness = DockPositionManager.shared.dockDetectionThickness
                
                let inDock: Bool = {
                    switch dockPos {
                    case .bottom: return location.y > (screen.height - thickness)
                    case .left:   return location.x < thickness
                    case .right:  return location.x > (screen.width - thickness)
                    }
                }()
                
                let currentBundleId = inDock ? DockIconCacheManager.shared.getBundleId(at: location) : nil
                
                // 2. 预览条交互与动态安全区域保护
                if self.isPreviewBarVisible && !self.previewBarFrame.isEmpty {
                    // A. 如果鼠标在预览条内，维持现状
                    if self.previewBarFrame.contains(location) {
                        DispatchQueue.main.async { self.delegate?.hoverEventMonitor(self, didMoveInPreviewBar: location) }
                        semaphore.signal()
                        return
                    }
                    
                    // B. 鼠标位于图标 -> 预览条的梯形安全区时，保持当前 App 锁定
                    if let bundleId = self.lastHoveredApp,
                       let iconFrame = self.getDockIconFrame(for: bundleId),
                       let safeZone = self.buildSafeTransitionZone(dockPos: dockPos, screen: screen, iconFrame: iconFrame) {
                        if self.isMovingTowardPreviewArea(location: location, dockPos: dockPos, iconFrame: iconFrame),
                       safeZone.contains(location) {
                            self.cancelHoverTimer()
                            semaphore.signal()
                            return
                        }
                    }
                }
                
                // 3. Dock 边界处理与图标更新
                if !inDock {
                    self.cancelHoverTimer()
                    if self.lastHoveredApp != nil {
                        self.lastHoveredApp = nil
                        DispatchQueue.main.async { self.delegate?.hoverEventMonitorDidExitDock(self) }
                    }
                    semaphore.signal()
                    return
                }
                
                if let bundleId = currentBundleId {
                    if bundleId != self.lastHoveredApp {
                        let now = Date()
                        // ⭐️ 极致优化：将冷却时间压缩至 20ms (约单帧间隔)，实现极致跟手
                        if now.timeIntervalSince(self.lastHoverTriggerTime) < 0.02 {
                            semaphore.signal()
                            return
                        }
                        
                        self.cancelHoverTimer()
                        self.startHoverTimer(for: bundleId, at: location)
                        self.lastHoverTriggerTime = now
                    }
                } else {
                    self.cancelHoverTimer()
                    if self.lastHoveredApp != nil {
                        self.lastHoveredApp = nil
                        DispatchQueue.main.async { self.delegate?.hoverEventMonitorDidExitDock(self) }
                    }
                }
                
                semaphore.signal()
            }
        }
        
        _ = semaphore.wait(timeout: .now() + 0.01)
    }
    
    private func startHoverTimer(for bundleId: String, at position: CGPoint) {
        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.lastHoveredApp = bundleId
            self.delegate?.hoverEventMonitor(self, didHoverOnApp: bundleId, at: position)
        }
        hoverTimer = workItem
        // ⭐️ 极速触发：20ms -> 10ms
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.01, execute: workItem)
    }
    
    private func cancelHoverTimer() {
        hoverTimer?.cancel()
        hoverTimer = nil
    }
    
    func getDockIconPosition(for bundleId: String) -> CGPoint? {
        if let icon = DockIconCacheManager.shared.cachedIcons.first(where: { $0.bundleId == bundleId }) {
            // ⭐️ 核心修正：返回图标中心点，而非底边中心。这能让侧边 Dock 的保护走廊更准确。
            return CGPoint(x: icon.frame.midX, y: icon.frame.midY)
        }
        return nil
    }
    
    private func getDockIconFrame(for bundleId: String) -> CGRect? {
        DockIconCacheManager.shared.cachedIcons.first(where: { $0.bundleId == bundleId })?.frame
    }
    
    private func buildSafeTransitionZone(dockPos: DockPosition, screen: CGRect, iconFrame: CGRect) -> SafeTransitionZone? {
        guard !previewBarFrame.isEmpty else { return nil }

        let iconCenter = CGPoint(x: iconFrame.midX, y: iconFrame.midY)
        let previewCenter = CGPoint(x: previewBarFrame.midX, y: previewBarFrame.midY)
        let vx = previewCenter.x - iconCenter.x
        let vy = previewCenter.y - iconCenter.y
        let len = sqrt(vx * vx + vy * vy)
        guard len > 0.1 else { return nil }
        
        let dir = CGPoint(x: vx / len, y: vy / len)
        let perp = CGPoint(x: -dir.y, y: dir.x)
        
        func halfExtent(_ rect: CGRect, along axis: CGPoint) -> CGFloat {
            abs(axis.x) * rect.width * 0.5 + abs(axis.y) * rect.height * 0.5
        }
        
        let iconHalfDepth = halfExtent(iconFrame, along: dir)
        let iconHalfBreadth = halfExtent(iconFrame, along: perp)
        let previewHalfDepth = halfExtent(previewBarFrame, along: dir)
        let previewHalfBreadth = halfExtent(previewBarFrame, along: perp)
        
        // 图标侧短边：压进“朝向预览”的边界约 1/5（即离边界 20% 深度）。
        let nearCenterOffset = iconHalfDepth * 0.6
        var nearCenter = CGPoint(
            x: iconCenter.x + dir.x * nearCenterOffset,
            y: iconCenter.y + dir.y * nearCenterOffset
        )
        
        // Dock 返回的 iconFrame 实际更接近“槽位框”，会比可视图标偏高。
        // 对底部 Dock 做一层经验校正。
        if dockPos == .bottom {
            let correctedY = iconFrame.minY + iconFrame.height * 0.35
            nearCenter.y = min(iconFrame.maxY - 2, max(nearCenter.y, correctedY))
        }
        
        // 预览侧长边：严格锚在“朝向图标”的预览边界。
        let farCenter = CGPoint(
            x: previewCenter.x - dir.x * previewHalfDepth,
            y: previewCenter.y - dir.y * previewHalfDepth
        )
        
        let nearHalf = max(20, min(36, iconHalfBreadth * 0.85))
        // 顶部长边严格对齐预览小窗底边宽度，不向两侧额外外扩。
        let farHalf = previewHalfBreadth
        
        return SafeTransitionZone(
            p1: CGPoint(x: nearCenter.x - perp.x * nearHalf, y: nearCenter.y - perp.y * nearHalf),
            p2: CGPoint(x: nearCenter.x + perp.x * nearHalf, y: nearCenter.y + perp.y * nearHalf),
            p3: CGPoint(x: farCenter.x + perp.x * farHalf, y: farCenter.y + perp.y * farHalf),
            p4: CGPoint(x: farCenter.x - perp.x * farHalf, y: farCenter.y - perp.y * farHalf)
        )
    }
    
    private func isMovingTowardPreviewArea(location: CGPoint, dockPos: DockPosition, iconFrame: CGRect) -> Bool {
        switch dockPos {
        case .bottom:
            // 仅在鼠标离开 Dock 图标“向上”进入预览区时启用保护，避免横向扫 Dock 时被强锁。
            return location.y <= (iconFrame.midY - 2)
        case .left:
            return location.x >= (iconFrame.midX + 2)
        case .right:
            return location.x <= (iconFrame.midX - 2)
        }
    }
    
}
