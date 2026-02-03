//
//  SettingsView.swift
//  DockMinimize
//

import SwiftUI

struct SettingsView: View {
    @ObservedObject private var accessibilityManager = AccessibilityManager.shared
    @ObservedObject private var settingsManager = SettingsManager.shared
    @State private var showMinimizeTip = false
    
    // 当前选中的标签页
    @State private var selectedTab: SettingsTab = .permissions
    
    // 菜单枚举
    // 菜单枚举
    enum SettingsTab: String, CaseIterable {
        case permissions
        case general
        case smallWindowPreview
        case blacklist
        case about
        
        func iconName() -> String {
            switch self {
            case .permissions: return "lock.shield"
            case .general: return "gearshape"
            case .smallWindowPreview: return "eye"
            case .blacklist: return "nosign"
            case .about: return "info.circle"
            }
        }
        
        func displayName(t: (String, String) -> String) -> String {
            switch self {
            case .permissions: return t("权限设置", "Permissions")
            case .general: return t("常规设置", "General")
            case .smallWindowPreview: return t("小窗预览", "Small Window Preview")
            case .blacklist: return t("黑名单", "Blacklist")
            case .about: return t("关于", "About")
            }
        }
    }
    
    var body: some View {
        if #available(macOS 13.0, *) {
            NavigationSplitView {
                List(SettingsTab.allCases, id: \.self, selection: $selectedTab) { tab in
                    NavigationLink(value: tab) {
                        Label {
                            Text(tab.displayName(t: t))
                        } icon: {
                            Image(systemName: tab.iconName())
                        }
                    }
                }
                .navigationTitle("Dock Minimize")
                .safeAreaInset(edge: .bottom) {
                    Button(action: {
                        NSApp.terminate(nil)
                    }) {
                        Label(t("退出软件", "Quit App"), systemImage: "power.circle")
                            .foregroundColor(Color.red.opacity(0.8))
                    }
                    .buttonStyle(.plain)
                    .padding()
                }
                .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 220)
            } detail: {
                contentView
                    .background(Color(NSColor.windowBackgroundColor))
            }
            .frame(width: 700, height: 480) // 1. 缩小窗口尺寸
        } else {
            HStack(spacing: 0) {
                Text("Please upgrade to macOS 13+ for the best experience")
            }
        }
    }

    // MARK: - 内容视图
    
    private var contentView: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                Section(header: headerView) {
                    VStack(alignment: .leading, spacing: 20) {
                        switch selectedTab {
                        case .permissions:
                            permissionsContent
                        case .general:
                            generalSettingsContent
                        case .smallWindowPreview:
                            smallWindowPreviewContent
                        case .blacklist:
                            blacklistContent
                        case .about:
                            aboutRecommendations
                        }
                        
                        Spacer()
                    }
                    .padding(.horizontal, 32)
                    .padding(.bottom, 32)
                    .padding(.top, 12)
                }
            }
        }
    }
    
    private var headerView: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 顶部标题 (所有页共有)
            Text(selectedTab.displayName(t: t))
                .font(.system(size: 24, weight: .bold))
                .foregroundColor(.accentColor)
                .padding(.top, 12)
                .padding(.bottom, 10)
            
            // 软件信息 (仅关于页显示)
            if selectedTab == .about {
                aboutAppHeader
                    .padding(.bottom, 16)
            }
            
            Divider()
                .opacity(settingsManager.language == .simplifiedChinese ? 0.3 : 0.5)
        }
        .padding(.horizontal, 32)
        .background(Color(NSColor.windowBackgroundColor)) // 实色背景遮挡下方滚动内容
    }
    
    // MARK: - About Tab Sub-components
    
    private var aboutAppHeader: some View {
        HStack(spacing: 16) {
            if let appIcon = NSImage(named: "AppIcon") {
                Image(nsImage: appIcon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 64, height: 64)
                    .cornerRadius(12)
                    .shadow(color: Color.black.opacity(0.1), radius: 4, x: 0, y: 2)
            }
            
            VStack(alignment: .leading, spacing: 4) {
                Text("DockMinimize")
                    .font(.title2)
                    .bold()
                
                Text(t("在 macOS 上实现类似 Windows 系统的单击隐藏和显示窗口", "Single-click to hide and show windows on macOS, just like Windows."))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                
                Button(action: {
                    if let url = URL(string: "https://ivean.com/dockminimize/") {
                        NSWorkspace.shared.open(url)
                    }
                }) {
                    HStack(spacing: 4) {
                        Text(t("访问网站", "Visit Website"))
                        Image(systemName: "arrow.up.right")
                    }
                    .font(.caption)
                    .foregroundColor(.accentColor)
                }
                .buttonStyle(.plain)
                .padding(.top, 2)
            }
        }
    }
    
    private var aboutRecommendations: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(t("作者的奇思妙想", "Author's Whimsical Ideas"))
                .font(.footnote)
                .bold()
                .foregroundColor(.secondary)
                .padding(.top, 4)
            
            VStack(spacing: 12) {
                ForEach(recommendedToolsList) { tool in
                    RecommendationRow(tool: tool)
                }
            }
        }
    }
    
    private var recommendedToolsList: [RecommendedTool] {
        [
            RecommendedTool(
                name: t("流光倒计时", "Flux Timer"),
                slogan: t("一按一拉，静待流光。让时间流逝成为一种桌面美学。", "Pull to Focus. Flow to Finish. Turning every wait into a ceremony."),
                iconName: "flux_timer",
                url: "https://ivean.com/fluxtimer/"
            ),
            RecommendedTool(
                name: t("轻待办", "Light Todo"),
                slogan: t("极致轻量，随叫随到。让待办事项如灵感般轻盈。", "Minimalist, Always Ready. Making tasks as light as inspiration."),
                iconName: "light_todo",
                url: "https://ivean.com/lighttodo/"
            ),
            RecommendedTool(
                name: t("快速搜索", "Quick Search"),
                slogan: t("选中文本，双击快捷键，在页面上瞬间切换搜索方式。", "Instantly switch search engines with a double-click shortcut."),
                iconName: "quick_search",
                url: "https://www.ivean.com/quicksearch/"
            ),
            RecommendedTool(
                name: t("多次高亮查找", "Multi-Keyword Highlighter"),
                slogan: t("告别低效，开启专业的多词批量高亮检索新纪元。", "Efficient multi-keyword highlighting for faster information retrieval."),
                iconName: "highlighter",
                url: "https://ivean.com/highlighter/"
            ),
            RecommendedTool(
                name: t("极致护眼", "EyeCare Pro"),
                slogan: t("为你的眼睛，挑选一种舒适。全方位的护眼计划。", "A comprehensive eye protection plan for your vision."),
                iconName: "eyecare",
                url: "https://www.ivean.com/eyecarepro"
            )
        ]
    }
    
    // MARK: - 1. 权限设置内容
    
    private var permissionsContent: some View {
        VStack(spacing: 16) {
            permissionCard(
                title: t("辅助功能", "Accessibility"),
                desc: t("用于监听 Dock 图标点击和鼠标悬停事件。", "Monitor Dock icon clicks and hover events."),
                isEnabled: accessibilityManager.isAccessibilityEnabled,
                action: { accessibilityManager.requestAccessibility() }
            )
            
            permissionCard(
                title: t("屏幕录制", "Screen Recording"),
                desc: t("用于获取窗口的实时预览图。", "Capture window previews."),
                isEnabled: ScreenCaptureManager.shared.hasScreenCapturePermission(),
                action: { ScreenCaptureManager.shared.requestPermission() }
            )
            
            storagePermissionCard
        }
    }
    
    private func permissionCard(title: String, desc: String, isEnabled: Bool, action: @escaping () -> Void) -> some View {
        GroupBox {
            HStack(alignment: .center, spacing: 16) {
                Image(systemName: isEnabled ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 24))
                    .foregroundColor(isEnabled ? .green : .orange)
                    .frame(width: 32)
                
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.headline)
                    Text(desc)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                if !isEnabled {
                    Button(t("授权", "Grant")) { action() }
                        .controlSize(.small)
                        .buttonStyle(.borderedProminent)
                } else {
                    Text(t("已开启", "On"))
                        .foregroundColor(.secondary)
                }
            }
            .padding(8) // 增加内部 padding
        }
    }
    
    private var storagePermissionCard: some View {
        let isReady = CacheManager.shared.checkStoragePermission()
        return GroupBox {
            HStack(alignment: .center, spacing: 16) {
                Image(systemName: isReady ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 24))
                    .foregroundColor(isReady ? .green : .orange)
                    .frame(width: 32)
                
                VStack(alignment: .leading, spacing: 4) {
                    Text(t("临时存储", "Temp Storage"))
                        .font(.headline)
                    Text(t("缓存预览图到磁盘。", "Cache previews to disk."))
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    if let url = CacheManager.shared.getCacheURL() {
                        Text(url.path)
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                
                Spacer()
                
                Button(t("更改", "Change")) {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = false
                    panel.allowsMultipleSelection = false
                    panel.message = t("请选择存放缩略图缓存的文件夹", "Select a folder for thumbnail cache")
                    
                    if panel.runModal() == .OK, let url = panel.url {
                        CacheManager.shared.setCustomPath(url)
                    }
                }
                .controlSize(.small)
                .buttonStyle(.bordered)
            }
            .padding(8)
        }
    }

    // MARK: - 2. 常规设置内容
    
    private var generalSettingsContent: some View {
        VStack(spacing: 20) {
            // GroupBox 1: 启动与显示
            GroupBox {
                VStack(spacing: 0) {
                    toggleRow(
                        icon: "laptopcomputer",
                        title: t("开机自动启动", "Launch at Login"),
                        isOn: $settingsManager.launchAtLogin
                    )
                    
                    Divider().padding(.leading, 42)
                    
                    toggleRow(
                        icon: "menubar.rectangle",
                        title: t("在菜单栏显示图标", "Show Icon in Menu Bar"),
                        isOn: $settingsManager.showInMenuBar
                    )
                }
                .padding(.vertical, 4) // 只保留垂直 padding，移除水平 padding 以对齐
            }
            
            // GroupBox 2: 语言
            GroupBox {
                HStack {
                    Image(systemName: "globe")
                        .font(.system(size: 18))
                        .frame(width: 30, alignment: .center)
                        .foregroundColor(.accentColor)
                    
                    Text(t("语言 / Language", "Language"))
                        .font(.system(size: 14))
                    
                    Spacer()
                    
                    Picker("", selection: $settingsManager.language) {
                        ForEach(AppLanguage.allCases, id: \.self) { lang in
                            Text(lang.displayName).tag(lang)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(width: 120)
                }
                .padding(12)
            }
            
            if !settingsManager.showInMenuBar {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "info.circle.fill")
                        .foregroundColor(.blue)
                    Text(t("隐藏菜单栏图标后，您需要在访达(Finder)中再次运行该软件来打开此设置面板。", "Run from Finder to open settings if menu item is hidden."))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding()
            }
        }
    }

private func toggleRow(icon: String, title: String, isOn: Binding<Bool>) -> some View {
    HStack {
        Image(systemName: icon)
            .font(.system(size: 18))
            .frame(width: 30, alignment: .center) // 3. 统一图标宽度 30
            .foregroundColor(.accentColor)
        
        Text(title)
            .font(.system(size: 14))
        
        Spacer()
        
        Toggle("", isOn: isOn)
            .toggleStyle(.switch)
    }
    .padding(12)
}

// MARK: - 3. 小窗预览内容

private var smallWindowPreviewContent: some View {
    VStack(spacing: 20) {
        GroupBox {
            toggleRow(
                icon: "eye.fill", // 保持 fill 版本
                title: t("启用小窗预览", "Enable Small Window Preview"),
                isOn: $settingsManager.hoverPreviewEnabled
            )
            .padding(-8) // 抵消 GroupBox 默认 padding
            .onChange(of: settingsManager.hoverPreviewEnabled) { newValue in
                if newValue { PreviewBarController.shared.start() }
                else { PreviewBarController.shared.stop() }
            }
        }
        
        if settingsManager.hoverPreviewEnabled {
            GroupBox {
                VStack(spacing: 0) {
                    toggleRowWithDesc(
                        title: t("子窗口独立收起/展开", "Independent Sub-window Control"),
                        desc: t("点击预览窗口以操作特定子窗口。", "Click sub-windows to manage specifically."),
                        isOn: $settingsManager.enableIndependentWindowControl
                    )
                    
                    Divider().padding(.leading, 16)
                    
                    toggleRowWithDesc(
                        title: t("原位预览", "Original Preview"),
                        desc: t("在窗口原本消失的位置显示大图预览。", "Show large preview at original window location."),
                        isOn: $settingsManager.enableOriginalPreview
                    )
                }
                .padding(4)
            }
        }
    }
}

private func toggleRowWithDesc(title: String, desc: String, isOn: Binding<Bool>) -> some View {
    HStack {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.body)
            Text(desc).font(.caption).foregroundColor(.secondary)
        }
        Spacer()
        Toggle("", isOn: isOn)
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
    }
    .padding(12)
}
    
    // MARK: - 5. 黑名单设置内容
    
    private var blacklistContent: some View {
        VStack(alignment: .leading, spacing: 24) {
            // 1. 警告性的文字提醒 (全宽显示)
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "exclamationmark.shield.fill")
                    .foregroundColor(.orange)
                    .font(.title2)
                
                Text(t("对于某些特殊软件（例如可以贴边隐藏的软件，或者会拦截、修改系统点击行为的软件），请加入黑名单，以避免该软件的点击行为失效。", 
                       "For specialized software (like apps that snap to screen edges or those that intercept/modify system click behavior), please add them to the blacklist to prevent their click handling from failing."))
                    .font(.subheadline)
                    .lineSpacing(4)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                
                Spacer() // 确保背景色铺满
            }
            .padding(16)
            .background(Color.orange.opacity(0.1))
            .cornerRadius(12)
            
            // 2. 只有当黑名单不为空时，才显示管理方框
            if !settingsManager.blacklistedBundleIDs.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Text(t("排除的应用", "Excluded Applications"))
                        .font(.headline)
                        .foregroundColor(.primary)
                    
                    GroupBox {
                        VStack(spacing: 0) {
                            ForEach(settingsManager.blacklistedBundleIDs, id: \.self) { bid in
                                HStack(spacing: 12) {
                                    if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid),
                                       let icon = NSWorkspace.shared.icon(forFile: appURL.path) as NSImage? {
                                        Image(nsImage: icon)
                                            .resizable()
                                            .frame(width: 28, height: 28)
                                    } else {
                                        Image(systemName: "app.dashed")
                                            .resizable()
                                            .frame(width: 28, height: 28)
                                            .foregroundColor(.secondary)
                                    }
                                    
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(getAppName(for: bid))
                                            .font(.system(size: 14, weight: .medium))
                                        Text(bid)
                                            .font(.system(size: 10, design: .monospaced))
                                            .foregroundColor(.secondary)
                                    }
                                    
                                    Spacer()
                                    
                                    Button(action: {
                                        withAnimation {
                                            settingsManager.blacklistedBundleIDs.removeAll { $0 == bid }
                                        }
                                    }) {
                                        Image(systemName: "xmark.circle.fill")
                                            .font(.system(size: 18))
                                            .foregroundColor(.secondary)
                                    }
                                    .buttonStyle(.plain)
                                }
                                .padding(.vertical, 10)
                                
                                if bid != settingsManager.blacklistedBundleIDs.last {
                                    Divider()
                                }
                            }
                        }
                    }
                }
            }
            
            // 3. 添加按钮 (始终左对齐)
            Button(action: {
                showAppPicker()
            }) {
                Label(t("添加黑名单软件...", "Add Blacklisted App..."), systemImage: "plus.circle.fill")
                    .padding(.horizontal, 4)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    
    private func getAppName(for bundleId: String) -> String {
        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId),
           let bundle = Bundle(url: appURL),
           let name = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? 
                      bundle.object(forInfoDictionaryKey: "CFBundleName") as? String {
            return name
        }
        return bundleId
    }
    
    private func showAppPicker() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.application, .executable]
        panel.message = t("请选择要加入黑名单的应用", "Select applications to blacklist")
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        
        if panel.runModal() == .OK {
            for url in panel.urls {
                if let bundle = Bundle(url: url), let bid = bundle.bundleIdentifier {
                    if !settingsManager.blacklistedBundleIDs.contains(bid) {
                        settingsManager.blacklistedBundleIDs.append(bid)
                    }
                }
            }
        }
    }

    // MARK: - Helper
    private func t(_ zh: String, _ en: String) -> String {
        return settingsManager.t(zh, en)
    }
}

// MARK: - About Tab Components

struct RecommendedTool: Identifiable {
    let id = UUID()
    let name: String
    let slogan: String
    let iconName: String
    let url: String
}



struct RecommendationRow: View {
    let tool: RecommendedTool
    @State private var isHovered = false
    
    var body: some View {
        Button(action: {
            if let url = URL(string: tool.url) {
                NSWorkspace.shared.open(url)
            }
        }) {
            HStack(spacing: 12) {
                // Icon
                if let iconUrl = Bundle.main.url(forResource: tool.iconName, withExtension: "png") {
                    if let nsImage = NSImage(contentsOf: iconUrl) {
                        Image(nsImage: nsImage)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 40, height: 40)
                            .cornerRadius(8)
                    } else {
                        Image(systemName: "app.fill")
                            .resizable()
                            .frame(width: 40, height: 40)
                            .foregroundColor(.secondary.opacity(0.2))
                    }
                } else {
                    // Fallback to name-based if URL search fails (useful for Assets)
                    if let nsImage = NSImage(named: tool.iconName) {
                        Image(nsImage: nsImage)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 40, height: 40)
                            .cornerRadius(8)
                    } else {
                        Image(systemName: "app.fill")
                            .resizable()
                            .frame(width: 40, height: 40)
                            .foregroundColor(.secondary.opacity(0.2))
                    }
                }
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(tool.name)
                        .font(.body)
                        .fontWeight(.medium)
                    
                    Text(tool.slogan)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                
                Spacer()
                
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundColor(.secondary.opacity(0.5))
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 12)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(isHovered ? Color.primary.opacity(0.05) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(isHovered ? Color.primary.opacity(0.1) : Color.clear, lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.2)) {
                isHovered = hovering
            }
        }
    }
}
