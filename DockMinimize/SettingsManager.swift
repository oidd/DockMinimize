//
//  SettingsManager.swift
//  DockMinimize
//

import Foundation
import Cocoa
import ServiceManagement

extension Notification.Name {
    static let menuBarIconVisibilityChanged = Notification.Name("menuBarIconVisibilityChanged")
    static let operationModeChanged = Notification.Name("operationModeChanged")
    static let languageChanged = Notification.Name("languageChanged")
    static let hoverPreviewChanged = Notification.Name("hoverPreviewChanged")
    static let blacklistChanged = Notification.Name("blacklistChanged")
}

enum AppLanguage: String, CaseIterable {
    case english = "en"
    case simplifiedChinese = "zh-Hans"
    
    var displayName: String {
        switch self {
        case .english:
            return "English"
        case .simplifiedChinese:
            return "简体中文"
        }
    }
}

class SettingsManager: ObservableObject {
    static let shared = SettingsManager()
    
    private let defaults = UserDefaults.standard
    
    private let kLaunchAtLogin = "launchAtLogin"
    private let kShowInMenuBar = "showInMenuBar"
    private let kLanguage = "appLanguage"
    private let kHoverPreviewEnabled = "hoverPreviewEnabled"
    private let kBlacklistedBundleIDs = "blacklistedBundleIDs"
    
    // Removed OperationMode property
    
    @Published var launchAtLogin: Bool {
        didSet {
            defaults.set(launchAtLogin, forKey: kLaunchAtLogin)
            updateLaunchAtLogin()
        }
    }
    
    @Published var showInMenuBar: Bool {
        didSet {
            defaults.set(showInMenuBar, forKey: kShowInMenuBar)
            NotificationCenter.default.post(name: .menuBarIconVisibilityChanged, object: nil)
        }
    }
    
    @Published var language: AppLanguage {
        didSet {
            defaults.set(language.rawValue, forKey: kLanguage)
            NotificationCenter.default.post(name: .languageChanged, object: nil)
        }
    }
    
    @Published var hoverPreviewEnabled: Bool {
        didSet {
            defaults.set(hoverPreviewEnabled, forKey: kHoverPreviewEnabled)
            NotificationCenter.default.post(name: .hoverPreviewChanged, object: nil)
        }
    }
    
    @Published var enableIndependentWindowControl: Bool {
        didSet {
            defaults.set(enableIndependentWindowControl, forKey: "enableIndependentWindowControl")
        }
    }
    
    /// 当开启时，显示大图预览（原位/原尺寸）。当关闭时，不显示大图。
    @Published var enableOriginalPreview: Bool {
        didSet { UserDefaults.standard.set(enableOriginalPreview, forKey: "enableOriginalPreview") }
    }
    
    @Published var blacklistedBundleIDs: [String] {
        didSet {
            defaults.set(blacklistedBundleIDs, forKey: kBlacklistedBundleIDs)
            NotificationCenter.default.post(name: .blacklistChanged, object: nil)
        }
    }
    
    // MARK: - SideBar 联动（临时黑名单，不持久化）
    @Published var sidebarManagedBundleIDs: [String] = []
    
    private init() {
        // 加载菜单栏显示
        if defaults.object(forKey: kShowInMenuBar) == nil {
            defaults.set(true, forKey: kShowInMenuBar)
        }
        self.showInMenuBar = defaults.bool(forKey: kShowInMenuBar)
        
        // 加载开机启动
        self.launchAtLogin = defaults.bool(forKey: kLaunchAtLogin)
        
        // 加载语言设置
        if let savedLang = defaults.string(forKey: kLanguage), let lang = AppLanguage(rawValue: savedLang) {
            self.language = lang
        } else {
            // 默认匹配系统语言
            let currentLocale = Locale.current.identifier
            if currentLocale.contains("zh") {
                self.language = .simplifiedChinese
            } else {
                self.language = .english
            }
        }
        
        self.enableOriginalPreview = defaults.object(forKey: "enableOriginalPreview") as? Bool ?? true
        
        // 加载悬停预览设置（默认开启）
        if defaults.object(forKey: kHoverPreviewEnabled) == nil {
            defaults.set(true, forKey: kHoverPreviewEnabled)
        }
        self.hoverPreviewEnabled = defaults.bool(forKey: kHoverPreviewEnabled)
        
        // 加载子窗口独立控制设置（默认开启）
        if defaults.object(forKey: "enableIndependentWindowControl") == nil {
            defaults.set(true, forKey: "enableIndependentWindowControl")
        }
        self.enableIndependentWindowControl = defaults.bool(forKey: "enableIndependentWindowControl")
        
        // 加载黑名单
        self.blacklistedBundleIDs = defaults.stringArray(forKey: kBlacklistedBundleIDs) ?? []
        
        // 加载 SideBar 联动数据（主动读取一次，防止 SideBar 先启动的场景）
        loadSideBarManagedApps()
        
        // 监听 SideBar 的跨进程广播
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(handleSideBarNotification),
            name: NSNotification.Name("com.ivean.SideBar.managedAppsDidChange"),
            object: nil
        )
    }
    
    /// 翻译方法
    func t(_ zh: String, _ en: String) -> String {
        return language == .simplifiedChinese ? zh : en
    }
    
    private func updateLaunchAtLogin() {
        do {
            if launchAtLogin {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            print("Failed to update launch at login: \(error)")
        }
    }
    
    func getLaunchAtLoginStatus() -> Bool {
        return SMAppService.mainApp.status == .enabled
    }
    
    func openDockSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.dock") {
            NSWorkspace.shared.open(url)
        }
    }
    
    // MARK: - SideBar 联动接收方
    
    @objc private func handleSideBarNotification() {
        loadSideBarManagedApps()
    }
    
    /// 从共享文件读取 SideBar 当前管理的应用列表
    private func loadSideBarManagedApps() {
        let filePath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/ivean.shared/sidebar_managed_apps.json")
        
        guard FileManager.default.fileExists(atPath: filePath.path) else {
            // 共享文件不存在（SideBar 未安装或未运行过），清空临时列表
            DispatchQueue.main.async {
                self.sidebarManagedBundleIDs = []
            }
            return
        }
        
        do {
            let data = try Data(contentsOf: filePath)
            if let bundleIDs = try JSONSerialization.jsonObject(with: data) as? [String] {
                DispatchQueue.main.async {
                    self.sidebarManagedBundleIDs = bundleIDs
                    // 通知各模块重新加载（复用现有的黑名单变更通知）
                    NotificationCenter.default.post(name: .blacklistChanged, object: nil)
                }
            }
        } catch {
            print("[DockMinimize] 读取 SideBar 共享文件失败: \(error)")
        }
    }
    
    /// 综合判定某个 BundleID 是否应被跳过（用户黑名单 + SideBar 临时托管）
    func shouldSkipApp(bundleID: String) -> Bool {
        return blacklistedBundleIDs.contains(bundleID) || sidebarManagedBundleIDs.contains(bundleID)
    }
}
