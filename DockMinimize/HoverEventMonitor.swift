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
    
    /// 最后一次触发悬停的时间（用于防抖）
    private var lastHoverTriggerTime: Date = Date.distantPast

    private func handleMouseMoved(event: CGEvent) {
        let location = event.location
        lastMousePosition = location
        
        if event.type == .tapDisabledByTimeout || event.type == .tapDisabledByUserInput {
            exit(0)
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
                
                // 2. 预览条交互与安全走廊保护
                if self.isPreviewBarVisible && !self.previewBarFrame.isEmpty {
                    // A. 如果鼠标在预览条内，维持现状
                    if self.previewBarFrame.contains(location) {
                        DispatchQueue.main.async { self.delegate?.hoverEventMonitor(self, didMoveInPreviewBar: location) }
                        semaphore.signal()
                        return
                    }
                    
                    // B. ⭐️ 核心锁定消除：如果鼠标已经明确移到了另一个图标上，强制打破锁定
                    if let currentId = currentBundleId, currentId != self.lastHoveredApp {
                        self.log.log("🔓 Lock broken: hovering on new app \(currentId)")
                        // 继续向下执行，不 return
                    } else if let iconPos = self.getDockIconPosition(for: self.lastHoveredApp ?? "") {
                        // C. 常规安全走廊锁定逻辑
                        let lockMargin: CGFloat = 40
                        
                        switch dockPos {
                        case .bottom:
                            let isWithinCorridor = location.x > (iconPos.x - lockMargin) && location.x < (iconPos.x + lockMargin)
                            if isWithinCorridor && location.y < (screen.height - 40) && location.y > (screen.height - 200) {
                                semaphore.signal()
                                return
                            }
                        case .left:
                            let isWithinCorridor = location.y > (iconPos.y - lockMargin) && location.y < (iconPos.y + lockMargin)
                            if isWithinCorridor && location.x >= thickness - 10 && location.x < 220 {
                                semaphore.signal()
                                return
                            }
                        case .right:
                            let isWithinCorridor = location.y > (iconPos.y - lockMargin) && location.y < (iconPos.y + lockMargin)
                            if isWithinCorridor && location.x <= (screen.width - thickness + 10) && location.x > (screen.width - 220) {
                                semaphore.signal()
                                return
                            }
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
}
