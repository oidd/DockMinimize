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
}
