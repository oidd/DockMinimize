//
//  FinderSpecialHandler.swift
//  DockMinimize
//
//  Created by Dock Minimize (2026-04-29)
//
//  ╔═══════════════════════════════════════════════════════════════════════╗
//  ║   Finder 专属流水线（必读）                                              ║
//  ╠═══════════════════════════════════════════════════════════════════════╣
//  ║                                                                        ║
//  ║  Finder 在 macOS 中是「桌面外壳」，与普通 App 行为差异巨大。            ║
//  ║  以前的散落分支（5 个文件、6 处 if）已在多个 invariant 之间互相矛盾，   ║
//  ║  本文件统一收口，并固化以下 4 条不变量：                                ║
//  ║                                                                        ║
//  ║  I1. Finder 永不调 app.hide() / app.unhide()，只用 kAXMinimizedAttribute║
//  ║      原因：Finder 的「桌面」也是它的窗口，hide 会让桌面消失。           ║
//  ║                                                                        ║
//  ║  I2. Finder 的 frontmostApplication / kAXMain / kAXFocusedWindow       ║
//  ║      属性「不可信」—— 桌面窗口经常 Main=true、frontmost 经常是上一个   ║
//  ║      用户激活的 App。clickThumbnail 对 Finder 必须只信 isMinimized。   ║
//  ║                                                                        ║
//  ║  I3. Finder 多窗口反最小化必须「串行 + 主线程」，且                     ║
//  ║      setMinimized=false 全部发完后须等 ≥80ms 再发 SkyLight raise，     ║
//  ║      否则 Finder 会拒收后发的 setMinimized 写入（系统外壳特性）。       ║
//  ║                                                                        ║
//  ║  I4. Finder 不参与 reopenApplication —— 系统 reopen 对 Finder 等同于   ║
//  ║      「打开新 Finder 窗口」，会污染用户既有的最小化集合。               ║
//  ║                                                                        ║
//  ║  ─────────────────────────────────────────────────────────────────    ║
//  ║  本次修复对应的 4 个 bug：                                              ║
//  ║    Bug① 用户机器：点预览小窗后鼠标移到弹出窗口出现彩虹圈 → 缓解        ║
//  ║          （主因是用户 Finder 侧边栏挂网络盘，我们减少激活序列以降诱因）║
//  ║    Bug② 设置窗口可见时点预览小窗，DockMinimize 设置面板被弹到最前 → 修 ║
//  ║          （改 PreviewStateManager.activateWindow，先 NSApp.deactivate）║
//  ║    Bug③ 三个 Finder 窗口都最小化，第一次点 Dock 只出 1 个 → 修         ║
//  ║          （此处 toggleAll 改串行 + 80ms 延后 SkyLight raise）           ║
//  ║    Bug④ 蓝色指示条说窗口在桌面，点了反而最小化 → 修                    ║
//  ║          （shouldMinimizeOnClick 短路为 !isMinimized）                  ║
//  ╚═══════════════════════════════════════════════════════════════════════╝
//

import Cocoa
import ApplicationServices

enum FinderSpecialHandler {
    
    /// Finder 的 BundleID，统一引用此常量，避免散落字符串
    static let bundleId = "com.apple.finder"
    
    /// SkyLight raise 与 setMinimized 之间的延迟（秒）
    /// 实测：80ms 时三个独立窗口仍只能恢复 1~2 个（Finder 拒收）。
    /// 250ms 在用户场景下稳定恢复全部窗口。如果用户反馈仍偶发只出来部分窗口，
    /// 调到 0.35 即可（人眼连续性阈值 ~100ms 临界，但 minimize 动画本身就 200ms+，
    /// 所以延后 250ms 视觉上完全感知不到）。
    static let skylightRaiseDelay: TimeInterval = 0.25
    
    /// 该 BundleID 是否需要走 Finder 专属流水线
    static func handles(_ bundleId: String?) -> Bool {
        bundleId == FinderSpecialHandler.bundleId
    }
    
    // MARK: - I4: 不参与系统 Reopen
    
    /// DockEventMonitor 在「真正无可见窗口」时是否应该放行给系统触发 Reopen
    /// 对 Finder 始终返回 true（即「不要放行」），保证我们自己 toggleWindows
    static func shouldSkipReopen(for bundleId: String) -> Bool {
        return handles(bundleId)
    }
    
    // MARK: - I2: clickThumbnail 三态判定（基于 windowOnScreen 的可靠事实）
    
    /// 给 PreviewStateManager.clickThumbnail 用的 Finder 决策。
    ///
    /// 核心原则：**完全不依赖** frontmostApplication / kAXMain / kAXFocused
    /// （Finder 桌面窗口 Main=true 永真、我们的 popUp 预览条会让 frontmost 漂移、
    /// 第二次连点时 DockMinimize 自己可能短暂是 frontmost…全部不可信）。
    ///
    /// 我们用三个真正可靠的事实：
    ///   1. window.isMinimized：Dock 上有无「灰色缩进」标记
    ///   2. window.isOnScreen：CGWindowList 报告该窗口当前是否「在屏幕可见区域」
    ///      —— 注意：被 Safari 完全盖住时 macOS 仍认为 onScreen=true（在桌面坐标），
    ///        但「不可见」（被遮挡），所以 onScreen 实际等于「未最小化」，与 isMinimized 互补
    ///   3. 内存里的 lastActivatedWindowId：我们自己刚才点过的窗口 ID
    ///
    /// 决策（按优先级）：
    ///   - isMinimized=true                           → 恢复 (Activate)
    ///   - lastActivatedWindowId == windowId          → 最小化 (Minimize) ← 第二次连点必走这条
    ///   - 否则（窗口在桌面但不是我们刚激活的）         → 抬到前台 (Activate)
    ///
    /// 这样无论 frontmost 是 Finder、DockMinimize、还是 Safari，第二次点击都能稳定 minimize。
    static func shouldMinimizeOnClick(window: WindowThumbnailService.WindowInfo,
                                      lastActivatedWindowId: CGWindowID?) -> Bool {
        if window.isMinimized {
            return false  // 已最小化 → 恢复
        }
        // 第二次点击同一窗口：我们刚才激活过它，此时它必然在最前 → 该最小化
        if let last = lastActivatedWindowId, last == window.windowId {
            return true
        }
        // 窗口在桌面上但不是我们刚激活的（比如被 Safari 盖住）→ 抬到前台
        return false
    }
    
    // MARK: - 单窗口轻量激活（缓解 Bug①）
    
    /// 给 PreviewStateManager 用的 Finder 专属激活序列。
    /// 比通用 activateWindow 少 2 步：
    ///   - 不再设置 kAXMainAttribute=true（Finder 内部 ~16ms 自己会更新 Main）
    ///   - 不再在末尾重复调用 app.activate（避免给 Finder 进程主循环连续推 7 个状态变更）
    /// 这能显著降低用户机器（macOS ≤15、Finder 侧边栏挂网络盘场景）出彩虹球的概率。
    static func activateWindow(_ windowInfo: WindowThumbnailService.WindowInfo,
                               log: DebugLogger) {
        let windowId = windowInfo.windowId
        let pid = windowInfo.ownerPID
        
        // I1: 不调用 app.hide()/unhide()。Finder 不存在 hidden 状态。
        
        // 1. SkyLight 把 Finder 的目标窗口提到前台进程
        var psn = ProcessSerialNumber()
        if GetProcessForPID(pid, &psn) == noErr {
            _ = _SLPSSetFrontProcessWithOptions(&psn, windowId, SLPSMode.userGenerated.rawValue)
            makeKeyWindow(&psn, windowID: windowId)
        }
        
        // 2. 取消最小化（如有需要）
        if windowInfo.isMinimized {
            AXUIElementSetAttributeValue(windowInfo.axElement,
                                         kAXMinimizedAttribute as CFString,
                                         false as CFTypeRef)
        }
        
        // 3. Raise（让该窗口浮到 Finder 自己窗口序列的顶层）
        AXUIElementPerformAction(windowInfo.axElement, kAXRaiseAction as CFString)
        
        // 4. 一次温和的 activate，不带 ignoringOtherApps（避免抢焦点抢得太狠）
        if let app = NSRunningApplication(processIdentifier: pid) {
            app.activate(options: [])
        }
        
        log.log("✅ [Finder] Light-activated window \(windowId)")
    }
    
    // MARK: - I3: 多窗口反最小化（解决 Bug③）
    
    /// 给 WindowManager.toggleWindows / ensureWindowsVisible 用的 Finder 专属
    /// 「全部恢复」流程。
    ///
    /// 关键洞察（三轮迭代后定型）：之前所有基于 `kAXMinimizedAttribute=false` 的方案
    /// （并发 / 串行 30ms / 串行 250ms / 串行 400ms…）都因 Finder 在反最小化动画
    /// 期间冻结同进程的 AX 写入队列而**最多只能恢复 1 个窗口**。
    ///
    /// 终极方案：换技术路径，**用 AppleScript** 一次性恢复全部最小化窗口。
    /// AppleScript 走 Finder 自己的 OSA 引擎，不走 AX 写入队列，互相不会拒收。
    /// 命令：`tell application "Finder" to set collapsed of every window to false`
    ///
    /// 代价：首次执行会弹一次「DockMinimize 想要控制 Finder」的 macOS 自动化授权框，
    /// 用户点确定即可，之后永久授权。已在 Info.plist 加 NSAppleEventsUsageDescription，
    /// entitlements 里 `com.apple.security.automation.apple-events=true` 已存在。
    static func toggleAllRestore(windows: [WindowThumbnailService.WindowInfo],
                                 app: NSRunningApplication,
                                 log: DebugLogger) {
        // I1: 不调 app.unhide()，Finder 永远不 hidden
        
        let minimizedWindows = windows.filter { $0.isMinimized }
        guard !minimizedWindows.isEmpty else {
            // 已经全展开了，直接 raise + activate
            log.log("📂 [Finder] All windows already non-minimized, just raise primary.")
            raiseAndActivate(windows: windows, app: app, log: log)
            return
        }
        
        log.log("📂 [Finder] Restore via AppleScript for \(minimizedWindows.count) minimized windows")
        
        // 在后台线程跑 AppleScript，不阻塞主线程
        DispatchQueue.global(qos: .userInteractive).async {
            let source = """
            tell application "Finder"
                set collapsed of every window to false
            end tell
            """
            var errorDict: NSDictionary?
            if let scriptObject = NSAppleScript(source: source) {
                let result = scriptObject.executeAndReturnError(&errorDict)
                if let err = errorDict {
                    log.log("⚠️ [Finder] AppleScript restore failed: \(err). Falling back to AX serial.")
                    // 降级：AX 串行（最多恢复部分窗口，但有总比没有强）
                    DispatchQueue.main.async {
                        for window in minimizedWindows.reversed() {
                            _ = AXUIElementSetAttributeValue(window.axElement,
                                                             kAXMinimizedAttribute as CFString,
                                                             false as CFTypeRef)
                        }
                    }
                } else {
                    log.log("✅ [Finder] AppleScript restore success: \(result.stringValue ?? "")")
                }
            }
            
            // raise + activate 必须回主线程
            DispatchQueue.main.async {
                raiseAndActivate(windows: windows, app: app, log: log)
            }
        }
    }
    
    /// 仅 raise + activate 流程，不触碰 setMinimized
    private static func raiseAndActivate(windows: [WindowThumbnailService.WindowInfo],
                                         app: NSRunningApplication,
                                         log: DebugLogger) {
        // 温和的 activate（不带 ignoringOtherApps 避免抢焦点抢得太狠）
        app.activate(options: [])
        
        guard let primary = windows.first else { return }
        var psn = ProcessSerialNumber()
        if GetProcessForPID(app.processIdentifier, &psn) == noErr {
            _ = _SLPSSetFrontProcessWithOptions(&psn,
                                                primary.windowId,
                                                SLPSMode.userGenerated.rawValue)
            makeKeyWindow(&psn, windowID: primary.windowId)
        }
        AXUIElementPerformAction(primary.axElement, kAXRaiseAction as CFString)
    }
    
    /// 给 WindowManager.toggleWindows Finder 分支用的「全部最小化」流程。
    /// 串行 setMinimized=true（不需要 SkyLight 介入，无 Bug③ 类问题）。
    static func toggleAllMinimize(windows: [WindowThumbnailService.WindowInfo],
                                  log: DebugLogger) {
        for window in windows {
            if !window.isMinimized {
                _ = AXUIElementSetAttributeValue(window.axElement,
                                                 kAXMinimizedAttribute as CFString,
                                                 true as CFTypeRef)
            }
        }
        log.log("📂 [Finder] Minimized \(windows.count) windows")
    }
}
