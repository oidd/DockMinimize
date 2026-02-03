//
//  MenuBarController.swift
//  DockMinimize
//

import Cocoa
import SwiftUI

class MenuBarController: NSObject {
    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?
    private var contextMenu: NSMenu?
    
    override init() {
        super.init()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        setupStatusItem()
        setupMenu()
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(updateStatusItemVisibility),
            name: .menuBarIconVisibilityChanged,
            object: nil
        )
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(setupMenu),
            name: .languageChanged,
            object: nil
        )
    }
    
    private func setupStatusItem() {
        guard let button = statusItem?.button else { return }
        
        // 优先尝试获取工程内置的图标
        if let image = NSImage(named: "menu_small") {
            image.size = NSSize(width: 18, height: 18)
            image.isTemplate = true
            button.image = image
        } else if let image = NSImage(named: "MenuBarIcon") {
            image.isTemplate = true
            button.image = image
        } else {
            // 最终兜底：系统图标
            button.image = NSImage(systemSymbolName: "square.3.layers.3d.down.right", accessibilityDescription: "Dock Minimize")
        }
        
        // 分别发送左键和右键点击事件
        button.action = #selector(handleStatusItemClick)
        button.target = self
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        
        updateStatusItemVisibility()
    }
    
    @objc private func setupMenu() {
        let menu = NSMenu()
        
        let settingsItem = NSMenuItem(
            title: SettingsManager.shared.t("设置", "Settings"),
            action: #selector(showSettingsWindow),
            keyEquivalent: ""
        )
        settingsItem.target = self
        settingsItem.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
        menu.addItem(settingsItem)
        
        menu.addItem(NSMenuItem.separator())
        
        let quitItem = NSMenuItem(
            title: SettingsManager.shared.t("退出", "Quit"),
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: ""
        )
        // 使用一个更统一的图标
        quitItem.image = NSImage(systemSymbolName: "xmark.circle", accessibilityDescription: nil)
        menu.addItem(quitItem)
        
        self.contextMenu = menu
    }
    
    @objc private func handleStatusItemClick() {
        let event = NSApp.currentEvent
        
        // 判定是否为右键点击（或者按住 Control 点击左键）
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            if let menu = contextMenu, let button = statusItem?.button {
                statusItem?.menu = menu
                button.performClick(nil) // 这一行触发系统弹出菜单
                statusItem?.menu = nil // 弹出后立即解绑，保证下次点击能重新被 handleStatusItemClick 捕获
            }
        } else {
            // 左键点击直达面板
            showSettingsWindow()
        }
    }
    
    @objc func showSettingsWindow() {
        NSApp.activate(ignoringOtherApps: true)
        
        if settingsWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 320, height: 460),
                styleMask: [.titled, .closable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.title = "Dock Minimize"
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.isMovableByWindowBackground = true
            window.standardWindowButton(.miniaturizeButton)?.isHidden = true
            window.standardWindowButton(.zoomButton)?.isHidden = true
            window.contentViewController = NSHostingController(rootView: SettingsView())
            window.level = .normal
            window.isReleasedWhenClosed = false
            settingsWindow = window
        }
        
        // 偏移显示，避免挡住系统的权限请求弹窗（系统弹窗通常居中）
        if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            let windowSize = settingsWindow?.frame.size ?? NSSize(width: 320, height: 460)
            
            // 默认居中位置
            var x = (screenFrame.width - windowSize.width) / 2
            var y = (screenFrame.height - windowSize.height) / 2
            
            // 向右下方向稍微偏移
            x += 160
            y -= 100
            
            settingsWindow?.setFrameOrigin(CGPoint(x: x + screenFrame.origin.x, y: y + screenFrame.origin.y))
        } else {
            settingsWindow?.center()
        }
        
        settingsWindow?.makeKeyAndOrderFront(nil)
        settingsWindow?.orderFrontRegardless()
    }
    
    private func closeSettingsWindow() {
        settingsWindow?.orderOut(nil)
    }
    
    @objc private func updateStatusItemVisibility() {
        statusItem?.isVisible = SettingsManager.shared.showInMenuBar
    }
}
