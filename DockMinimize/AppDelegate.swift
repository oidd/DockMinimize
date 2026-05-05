//
//  AppDelegate.swift
//  DockMinimize
//
//  Created by Dock Minimize
//

import Cocoa
import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
    private var menuBarController: MenuBarController?
    private var dockEventMonitor: DockEventMonitor?
    private var previewBarController: PreviewBarController?
    private var hotkeyMonitor: HotkeyMonitor?
    private let dockOwnershipTipController = DockOwnershipTipController.shared
    
    /// EventTap 健康检查定时器
    private var healthCheckTimer: Timer?
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        print("🚀 DockMinimize Version: CRASH_FIX_V3")
        
        // ⭐️ 注册全局崩溃处理器（在所有其它初始化之前）
        setupCrashHandlers()
        
        // 初始化菜单栏控制器
        menuBarController = MenuBarController()
        SideBarBridge.shared.start(with: SettingsManager.shared.hotkeyBindings)
        dockOwnershipTipController.start()
        
        // 检查辅助功能权限后启动 Dock 事件监听

        if AccessibilityManager.shared.isAccessibilityEnabled {
            startDockMonitoring()
            startHoverPreview()
            startHotkeyMonitoring()
        }
        
        // 仅在首次启动时自动弹出设置面板
        let hasLaunchedBefore = UserDefaults.standard.bool(forKey: "hasLaunchedBefore")
        if !hasLaunchedBefore {
            menuBarController?.showSettingsWindow()
            UserDefaults.standard.set(true, forKey: "hasLaunchedBefore")
        }
        
        // 监听权限变化
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(accessibilityStatusChanged),
            name: .accessibilityStatusChanged,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(hotkeyBindingsChanged),
            name: .hotkeyBindingsChanged,
            object: nil
        )
        
        // ⭐️ 启动 EventTap 健康检查定时器（每 30 秒检查一次）
        startHealthCheck()
        
        // 按用户设置执行后台静默更新检查（仅在有新版本时弹窗）
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            UpdateChecker.shared.performScheduledCheckIfNeeded()
        }
        
        DebugLogger.shared.log("🚀 Application launched successfully")
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        DebugLogger.shared.log("👋 Application will terminate (normal exit)")
        DebugLogger.shared.flush()
        
        healthCheckTimer?.invalidate()
        healthCheckTimer = nil
        dockEventMonitor?.stop()
        previewBarController?.stop()
        hotkeyMonitor?.stop()
        SideBarBridge.shared.stop()
    }
    
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        menuBarController?.showSettingsWindow()
        return true
    }
    
    @objc private func accessibilityStatusChanged() {
        if AccessibilityManager.shared.isAccessibilityEnabled {
            startDockMonitoring()
            startHoverPreview()
            startHotkeyMonitoring()
        } else {
            dockEventMonitor?.stop()
            dockEventMonitor = nil
            previewBarController?.stop()
            previewBarController = nil
            hotkeyMonitor?.stop()
            hotkeyMonitor = nil
        }
    }

    @objc private func hotkeyBindingsChanged() {
        guard AccessibilityManager.shared.isAccessibilityEnabled else { return }
        startHotkeyMonitoring()
        hotkeyMonitor?.reloadBindings()
    }
    
    private func startDockMonitoring() {
        guard dockEventMonitor == nil else { return }
        dockEventMonitor = DockEventMonitor()
        dockEventMonitor?.start()
    }
    
    private func startHoverPreview() {
        guard previewBarController == nil else { return }
        previewBarController = PreviewBarController.shared
        // ⭐️ 启动后延迟 0.8 秒再启动 hover 监听
        // 原因：刚启动时 SwiftUI/AppKit 资源、字体缓存、NSVisualEffectView 材质引擎等还在初始化，
        //     如果用户立即把鼠标停在 Dock 图标上触发预览条创建，可能因为某些资源未就绪而崩溃。
        //     延迟启动给系统留出 cold-start 缓冲，提高启动稳定性。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            self?.previewBarController?.start()
        }
    }

    private func startHotkeyMonitoring() {
        if hotkeyMonitor == nil {
            hotkeyMonitor = HotkeyMonitor.shared
        }
        hotkeyMonitor?.start()
    }
    
    // MARK: - 崩溃保护
    
    /// 注册全局崩溃处理器
    private func setupCrashHandlers() {
        // 1. ObjC 异常处理
        NSSetUncaughtExceptionHandler { exception in
            let logger = DebugLogger.shared
            logger.logCritical("Uncaught exception: \(exception.name.rawValue)")
            logger.logCritical("Reason: \(exception.reason ?? "unknown")")
            // ⭐️ 增强：记录完整栈帧（不再 prefix(10)），方便定位代码行
            logger.logCritical("Stack: \(exception.callStackSymbols.joined(separator: "\n"))")
            logger.flush()
        }
        
        // 2. Unix 信号处理（SIGSEGV、SIGABRT 等严重崩溃）
        let signals: [Int32] = [SIGSEGV, SIGABRT, SIGBUS, SIGFPE, SIGILL, SIGTRAP]
        for sig in signals {
            signal(sig) { signalNumber in
                let logger = DebugLogger.shared
                logger.logCritical("Fatal signal received: \(signalNumber)")
                // ⭐️ 增强：信号崩溃也记录调用栈
                let stack = Thread.callStackSymbols.joined(separator: "\n")
                logger.logCritical("Crash stack:\n\(stack)")
                logger.flush()
                // 还原默认处理并重新触发（产生正常的崩溃报告）
                signal(signalNumber, SIG_DFL)
                raise(signalNumber)
            }
        }
    }
    
    // MARK: - EventTap 健康检查
    
    /// 每 30 秒检查 EventTap 是否还活着，如果死了就重建
    private func startHealthCheck() {
        healthCheckTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            
            // 检查 DockEventMonitor
            if let monitor = self.dockEventMonitor, !monitor.isAlive() {
                DebugLogger.shared.logCritical("DockEventMonitor EventTap is dead! Rebuilding...")
                monitor.stop()
                self.dockEventMonitor = nil
                self.startDockMonitoring()
            }
            
            // 检查 HoverEventMonitor（通过 PreviewBarController 间接检查）
            if let controller = self.previewBarController, !controller.isHoverMonitorAlive() {
                DebugLogger.shared.logCritical("HoverEventMonitor EventTap is dead! Rebuilding...")
                controller.stop()
                self.previewBarController = nil
                self.startHoverPreview()
            }

            if let monitor = self.hotkeyMonitor,
               monitor.hasRegisteredHotkeys,
               !monitor.isAlive() {
                DebugLogger.shared.logCritical("HotkeyMonitor EventTap is dead! Rebuilding...")
                monitor.stop()
                self.hotkeyMonitor = nil
                self.startHotkeyMonitoring()
            }
        }
    }
}
