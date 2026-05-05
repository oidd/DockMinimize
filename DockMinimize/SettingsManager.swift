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

enum UpdateCheckFrequency: String, CaseIterable {
    case never = "never"
    case everyLaunch = "everyLaunch"
    case weekly = "weekly"
    
    func displayName(t: (String, String) -> String) -> String {
        switch self {
        case .never:       return t("从不检查", "Never")
        case .everyLaunch: return t("每次启动", "On Launch")
        case .weekly:      return t("每周一次", "Weekly")
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
    private let kHotkeyBindings = "hotkeyBindings"
    private let kSuppressDockMinimizeOwnershipTip = "suppressDockMinimizeOwnershipTip"
    private let kSuppressSideBarOwnershipTip = "suppressSideBarOwnershipTip"
    private let kUpdateCheckFrequency = "updateCheckFrequency"
    private let kLastUpdateCheckDate = "lastUpdateCheckDate"
    
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
        didSet {
            UserDefaults.standard.set(enableOriginalPreview, forKey: "enableOriginalPreview")
            // ⭐️ 联动：原位预览关闭时，「聚焦预览」必须自动关闭（依赖关系）
            if !enableOriginalPreview && enableFocusPreview {
                enableFocusPreview = false
            }
        }
    }

    /// 「聚焦预览」(Focus Preview)：在显示原位预览时，对桌面其他区域加毛玻璃，
    /// 让用户的视觉聚焦到截图上。依赖 enableOriginalPreview = true 才能开启。
    @Published var enableFocusPreview: Bool {
        didSet { UserDefaults.standard.set(enableFocusPreview, forKey: "enableFocusPreview") }
    }

    
    @Published var blacklistedBundleIDs: [String] {

        didSet {
            defaults.set(blacklistedBundleIDs, forKey: kBlacklistedBundleIDs)
            NotificationCenter.default.post(name: .blacklistChanged, object: nil)
        }
    }

    @Published var hotkeyBindings: [AppHotkeyBinding] {
        didSet {
            if let data = try? JSONEncoder().encode(hotkeyBindings) {
                defaults.set(data, forKey: kHotkeyBindings)
            } else {
                defaults.removeObject(forKey: kHotkeyBindings)
            }
            NotificationCenter.default.post(name: .hotkeyBindingsChanged, object: nil)
        }
    }

    @Published var suppressDockMinimizeOwnershipTip: Bool {
        didSet {
            defaults.set(suppressDockMinimizeOwnershipTip, forKey: kSuppressDockMinimizeOwnershipTip)
        }
    }

    @Published var suppressSideBarOwnershipTip: Bool {
        didSet {
            defaults.set(suppressSideBarOwnershipTip, forKey: kSuppressSideBarOwnershipTip)
        }
    }
    
    @Published var updateCheckFrequency: UpdateCheckFrequency {
        didSet {
            defaults.set(updateCheckFrequency.rawValue, forKey: kUpdateCheckFrequency)
        }
    }
    
    @Published var lastUpdateCheckDate: Date? {
        didSet {
            if let date = lastUpdateCheckDate {
                defaults.set(date, forKey: kLastUpdateCheckDate)
            } else {
                defaults.removeObject(forKey: kLastUpdateCheckDate)
            }
        }
    }
    
    // MARK: - SideBar 联动（不持久化）
    @Published var sidebarDockExcludedBundleIDs: [String] = []
    @Published var sidebarHotkeyClaims: [String: SideBarHotkeyClaim] = [:]

    var sidebarManagedBundleIDs: [String] {
        sidebarDockExcludedBundleIDs
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

        // 加载「聚焦预览」设置（默认关闭，用户自行开启；
        // 且必须在「原位预览」开启的前提下才能生效——见 didSet 联动）
        self.enableFocusPreview = defaults.object(forKey: "enableFocusPreview") as? Bool ?? false
        
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

        // 加载快捷键绑定
        if let data = defaults.data(forKey: kHotkeyBindings),
           let bindings = try? JSONDecoder().decode([AppHotkeyBinding].self, from: data) {
            self.hotkeyBindings = bindings
        } else {
            self.hotkeyBindings = []
        }

        self.suppressDockMinimizeOwnershipTip = defaults.bool(forKey: kSuppressDockMinimizeOwnershipTip)
        self.suppressSideBarOwnershipTip = defaults.bool(forKey: kSuppressSideBarOwnershipTip)
        
        // 加载更新检查频率（默认从不检查）
        if let savedFreq = defaults.string(forKey: kUpdateCheckFrequency),
           let freq = UpdateCheckFrequency(rawValue: savedFreq) {
            self.updateCheckFrequency = freq
        } else {
            self.updateCheckFrequency = .never
        }
        
        // 加载上次自动检查时间
        self.lastUpdateCheckDate = defaults.object(forKey: kLastUpdateCheckDate) as? Date
        
        // 加载 SideBar 联动数据（主动读取一次，防止 SideBar 先启动的场景）
        SideBarBridge.shared.loadInitialState()
        applySideBarBridgeState()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleSideBarBridgeStateChanged),
            name: .sideBarBridgeStateChanged,
            object: nil
        )
    }
    
    /// 翻译方法
    func t(_ zh: String, _ en: String) -> String {
        return language == .simplifiedChinese ? zh : en
    }

    func shouldSuppressDockOwnershipTip(for owner: SideBarHotkeyClaim.HotkeyOwner) -> Bool {
        switch owner {
        case .dockminimize:
            return suppressDockMinimizeOwnershipTip
        case .sidebar:
            return suppressSideBarOwnershipTip
        }
    }

    func setSuppressDockOwnershipTip(_ suppressed: Bool, for owner: SideBarHotkeyClaim.HotkeyOwner) {
        switch owner {
        case .dockminimize:
            suppressDockMinimizeOwnershipTip = suppressed
        case .sidebar:
            suppressSideBarOwnershipTip = suppressed
        }
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

    @objc private func handleSideBarBridgeStateChanged() {
        applySideBarBridgeState()
    }

    private func applySideBarBridgeState() {
        sidebarDockExcludedBundleIDs = SideBarBridge.shared.dockExcludedBundleIDs
        sidebarHotkeyClaims = SideBarBridge.shared.hotkeyClaims
        DispatchQueue.global(qos: .userInitiated).async {
            DockIconCacheManager.shared.updateCache()
        }
        NotificationCenter.default.post(name: .blacklistChanged, object: nil)
    }

    /// 用于 Dock 点击、缩略图采集和预览条的跳过规则。
    func shouldSkipDockHandling(bundleID: String) -> Bool {
        if blacklistedBundleIDs.contains(bundleID) {
            return true
        }

        if let controlOwner = SideBarBridge.shared.controlOwner(for: bundleID) {
            return controlOwner == .sidebar
        }

        return sidebarDockExcludedBundleIDs.contains(bundleID)
    }

    /// 用于应用级快捷键路由的 SideBar 接管判断。
    func shouldForwardHotkeyToSideBar(bundleID: String) -> Bool {
        SideBarBridge.shared.shouldForwardHotkey(for: bundleID)
    }

    func addHotkeyApp(bundleID: String) {
        guard !hotkeyBindings.contains(where: { $0.bundleID == bundleID }) else { return }
        hotkeyBindings.append(AppHotkeyBinding(bundleID: bundleID, shortcut: nil))
    }

    func updateHotkeyShortcut(for bundleID: String, shortcut: KeyboardShortcut) {
        var updatedBindings = hotkeyBindings.map { binding -> AppHotkeyBinding in
            guard binding.bundleID != bundleID else { return binding }

            var updatedBinding = binding
            if updatedBinding.shortcut == shortcut {
                updatedBinding.shortcut = nil
            }
            return updatedBinding
        }

        if let index = updatedBindings.firstIndex(where: { $0.bundleID == bundleID }) {
            updatedBindings[index].shortcut = shortcut
        } else {
            updatedBindings.append(AppHotkeyBinding(bundleID: bundleID, shortcut: shortcut))
        }

        hotkeyBindings = updatedBindings
    }

    func clearHotkeyShortcut(for bundleID: String) {
        guard let index = hotkeyBindings.firstIndex(where: { $0.bundleID == bundleID }) else { return }
        hotkeyBindings[index].shortcut = nil
    }

    func removeHotkeyApp(bundleID: String) {
        hotkeyBindings.removeAll { $0.bundleID == bundleID }
    }
}
