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
    var isPreviewBarVisible: Bool = false {
        didSet {
            if !isPreviewBarVisible {
                // 预览条隐藏时清空安全区时效与运动状态
                safeZoneEnteredAt = nil
                lastSafeZoneSamplePos = nil
            }
        }
    }
    private let hoverDelay: TimeInterval = 0.02 // 降低延迟实现丝滑响应
    
    // MARK: - 漏斗安全区状态
    
    /// 鼠标进入安全区的时间戳（用于失效保护，超时则放弃锁定）
    private var safeZoneEnteredAt: Date?
    /// 安全区最大持续时间：超过则失效，避免用户停在中间无限锁定
    private let safeZoneMaxDuration: TimeInterval = 0.8
    /// 上一次落在安全区内的鼠标位置（用于反向运动检测）
    private var lastSafeZoneSamplePos: CGPoint?
    
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
        
        // ⭐️ 线程安全修复：本方法在 CGEvent tap 回调线程中被调用，原实现把所有逻辑派到全局 background 队列处理，
        //    但其中访问的 self.lastHoveredApp / self.previewBarFrame / self.isPreviewBarVisible 等普通 var 属性
        //    都不是线程安全的，与主线程对它们的写入会产生数据竞争 → 在某些时序下触发 SIGSEGV。
        //    现改为全主线程执行：每次鼠标移动只做几次坐标比较 + 字典查询，主线程完全够用，不会卡。
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            // 1. 基础状态计算 (提前计算以供后续决策)
            // ⭐️ 多显示器修复：以「鼠标当前所在屏幕」为参考，而不是固定 NSScreen.main
            //    location 是 CG 全局坐标 (主屏左上为原点)；先转换为 AppKit 全局坐标用于查屏幕
            let mouseScreen = ScreenLocator.screenContainingCG(point: location) ?? NSScreen.main
            let screenFrame = mouseScreen?.frame ?? CGRect(x: 0, y: 0, width: 1200, height: 800)
            let dockPos = DockPositionManager.shared.position(for: mouseScreen)
            let thickness = DockPositionManager.shared.dockDetectionThickness
            
            // ⭐️ 关键：把 CG 坐标和屏幕几何放在「同一坐标系」里比较
            //    - 屏幕底边在 CG 坐标里是 primaryMaxY - screenFrame.minY
            //    - 把鼠标 y 转成 AppKit 后，再用 AppKit 几何判断更直观
            let mouseAK = ScreenLocator.appKitPoint(fromCGGlobal: location)
            
            let inDock: Bool = {
                switch dockPos {
                case .bottom:
                    // AppKit 坐标 y 越小越靠近屏幕底部；底部 Dock 占据 [screenFrame.minY, screenFrame.minY + thickness]
                    return mouseAK.y >= screenFrame.minY && mouseAK.y < (screenFrame.minY + thickness)
                case .left:
                    return mouseAK.x >= screenFrame.minX && mouseAK.x < (screenFrame.minX + thickness)
                case .right:
                    return mouseAK.x > (screenFrame.maxX - thickness) && mouseAK.x <= screenFrame.maxX
                }
            }()

            
            let currentBundleId = inDock ? DockIconCacheManager.shared.getBundleId(at: location) : nil
            
            // 2. 预览条交互与动态安全区域保护
            if self.isPreviewBarVisible && !self.previewBarFrame.isEmpty {
                // A. 如果鼠标在预览条内，维持现状
                if self.previewBarFrame.contains(location) {
                    self.delegate?.hoverEventMonitor(self, didMoveInPreviewBar: location)
                    self.safeZoneEnteredAt = nil
                    self.lastSafeZoneSamplePos = nil
                    return
                }
                
                // B. 鼠标位于图标 -> 预览条的「漏斗」安全区时，保持当前 App 锁定
                if let bundleId = self.lastHoveredApp,
                   let iconFrame = self.getDockIconFrame(for: bundleId),
                   let safeZone = self.buildSafeTransitionZone(
                        dockPos: dockPos,
                        screen: screenFrame,
                        iconFrame: iconFrame,
                        mouseAnchor: location
                   ) {

                    if self.isMovingTowardPreviewArea(location: location, dockPos: dockPos, iconFrame: iconFrame),
                       safeZone.contains(location) {


                        
                        let now = Date()
                        // —— 时效保护：超过 maxDuration 仍未进入小窗，认为用户其实没在去预览的路上
                        if let enteredAt = self.safeZoneEnteredAt,
                           now.timeIntervalSince(enteredAt) > self.safeZoneMaxDuration {
                            self.safeZoneEnteredAt = nil
                            self.lastSafeZoneSamplePos = nil
                            // 不 return，让后续逻辑处理图标切换
                        } else {
                            // —— 反向运动检测：与朝向预览的方向反向（dot < 0）即视为放弃
                            if let prev = self.lastSafeZoneSamplePos {
                                let mvx = location.x - prev.x
                                let mvy = location.y - prev.y
                                // 仅当位移足够大时判定（噪声过滤）
                                if (mvx * mvx + mvy * mvy) > 4 {
                                    let dirVec = self.previewDirection(dockPos: dockPos)
                                    let dot = mvx * dirVec.x + mvy * dirVec.y
                                    if dot < -0.5 {
                                        self.safeZoneEnteredAt = nil
                                        self.lastSafeZoneSamplePos = nil
                                        // 同样不 return，让外层切换/退出 Dock 逻辑接手
                                        // 走到这里继续执行下方判断
                                        // 但若鼠标仍在 Dock 内，会切到邻居图标——这是预期行为
                                        // 因此直接 break 出 if，落到 step 3
                                    } else {
                                        if self.safeZoneEnteredAt == nil {
                                            self.safeZoneEnteredAt = now
                                        }
                                        self.lastSafeZoneSamplePos = location
                                        self.cancelHoverTimer()
                                        return
                                    }
                                } else {
                                    // 位移过小（用户基本没动），保持锁定
                                    if self.safeZoneEnteredAt == nil {
                                        self.safeZoneEnteredAt = now
                                    }
                                    self.lastSafeZoneSamplePos = location
                                    self.cancelHoverTimer()
                                    return
                                }
                            } else {
                                // 首次进入安全区
                                self.safeZoneEnteredAt = now
                                self.lastSafeZoneSamplePos = location
                                self.cancelHoverTimer()
                                return
                            }
                        }
                    } else {
                        // 离开安全区域：清空状态，让常规逻辑接管
                        self.safeZoneEnteredAt = nil
                        self.lastSafeZoneSamplePos = nil
                    }
                }
            }

            
            // 3. Dock 边界处理与图标更新
            if !inDock {
                self.cancelHoverTimer()
                if self.lastHoveredApp != nil {
                    self.lastHoveredApp = nil
                    self.delegate?.hoverEventMonitorDidExitDock(self)
                }
                return
            }
            
            if let bundleId = currentBundleId {
                if bundleId != self.lastHoveredApp {
                    let now = Date()
                    // ⭐️ 极致优化：将冷却时间压缩至 20ms (约单帧间隔)，实现极致跟手
                    if now.timeIntervalSince(self.lastHoverTriggerTime) < 0.02 {
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
                    self.delegate?.hoverEventMonitorDidExitDock(self)
                }
            }
        }
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
    
    /// 漏斗形「安全过渡区」构建。
    ///
    /// 几何设计（方案 B）：
    ///   - **near 端中心**：以 iconFrame 远离预览那条边为基准，朝预览方向偏移 0.7×iconDepth，
    ///     落在「图标可视上沿」处。X/perp 中心默认用 iconFrame 的中心（不跟随鼠标，避免抖动）。
    ///   - **far 端中心**：锚到 previewBarFrame 朝图标那条边的中心 X。
    ///   - **nearHalf**（漏斗宽口）= iconHalfBreadth + 14px，覆盖图标 + 横向抖动余量。
    ///   - **farHalf**（漏斗窄口）= clamp(3×iconHalfBreadth, nearHalf, previewHalfBreadth)。
    ///
    /// **放大模式补偿**：当 `magnificationScale > 1.05` 时，认为缓存 iconFrame 与视觉位置可能错位，
    /// 此时把漏斗的"几何中心"沿 Dock 长轴方向偏到鼠标位置上 —— 但只在鼠标偏离 iconFrame 中心
    /// 超过 iconHalfBreadth × 1.5 时才生效（避免鼠标在图标内小幅移动时漏斗也跟着抖）。
    ///
    /// 防御：对异常 iconFrame 直接放弃保护，避免顶点跑飞。
    private func buildSafeTransitionZone(
        dockPos: DockPosition,
        screen: CGRect,
        iconFrame: CGRect,
        mouseAnchor: CGPoint
    ) -> SafeTransitionZone? {
        guard !previewBarFrame.isEmpty else { return nil }
        
        // —— 防御 ①：iconFrame 异常拒绝
        let maxIconSide: CGFloat = 200
        guard iconFrame.width > 1, iconFrame.height > 1,
              iconFrame.width <= maxIconSide, iconFrame.height <= maxIconSide,
              screen.insetBy(dx: -50, dy: -50).contains(CGPoint(x: iconFrame.midX, y: iconFrame.midY)) else {
            return nil
        }
        
        // —— 1. 计算各方向的标量坐标
        let farEndPos: CGFloat       // 沿 dir 方向、远端（远离预览）的标量
        var perpCenter: CGFloat      // 沿 perp 方向、漏斗几何中心（默认 iconFrame 中心）
        let iconDepth: CGFloat
        let iconHalfBreadth: CGFloat
        
        switch dockPos {
        case .bottom:
            farEndPos = iconFrame.maxY
            perpCenter = iconFrame.midX
            iconDepth = iconFrame.height
            iconHalfBreadth = iconFrame.width / 2
        case .left:
            farEndPos = iconFrame.minX
            perpCenter = iconFrame.midY
            iconDepth = iconFrame.width
            iconHalfBreadth = iconFrame.height / 2
        case .right:
            farEndPos = iconFrame.maxX
            perpCenter = iconFrame.midY
            iconDepth = iconFrame.width
            iconHalfBreadth = iconFrame.height / 2
        }
        
        // —— 防御 ②：槽位深度合理性
        guard iconDepth < 200, iconDepth > 1 else { return nil }
        
        // —— 2. 放大模式补偿：缓存 iconFrame 的 perp 中心可能与视觉位置错位。
        // 当鼠标显著偏离 iconFrame 中心（说明这个图标实际被放大并平移了），用鼠标位置纠偏 perpCenter。
        // 阈值 = iconHalfBreadth × 1.5：鼠标在图标内部小幅移动不会触发漂移。
        let scale = DockPositionManager.shared.magnificationScale
        if scale > 1.05 {
            let mouseInPerp: CGFloat
            switch dockPos {
            case .bottom: mouseInPerp = mouseAnchor.x
            case .left, .right: mouseInPerp = mouseAnchor.y
            }
            let drift = mouseInPerp - perpCenter
            if abs(drift) > iconHalfBreadth * 1.5 {
                // 把漏斗中心拉到鼠标位置（让漏斗"对齐"被放大的图标视觉中心）
                perpCenter = mouseInPerp
            }
        }
        
        // —— 3. near 端深度：从 farEnd 朝预览方向偏移 0.7 × iconDepth = 图标可视上沿
        let visualOffset = iconDepth * 0.7
        let nearDepthPos: CGFloat
        switch dockPos {
        case .bottom: nearDepthPos = farEndPos - visualOffset   // CG: 朝上=减
        case .left:   nearDepthPos = farEndPos + visualOffset
        case .right:  nearDepthPos = farEndPos - visualOffset
        }
        
        // —— 4. far 端：锚到 previewBarFrame 朝图标那条边
        let previewCenter = CGPoint(x: previewBarFrame.midX, y: previewBarFrame.midY)
        let previewHalfDepth: CGFloat
        let previewHalfBreadth: CGFloat
        switch dockPos {
        case .bottom:
            previewHalfDepth = previewBarFrame.height / 2
            previewHalfBreadth = previewBarFrame.width / 2
        case .left, .right:
            previewHalfDepth = previewBarFrame.width / 2
            previewHalfBreadth = previewBarFrame.height / 2
        }
        
        let farDepthPos: CGFloat
        switch dockPos {
        case .bottom: farDepthPos = previewCenter.y + previewHalfDepth
        case .left:   farDepthPos = previewCenter.x - previewHalfDepth
        case .right:  farDepthPos = previewCenter.x + previewHalfDepth
        }
        
        // —— 5. nearHalf / farHalf
        var nearHalf: CGFloat = iconHalfBreadth + 14
        var farHalf: CGFloat = min(previewHalfBreadth, max(nearHalf, iconHalfBreadth * 3.0))
        
        // —— 屏幕边缘约束（防止 Finder 在边角时画到屏幕外造成扭曲）
        switch dockPos {
        case .bottom:
            nearHalf = min(nearHalf, max(8, perpCenter - screen.minX), max(8, screen.maxX - perpCenter))
            farHalf  = min(farHalf,  max(8, perpCenter - screen.minX), max(8, screen.maxX - perpCenter))
        case .left, .right:
            nearHalf = min(nearHalf, max(8, perpCenter - screen.minY), max(8, screen.maxY - perpCenter))
            farHalf  = min(farHalf,  max(8, perpCenter - screen.minY), max(8, screen.maxY - perpCenter))
        }
        // 保证不反向漏斗
        if farHalf < nearHalf { farHalf = nearHalf }
        
        // —— 6. 构造 4 个顶点
        let nearLeftPerp = perpCenter - nearHalf
        let nearRightPerp = perpCenter + nearHalf
        let farLeftPerp = perpCenter - farHalf
        let farRightPerp = perpCenter + farHalf
        
        let p1: CGPoint, p2: CGPoint, p3: CGPoint, p4: CGPoint
        switch dockPos {
        case .bottom:
            p1 = CGPoint(x: nearLeftPerp,  y: nearDepthPos)
            p2 = CGPoint(x: nearRightPerp, y: nearDepthPos)
            p3 = CGPoint(x: farRightPerp,  y: farDepthPos)
            p4 = CGPoint(x: farLeftPerp,   y: farDepthPos)
        case .left:
            p1 = CGPoint(x: nearDepthPos, y: nearLeftPerp)
            p2 = CGPoint(x: nearDepthPos, y: nearRightPerp)
            p3 = CGPoint(x: farDepthPos,  y: farRightPerp)
            p4 = CGPoint(x: farDepthPos,  y: farLeftPerp)
        case .right:
            p1 = CGPoint(x: nearDepthPos, y: nearLeftPerp)
            p2 = CGPoint(x: nearDepthPos, y: nearRightPerp)
            p3 = CGPoint(x: farDepthPos,  y: farRightPerp)
            p4 = CGPoint(x: farDepthPos,  y: farLeftPerp)
        }
        
        return SafeTransitionZone(p1: p1, p2: p2, p3: p3, p4: p4)
    }



    
    /// 判断鼠标是否「已经离开图标本体、朝预览方向移动」。
    /// 阈值收紧到「图标外缘 -1px」，让保护在鼠标越过图标边的瞬间立即生效，
    /// 消灭老版本「图标顶边到中线」之间的 30px 裸奔区。
    private func isMovingTowardPreviewArea(location: CGPoint, dockPos: DockPosition, iconFrame: CGRect) -> Bool {
        switch dockPos {
        case .bottom:
            return location.y <= (iconFrame.maxY - 1)
        case .left:
            return location.x >= (iconFrame.minX + 1)
        case .right:
            return location.x <= (iconFrame.maxX - 1)
        }
    }
    
    /// 朝预览方向的单位向量（用于反向运动检测）。
    private func previewDirection(dockPos: DockPosition) -> CGPoint {
        switch dockPos {
        case .bottom: return CGPoint(x: 0, y: -1) // 屏幕坐标 y 向上为负
        case .left:   return CGPoint(x: 1, y: 0)
        case .right:  return CGPoint(x: -1, y: 0)
        }
    }
    
}

