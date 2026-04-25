//
//  AccessibilityManager.swift
//  DockMinimize
//

import Cocoa
import ApplicationServices

extension Notification.Name {
    static let accessibilityStatusChanged = Notification.Name("accessibilityStatusChanged")
}

class AccessibilityManager: ObservableObject {
    static let shared = AccessibilityManager()
    
    @Published var isAccessibilityEnabled: Bool = false
    private var checkTimer: Timer?
    
    private init() {
        checkAccessibilityStatus()
        startMonitoringAccessibility()
    }
    
    deinit {
        checkTimer?.invalidate()
    }
    
    /// 检查辅助功能权限状态
    func checkAccessibilityStatus() {
        let enabled = AXIsProcessTrusted()
        if enabled != isAccessibilityEnabled {
            isAccessibilityEnabled = enabled
            NotificationCenter.default.post(name: .accessibilityStatusChanged, object: nil)
        }
    }
    
    /// 请求辅助功能权限
    func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }
    
    /// 打开系统辅助功能设置
    func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
    
    /// 重启应用
    func restartApp() {
        let url = URL(fileURLWithPath: Bundle.main.resourcePath!)
        let path = url.deletingLastPathComponent().deletingLastPathComponent().path
        let task = Process()
        task.launchPath = "/usr/bin/open"
        task.arguments = [path]
        task.launch()
        NSApp.terminate(nil)
    }
    
    /// 开始监控权限状态变化
    private func startMonitoringAccessibility() {
        // 恢复到正常的 1 秒检测一次，仅用于更新 UI 状态。
        // 因为真正的“安全性崩溃防护”已经移交到了 10ms 超时的 EventTap 内部逻辑。
        checkTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.checkAccessibilityStatus()
        }
    }
}
