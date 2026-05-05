//
//  SettingsView.swift
//  DockMinimize
//

import SwiftUI
import CoreServices

struct SettingsView: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var accessibilityManager = AccessibilityManager.shared
    @ObservedObject private var settingsManager = SettingsManager.shared
    @ObservedObject private var hotkeyCaptureCenter = HotkeyCaptureCenter.shared
    @State private var showMinimizeTip = false
    @State private var showHotkeyAppPickerSheet = false
    
    // 当前选中的标签页
    @State private var selectedTab: SettingsTab = .permissions
    
    // 菜单枚举
    // 菜单枚举
    enum SettingsTab: String, CaseIterable {
        case permissions
        case general
        case smallWindowPreview
        case hotkeys
        case blacklist
        case about
        
        func iconName() -> String {
            switch self {
            case .permissions: return "lock.shield.fill"
            case .general: return "gearshape.fill"
            case .smallWindowPreview: return "macwindow.fill"
            case .hotkeys: return "keyboard.fill"
            case .blacklist: return "minus.circle.fill"
            case .about: return "info.circle.fill"
            }
        }
        
        func displayName(t: (String, String) -> String) -> String {
            switch self {
            case .permissions: return t("权限设置", "Permissions")
            case .general: return t("常规设置", "General")
            case .smallWindowPreview: return t("小窗预览", "Small Window Preview")
            case .hotkeys: return t("快捷键", "Hotkeys")
            case .blacklist: return t("黑名单", "Blacklist")
            case .about: return t("关于", "About")
            }
        }
    }
    
    var body: some View {
        if #available(macOS 13.0, *) {
            NavigationSplitView {
                SidebarListView(selectedTab: $selectedTab, t: t)
                    .navigationTitle("Dock Minimize")
                    .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 220)
            } detail: {
                contentView
                    .background(Color(NSColor.windowBackgroundColor))
            }
            // 让 SwiftUI 认为自己可以收缩到很窄（200pt），从而 NavigationSplitView
            // 侧栏折叠/展开时有充足的伸缩空间，不会卡顿。
            // 实际窗口尺寸由 MenuBarController 通过 NSWindow.minSize=maxSize 锁定为 700×480。
            .frame(minWidth: 200, idealWidth: 700, maxWidth: 900,
                   minHeight: 200, idealHeight: 480, maxHeight: 900)
            .sheet(isPresented: $showHotkeyAppPickerSheet) {
                HotkeyAppPickerSheet(
                    excludedBundleIDs: Set(settingsManager.hotkeyBindings.map(\.bundleID))
                ) { bundleID in
                    withAnimation {
                        settingsManager.addHotkeyApp(bundleID: bundleID)
                    }
                    DispatchQueue.main.async {
                        toggleHotkeyRecording(for: bundleID)
                    }
                }
            }
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
                        case .hotkeys:
                            hotkeysContent
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
        .padding(.top, -10) // 向上收紧避免留白
        .background(
            Color(NSColor.windowBackgroundColor)
                .padding(.top, -100) // 背景向上延伸，彻底遮挡滚动内容穿透
        )
    }
    
    // MARK: - About Tab Sub-components

    private var aboutHeaderIcon: NSImage? {
        let resourceName = colorScheme == .dark ? "AboutAppIconDark" : "AboutAppIconLight"
        if let iconURL = Bundle.main.url(forResource: resourceName, withExtension: "png"),
           let icon = NSImage(contentsOf: iconURL) {
            return icon
        }
        return NSImage(named: "AboutAppIcon")
    }
    
    private var aboutAppHeader: some View {
        HStack(spacing: 16) {
            if let appIcon = aboutHeaderIcon {
                Image(nsImage: appIcon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 64, height: 64)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("DockMinimize")
                        .font(.title2)
                        .bold()
                    
                    Text("v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.3")")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.gray.opacity(0.15))
                        .cornerRadius(4)
                }
                
                Text(t("在 macOS 上实现类似 Windows 系统的单击隐藏和显示窗口", "Single-click to hide and show windows on macOS, just like Windows."))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                
                HStack(spacing: 12) {
                    Button(action: {
                        if let url = URL(string: "https://ivean.com/dockminimize/") {
                            NSWorkspace.shared.open(url)
                        }
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: "globe")
                            Text(t("访问网站", "Visit Website"))
                        }
                        .font(.system(size: 12, weight: .medium))
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.accentColor)
                }
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
                name: "EdgeClip",
                slogan: t("让刚刚复制的内容，留在手边。", "Keep What You Just Copied, Right at Hand."),
                iconName: "edgeclip",
                url: "https://www.ivean.com/edgeclip/"
            ),
            RecommendedTool(
                name: t("流光倒计时", "Flux Timer"),
                slogan: t("一按一拉，静待流光。让时间流逝成为一种桌面美学。", "Pull to Focus. Flow to Finish. Turning every wait into a ceremony."),
                iconName: "flux_timer",
                url: "https://ivean.com/fluxtimer/"
            ),
            RecommendedTool(
                name: "SideBar",
                slogan: t("将屏幕边缘的魔法收纳术带给所有的第三方应用。拖拽吸附，悬停弹射，纯粹且静谧。", "Bring the magic of screen-edge stashing to any third-party app. Drag to snap, hover to expand. Pure and silent."),
                iconName: "sidebar",
                url: "https://www.ivean.com/sidebar/"
            ),
            RecommendedTool(
                name: t("快速搜索", "Quick Search"),
                slogan: t("选中文本，双击快捷键，在页面上瞬间切换搜索方式。", "Instantly switch search engines with a double-click shortcut."),
                iconName: "quick_search",
                url: "https://www.ivean.com/quicksearch/"
            ),
            RecommendedTool(
                name: t("多词高亮查找", "Multi-Keyword Highlighter"),
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
            
            // GroupBox 3: 检查更新
            GroupBox {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 18))
                        .frame(width: 30, alignment: .center)
                        .foregroundColor(.accentColor)
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text(t("检查更新", "Check for Updates"))
                            .font(.system(size: 14))
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Text(t("当前版本：", "Current Version: ") + appVersionString)
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    
                    Spacer(minLength: 8)
                    
                    Button(t("立即检查", "Check Now")) {
                        UpdateChecker.shared.checkForUpdates(manual: true)
                    }
                    .frame(minWidth: 86)
                    
                    Picker("", selection: $settingsManager.updateCheckFrequency) {
                        ForEach(UpdateCheckFrequency.allCases, id: \.self) { freq in
                            Text(freq.displayName(t: t)).tag(freq)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(width: 110)
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

private func toggleRow(icon: String? = nil, title: String, isOn: Binding<Bool>) -> some View {
    HStack {
        if let icon = icon {
            Image(systemName: icon)
                .font(.system(size: 18))
                .frame(width: 30, alignment: .center)
                .foregroundColor(.accentColor)
        }
        
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.system(size: 14))
        }
        
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
            VStack(spacing: 0) {
                toggleRow(
                    title: t("启用小窗预览", "Enable Small Window Preview"),
                    isOn: $settingsManager.hoverPreviewEnabled
                )
            }
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
                    
                    Divider().padding(.leading, 12)
                    
                    toggleRowWithDesc(
                        title: t("原位预览", "Original Preview"),
                        desc: t("在窗口原本消失的位置显示大图预览。", "Show large preview at original window location."),
                        isOn: $settingsManager.enableOriginalPreview
                    )
                    .disabled(!settingsManager.enableIndependentWindowControl)
                    .opacity(settingsManager.enableIndependentWindowControl ? 1.0 : 0.5)

                    Divider().padding(.leading, 12)

                    // 「聚焦预览」(Focus Preview)：依赖「原位预览」开启
                    // - 仅在「原位预览」打开时才可用
                    // - 「原位预览」关闭时，开关本身会被 SettingsManager 自动联动关闭并禁用
                    toggleRowWithDesc(
                        title: t("聚焦预览", "Focus Preview"),
                        desc: t("显示原位预览时，将桌面其余区域模糊化以突出预览。",
                                "Blur the rest of the desktop while showing the original preview."),
                        isOn: $settingsManager.enableFocusPreview
                    )
                    .disabled(!settingsManager.enableIndependentWindowControl
                              || !settingsManager.enableOriginalPreview)
                    .opacity((settingsManager.enableIndependentWindowControl
                              && settingsManager.enableOriginalPreview) ? 1.0 : 0.5)
                }
                .padding(.vertical, 4)
            }

            
            if settingsManager.enableOriginalPreview {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "lightbulb.fill")
                        .foregroundColor(.orange)
                        .font(.title2)
                    
                    Text(t("对于“访达”和其他开启了多窗口的软件，DockMinimize会改用“最小化窗口”的方式来实现窗口消失和展现。你可能会看到预览图的背面有一个短暂的“神奇效果/缩放效果”动画。", 
                           "For \"Finder\" and other apps with multiple windows, DockMinimize will use the \"Minimize Window\" method for transitions. You might see a brief \"Genie/Scale effect\" animation behind the preview."))
                        .font(.subheadline)
                        .lineSpacing(4)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    
                    Spacer()
                }
                .padding(16)
                .background(Color.orange.opacity(0.1))
                .cornerRadius(12)
            }
        }
    }
}



private func toggleRowWithDesc(title: String, desc: String, isOn: Binding<Bool>) -> some View {
    HStack {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 14))
            Text(desc).font(.system(size: 11)).foregroundColor(.secondary)
        }
        Spacer()
        Toggle("", isOn: isOn)
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
    }
    .padding(12)
}

    // MARK: - 4. 快捷键内容

    private var hotkeysContent: some View {
        VStack(alignment: .leading, spacing: 24) {
            if !accessibilityManager.isAccessibilityEnabled {
                permissionCard(
                    title: t("辅助功能未开启", "Accessibility Not Enabled"),
                    desc: t("快捷键需要辅助功能权限来全局监听键盘事件。", "Hotkeys need Accessibility permission to listen globally for keyboard events."),
                    isEnabled: false,
                    action: { accessibilityManager.requestAccessibility() }
                )
            }

            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "keyboard.badge.ellipsis")
                    .foregroundColor(.blue)
                    .font(.title2)

                VStack(alignment: .leading, spacing: 6) {
                    Text(t("为常用应用绑定全局快捷键。按一次唤出窗口，再按一次隐藏窗口。录制时按 Esc 可以取消。", "Assign a global shortcut to an app. Press once to show its window, and press again to hide it. Press Esc while recording to cancel."))
                        .font(.subheadline)
                        .lineSpacing(4)
                        .foregroundColor(.secondary)
                }

                Spacer()
            }
            .padding(16)
            .background(Color.blue.opacity(0.08))
            .cornerRadius(12)

            if let statusMessage = hotkeyCaptureCenter.statusMessage {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundColor(.orange)
                    Text(statusMessage)
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                .padding(12)
                .background(Color.orange.opacity(0.08))
                .cornerRadius(10)
            }

            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(t("已绑定的应用", "Bound Applications"))
                        .font(.headline)
                        .foregroundColor(.primary)

                    Spacer()

                    Button(action: {
                        showHotkeyAppPickerSheet = true
                    }) {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 20))
                            .foregroundColor(.blue)
                    }
                    .buttonStyle(.plain)
                    .help(t("添加快捷键应用", "Add App Hotkey"))
                }

                if settingsManager.hotkeyBindings.isEmpty {
                    HStack(spacing: 10) {
                        Image(systemName: "app.badge.plus")
                            .foregroundColor(.secondary)
                        Text(t("还没有添加任何应用。点击右上角的加号，选择应用后即可开始录制快捷键。", "No apps have been added yet. Click the plus button to choose an app and start recording a shortcut."))
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.04))
                    .cornerRadius(12)
                } else {
                    GroupBox {
                        VStack(spacing: 0) {
                            ForEach(settingsManager.hotkeyBindings) { binding in
                                hotkeyBindingRow(binding)

                                if binding.id != settingsManager.hotkeyBindings.last?.id {
                                    Divider()
                                }
                            }
                        }
                    }
                }
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onDisappear {
            hotkeyCaptureCenter.cancelRecording()
        }
    }

    @ViewBuilder
    private func hotkeyBindingRow(_ binding: AppHotkeyBinding) -> some View {
        let isRecording = hotkeyCaptureCenter.recordingBundleID == binding.bundleID

        HStack(spacing: 12) {
            if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: binding.bundleID) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: appURL.path))
                    .resizable()
                    .frame(width: 28, height: 28)
            } else {
                Image(systemName: "app.dashed")
                    .resizable()
                    .frame(width: 28, height: 28)
                    .foregroundColor(.secondary)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(localizedAppName(for: binding.bundleID))
                    .font(.system(size: 14, weight: .medium))
            }

            Spacer()

            if isRecording {
                Button(action: {
                    toggleHotkeyRecording(for: binding.bundleID)
                }) {
                    Text(hotkeyButtonTitle(for: binding, isRecording: isRecording))
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .lineLimit(1)
                        .frame(minWidth: 144)
                }
                .buttonStyle(.borderedProminent)
            } else {
                Button(action: {
                    toggleHotkeyRecording(for: binding.bundleID)
                }) {
                    Text(hotkeyButtonTitle(for: binding, isRecording: isRecording))
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .lineLimit(1)
                        .frame(minWidth: 144)
                }
                .buttonStyle(.bordered)
            }

            Button(action: {
                hotkeyCaptureCenter.cancelRecording()
                withAnimation {
                    settingsManager.removeHotkeyApp(bundleID: binding.bundleID)
                }
            }) {
                Image(systemName: "trash")
                    .font(.system(size: 14, weight: .medium))
            }
            .buttonStyle(.borderless)
            .foregroundColor(.secondary)
            .help(t("移除此应用", "Remove App"))
        }
        .padding(.vertical, 10)
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
            
            // 2. 排除的应用标题 + 添加按钮（始终显示）
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(t("排除的应用", "Excluded Applications"))
                        .font(.headline)
                        .foregroundColor(.primary)
                    
                    Spacer()
                    
                    Button(action: {
                        showAppPicker()
                    }) {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 20))
                            .foregroundColor(.blue)
                    }
                    .buttonStyle(.plain)
                    .help(t("添加黑名单软件", "Add Blacklisted App"))
                }
                
                if !settingsManager.blacklistedBundleIDs.isEmpty {
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
                                        Text(localizedAppName(for: bid))
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
            
            if !settingsManager.sidebarManagedBundleIDs.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 6) {
                        Image(systemName: "link.circle.fill")
                            .foregroundColor(.blue)
                            .font(.system(size: 13))
                        Text(t("SideBar 联动排除", "SideBar Linked Exclusions"))
                            .font(.headline)
                            .foregroundColor(.primary)
                    }
                    
                    Text(t("以下应用正在由 SideBar 管理贴边控制，已自动排除。此列表由 SideBar 实时同步，无需手动操作。",
                           "The following apps are managed by SideBar for edge-snapping control and are automatically excluded. This list is synced in real-time by SideBar."))
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .lineSpacing(3)
                    
                    GroupBox {
                        VStack(spacing: 0) {
                            ForEach(settingsManager.sidebarManagedBundleIDs, id: \.self) { bid in
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
                                        Text(localizedAppName(for: bid))
                                            .font(.system(size: 14, weight: .medium))
                                        Text(bid)
                                            .font(.system(size: 10, design: .monospaced))
                                            .foregroundColor(.secondary)
                                    }
                                    
                                    Spacer()
                                    
                                    Text(t("由 SideBar 管理", "Managed by SideBar"))
                                        .font(.system(size: 10))
                                        .foregroundColor(.blue.opacity(0.7))
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 3)
                                        .background(Color.blue.opacity(0.1))
                                        .cornerRadius(4)
                                }
                                .padding(.vertical, 10)
                                
                                if bid != settingsManager.sidebarManagedBundleIDs.last {
                                    Divider()
                                }
                            }
                        }
                    }
                }
            }
            
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    
    private func localizedAppName(for bundleId: String) -> String {
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else {
            return bundleId
        }

        return ApplicationMetadataResolver.localizedDisplayName(for: appURL, fallbackBundleID: bundleId)
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

    private func toggleHotkeyRecording(for bundleID: String) {
        if hotkeyCaptureCenter.recordingBundleID == bundleID {
            hotkeyCaptureCenter.cancelRecording()
            return
        }

        hotkeyCaptureCenter.beginRecording(for: bundleID) { shortcut in
            guard let shortcut else { return }
            settingsManager.updateHotkeyShortcut(for: bundleID, shortcut: shortcut)
        }
    }

    private func hotkeyButtonTitle(for binding: AppHotkeyBinding, isRecording: Bool) -> String {
        if isRecording {
            return t("按下快捷键", "Press Shortcut")
        }

        if let shortcut = binding.shortcut {
            return shortcut.displayString
        }

        return t("录制快捷键", "Record Shortcut")
    }

    // MARK: - Helper
    private func t(_ zh: String, _ en: String) -> String {
        return settingsManager.t(zh, en)
    }
    
    private var appVersionString: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.3"
    }
    
}


// MARK: - 侧边栏图标（外部 SVG 资源）

/// SVG 图标位于 Resources/SidebarIcons/ 目录下，本身是白色填充的单色图标。
/// 加载后通过 `template` 属性让 SwiftUI 的 `.foregroundColor` 接管染色，
/// 从而实现选中态变为 accentColor、未选中变为 secondary 等动态着色。
private struct SidebarTabIcon: View {
    let tab: SettingsView.SettingsTab
    let isSelected: Bool

    private var resourceName: String {
        switch tab {
        case .permissions:        return "permissions"
        case .general:            return "general"
        case .smallWindowPreview: return "preview"
        case .hotkeys:            return "hotkey"
        case .blacklist:          return "blacklist"
        case .about:              return "about"
        }
    }

    private var loadedImage: NSImage? {
        // 优先从 Resources/SidebarIcons 目录读取（folder reference 形式被打包到 bundle 根）
        let candidates: [URL?] = [
            Bundle.main.url(forResource: resourceName, withExtension: "svg", subdirectory: "SidebarIcons"),
            Bundle.main.url(forResource: resourceName, withExtension: "svg")
        ]
        for case let url? in candidates {
            if let img = NSImage(contentsOf: url) {
                img.isTemplate = true   // 让外部 .foregroundColor 接管颜色
                return img
            }
        }
        return nil
    }

    var body: some View {
        Group {
            if let img = loadedImage {
                Image(nsImage: img)
                    .resizable()
                    .renderingMode(.template)
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
            } else {
                // 兜底：万一 SVG 没找到，用 SF Symbol 占位
                Image(systemName: "questionmark.circle")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            }
        }
        .frame(width: 18, height: 18)
    }
}


// MARK: - 全新 Sidebar：左侧滑动竖条 + 半透明展开背景

private struct SidebarListView: View {
    @Binding var selectedTab: SettingsView.SettingsTab
    let t: (String, String) -> String

    @Namespace private var indicatorNamespace

    var body: some View {
        // 关掉 List 自带的选中高亮，用纯 VStack + ZStack 控制
        ScrollView(showsIndicators: false) {
            VStack(spacing: 4) {
                ForEach(SettingsView.SettingsTab.allCases, id: \.self) { tab in
                    SidebarRow(
                        tab: tab,
                        selectedTab: $selectedTab,
                        indicatorNamespace: indicatorNamespace,
                        t: t
                    )
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, 8)
            .padding(.bottom, 12)
        }
        .background(.clear)
    }
}

private struct SidebarRow: View {
    let tab: SettingsView.SettingsTab
    @Binding var selectedTab: SettingsView.SettingsTab
    let indicatorNamespace: Namespace.ID
    let t: (String, String) -> String

    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovered = false
    /// 展开背景的进度：0 → 1，从左向右铺开
    @State private var bgProgress: CGFloat = 0

    private var isSelected: Bool { selectedTab == tab }

    private var displayText: String {
        tab == .smallWindowPreview
            ? t("小窗预览", "Preview")
            : tab.displayName(t: t)
    }

    private var backgroundFill: Color {
        // 暗色模式略提亮一点
        Color.accentColor.opacity(colorScheme == .dark ? 0.22 : 0.15)
    }

    private var iconColor: Color {
        if isSelected { return .accentColor }
        return isHovered ? .primary.opacity(0.85) : .secondary
    }

    private var textColor: Color {
        if isSelected { return .accentColor }
        return .primary
    }

    var body: some View {
        ZStack(alignment: .leading) {
            // —— 第一层：左侧竖条（只在选中行渲染，靠 matchedGeometryEffect 在不同行之间滑动）
            //   高度与右侧蓝色背景胶囊保持一致 —— 都是行高 36 - 上下各 0pt
            HStack(spacing: 0) {
                if isSelected {
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(width: 3)
                        .frame(maxHeight: .infinity)
                        .matchedGeometryEffect(id: "sidebar.indicator", in: indicatorNamespace)
                } else {
                    Spacer().frame(width: 3)
                }
                Spacer()
            }
            .padding(.leading, 4)

            // —— 第二层：从左向右展开的半透明蓝色底色
            //     用 GeometryReader 精确控制宽度（而不是 scaleEffect，避免圆角形变）
            GeometryReader { geo in
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? backgroundFill : Color.clear)
                    .frame(width: geo.size.width * bgProgress,
                           height: geo.size.height,
                           alignment: .leading)
            }
            .padding(.leading, 12)   // 给竖条让出空间
            .padding(.trailing, 4)

            // —— 第三层：图标 + 文字
            HStack(spacing: 11) {
                SidebarTabIcon(tab: tab, isSelected: isSelected)
                    .foregroundColor(iconColor)
                    .frame(width: 22, alignment: .center)

                Text(displayText)
                    .font(.system(size: 13.5,
                                  weight: isSelected ? .semibold : .regular))
                    .foregroundColor(textColor)
                    .lineLimit(1)

                Spacer(minLength: 0)
            }
            .padding(.leading, 22)   // 12 (背景起点) + 10 (背景内左 padding)
            .padding(.trailing, 12)
            .padding(.vertical, 8)
        }
        .frame(height: 36)
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
        .onTapGesture {
            guard !isSelected else { return }
            // 选中切换：竖条用 spring，背景用 easeOut
            withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) {
                selectedTab = tab
            }
        }
        // 监听选中状态变化，驱动背景从左向右展开 / 直接淡出
        .onChange(of: isSelected) { newValue in
            if newValue {
                bgProgress = 0
                withAnimation(.easeOut(duration: 0.32)) {
                    bgProgress = 1
                }
            } else {
                // 旧选中行：直接淡出，不收回
                withAnimation(.easeIn(duration: 0.12)) {
                    bgProgress = 0
                }
            }
        }
        .onAppear {
            // 初始进入页面时，让默认选中那一项也展示出底色（无动画，避免开屏抖动）
            bgProgress = isSelected ? 1 : 0
        }
        // 让 hover 也有一点点反馈（非选中行）
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isHovered && !isSelected ? Color.primary.opacity(0.05) : Color.clear)
                .padding(.leading, 12)
                .padding(.trailing, 4)
        )
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
    @Environment(\.colorScheme) private var colorScheme
    let tool: RecommendedTool
    @State private var isHovered = false

    private var loadedIcon: NSImage? {
        let themedResourceName = "\(tool.iconName)_\(colorScheme == .dark ? "dark" : "light")"
        if let iconURL = Bundle.main.url(forResource: themedResourceName, withExtension: "png", subdirectory: "Recommends"),
           let icon = NSImage(contentsOf: iconURL) {
            return icon
        }
        if let fallbackURL = Bundle.main.url(forResource: tool.iconName, withExtension: "png", subdirectory: "Recommends"),
           let fallbackIcon = NSImage(contentsOf: fallbackURL) {
            return fallbackIcon
        }
        return NSImage(named: tool.iconName)
    }
    
    var body: some View {
        Button(action: {
            if let url = URL(string: tool.url) {
                NSWorkspace.shared.open(url)
            }
        }) {
            HStack(spacing: 12) {
                if let nsImage = loadedIcon {
                    Image(nsImage: nsImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 48, height: 48)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                } else {
                    Image(systemName: "app.fill")
                        .resizable()
                        .frame(width: 48, height: 48)
                        .foregroundColor(.secondary.opacity(0.2))
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

private struct InstalledApplicationItem: Identifiable, Hashable {
    let bundleID: String
    let url: URL
    let displayName: String

    var id: String { bundleID }

    var searchIndex: String {
        "\(displayName) \(bundleID) \(url.deletingPathExtension().lastPathComponent)".lowercased()
    }
}

private enum ApplicationMetadataResolver {
    static func localizedDisplayName(for appURL: URL, fallbackBundleID: String? = nil) -> String {
        if let spotlightName = spotlightDisplayName(for: appURL), !spotlightName.isEmpty {
            return spotlightName
        }

        if let localizedName = localizedInfoPlistName(for: appURL), !localizedName.isEmpty {
            return localizedName
        }

        if let bundle = Bundle(url: appURL) {
            if let localizedInfo = bundle.localizedInfoDictionary,
               let name = localizedInfo["CFBundleDisplayName"] as? String ?? localizedInfo["CFBundleName"] as? String,
               !name.isEmpty {
                return name
            }

            if let name = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ??
                bundle.object(forInfoDictionaryKey: "CFBundleName") as? String,
               !name.isEmpty {
                return name
            }
        }

        let displayName = FileManager.default.displayName(atPath: appURL.path)
        if !displayName.isEmpty {
            return displayName
        }

        return fallbackBundleID ?? appURL.deletingPathExtension().lastPathComponent
    }

    static func scanInstalledApplications() -> [InstalledApplicationItem] {
        let fileManager = FileManager.default
        let searchRoots = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications", isDirectory: true)
        ]

        var applicationsByBundleID: [String: InstalledApplicationItem] = [:]

        for root in searchRoots where fileManager.fileExists(atPath: root.path) {
            guard let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else {
                continue
            }

            for case let appURL as URL in enumerator {
                guard appURL.pathExtension == "app",
                      let bundle = Bundle(url: appURL),
                      let bundleID = bundle.bundleIdentifier else {
                    continue
                }

                let displayName = localizedDisplayName(for: appURL, fallbackBundleID: bundleID)
                applicationsByBundleID[bundleID] = InstalledApplicationItem(
                    bundleID: bundleID,
                    url: appURL,
                    displayName: displayName
                )
            }
        }

        return applicationsByBundleID.values.sorted {
            if $0.displayName == $1.displayName {
                return $0.bundleID.localizedStandardCompare($1.bundleID) == .orderedAscending
            }
            return $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }
    }

    private static func localizedInfoPlistName(for appURL: URL) -> String? {
        let resourceURL = appURL.appendingPathComponent("Contents/Resources", isDirectory: true)
        let preferredLanguages = Locale.preferredLanguages.flatMap { language -> [String] in
            let normalized = language.replacingOccurrences(of: "_", with: "-")
            let parts = normalized.split(separator: "-")
            if parts.count > 1 {
                return [normalized, String(parts[0])]
            }
            return [normalized]
        }

        let fallbackLanguages = ["zh-Hans", "zh_CN", "zh", "en", "Base"]
        let candidates = Array(NSOrderedSet(array: preferredLanguages + fallbackLanguages)) as? [String] ?? fallbackLanguages

        for language in candidates {
            let stringsURL = resourceURL
                .appendingPathComponent("\(language).lproj", isDirectory: true)
                .appendingPathComponent("InfoPlist.strings")

            guard let data = try? Data(contentsOf: stringsURL) else { continue }
            guard let dictionary = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
                continue
            }

            if let name = dictionary["CFBundleDisplayName"] as? String ?? dictionary["CFBundleName"] as? String,
               !name.isEmpty {
                return name
            }
        }

        return nil
    }

    private static func spotlightDisplayName(for appURL: URL) -> String? {
        guard let item = MDItemCreate(kCFAllocatorDefault, appURL.path as CFString) else {
            return nil
        }

        guard let name = MDItemCopyAttribute(item, kMDItemDisplayName) as? String,
              !name.isEmpty else {
            return nil
        }

        return name
    }
}

private struct HotkeyAppPickerSheet: View {
    @ObservedObject private var settingsManager = SettingsManager.shared
    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""
    @State private var applications: [InstalledApplicationItem] = []
    @State private var isLoading = true

    let excludedBundleIDs: Set<String>
    let onSelect: (String) -> Void

    private var visibleApplications: [InstalledApplicationItem] {
        applications.filter { !excludedBundleIDs.contains($0.bundleID) }
    }

    private var filteredApplications: [InstalledApplicationItem] {
        let keyword = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !keyword.isEmpty else { return visibleApplications }
        return visibleApplications.filter { $0.searchIndex.contains(keyword) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(settingsManager.t("请选择要绑定快捷键的应用", "Choose an App for Hotkey Binding"))
                    .font(.title3)
                    .fontWeight(.semibold)
                Spacer()
            }

            TextField(settingsManager.t("搜索应用", "Search Apps"), text: $searchText)
                .textFieldStyle(.roundedBorder)

            Group {
                if isLoading {
                    VStack(spacing: 10) {
                        ProgressView()
                        Text(settingsManager.t("正在读取应用列表…", "Loading installed applications..."))
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if filteredApplications.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "magnifyingglass")
                            .font(.title2)
                            .foregroundColor(.secondary)
                        Text(
                            visibleApplications.isEmpty
                                ? settingsManager.t("可绑定的应用都已经添加过了", "All available apps have already been added.")
                                : settingsManager.t("没有找到匹配的应用", "No matching applications found.")
                        )
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(filteredApplications) { app in
                        Button {
                            onSelect(app.bundleID)
                            dismiss()
                        } label: {
                            HStack(spacing: 12) {
                                Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path))
                                    .resizable()
                                    .frame(width: 32, height: 32)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(app.displayName)
                                        .foregroundColor(.primary)
                                    Text(app.bundleID)
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                            }
                            .padding(.vertical, 4)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    .listStyle(.inset)
                }
            }

            HStack {
                Spacer()
                Button(settingsManager.t("取消", "Cancel")) {
                    dismiss()
                }
            }
        }
        .padding(20)
        .frame(width: 520, height: 560)
        .task {
            guard applications.isEmpty else { return }
            isLoading = true
            applications = await Task.detached(priority: .userInitiated) {
                ApplicationMetadataResolver.scanInstalledApplications()
            }.value
            isLoading = false
        }
    }
}
