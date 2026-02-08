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
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        print("🚀 DockMinimize Version: ALIGNMENT_FIX_V2_DEPLOYED")
        // 初始化菜单栏控制器
        menuBarController = MenuBarController()
        
        // 检查辅助功能权限后启动 Dock 事件监听
        if AccessibilityManager.shared.isAccessibilityEnabled {
            startDockMonitoring()
            startHoverPreview()
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
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        dockEventMonitor?.stop()
        previewBarController?.stop()
    }
    
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        menuBarController?.showSettingsWindow()
        return true
    }
    
    @objc private func accessibilityStatusChanged() {
        if AccessibilityManager.shared.isAccessibilityEnabled {
            startDockMonitoring()
            startHoverPreview()
        } else {
            dockEventMonitor?.stop()
            dockEventMonitor = nil
            previewBarController?.stop()
            previewBarController = nil
        }
    }
    
    private func startDockMonitoring() {
        guard dockEventMonitor == nil else { return }
        dockEventMonitor = DockEventMonitor()
        dockEventMonitor?.start()
    }
    
    private func startHoverPreview() {
        guard previewBarController == nil else { return }
        previewBarController = PreviewBarController.shared
        previewBarController?.start()
    }
}
