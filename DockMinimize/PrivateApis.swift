//
//  PrivateApis.swift
//  DockMinimize
//
//  私有 API 声明（参考 DockDoor）
//

import Cocoa

// MARK: - Private Window APIs

/// 从 AXUIElement 获取对应的 CGWindowID
/// macOS 10.10+
@_silgen_name("_AXUIElementGetWindow") @discardableResult
func _AXUIElementGetWindow(_ axUiElement: AXUIElement, _ wid: inout CGWindowID) -> AXError

// MARK: - Private Window Capture Options

struct CGSWindowCaptureOptions: OptionSet {
    let rawValue: UInt32
    static let ignoreGlobalClipShape = CGSWindowCaptureOptions(rawValue: 1 << 11)
    static let nominalResolution = CGSWindowCaptureOptions(rawValue: 1 << 9)
    static let bestResolution = CGSWindowCaptureOptions(rawValue: 1 << 8)
    static let fullSize = CGSWindowCaptureOptions(rawValue: 1 << 19)
}

typealias CGSConnectionID = UInt32

@_silgen_name("CGSMainConnectionID")
func CGSMainConnectionID() -> CGSConnectionID

@_silgen_name("CGSHWCaptureWindowList")
func CGSHWCaptureWindowList(
    _ cid: CGSConnectionID,
    _ windowList: UnsafePointer<UInt32>,
    _ count: UInt32,
    _ options: CGSWindowCaptureOptions
) -> CFArray?

// MARK: - SkyLight Private APIs for Window Focusing

struct ProcessSerialNumber {
    var highLongOfPSN: UInt32 = 0
    var lowLongOfPSN: UInt32 = 0
}

@_silgen_name("GetProcessForPID")
func GetProcessForPID(_ pid: pid_t, _ psn: UnsafeMutablePointer<ProcessSerialNumber>) -> OSStatus

enum SLPSMode: UInt32 {
    case allWindows = 0x100
    case userGenerated = 0x200
    case noWindows = 0x400
}

typealias SLPSSetFrontProcessWithOptionsType = @convention(c) (
    UnsafeMutableRawPointer,
    CGWindowID,
    UInt32
) -> CGError

private var skyLightHandle: UnsafeMutableRawPointer?
private var setFrontProcessPtr: SLPSSetFrontProcessWithOptionsType?

private func loadSkyLightFunctions() {
    guard skyLightHandle == nil else { return }
    
    let skyLightPath = "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight"
    guard let handle = dlopen(skyLightPath, RTLD_LAZY) else {
        print("Failed to load SkyLight framework")
        return
    }
    
    skyLightHandle = handle
    
    if let symbol = dlsym(handle, "_SLPSSetFrontProcessWithOptions") {
        setFrontProcessPtr = unsafeBitCast(symbol, to: SLPSSetFrontProcessWithOptionsType.self)
    }
}

func _SLPSSetFrontProcessWithOptions(_ psn: UnsafeMutablePointer<ProcessSerialNumber>, _ wid: CGWindowID, _ mode: SLPSMode.RawValue) -> CGError {
    loadSkyLightFunctions()
    guard let fn = setFrontProcessPtr else { return CGError(rawValue: -1)! }
    return fn(psn, wid, mode)
}

// MARK: - SLPSPostEventRecordTo (用于 makeKeyWindow)

typealias SLPSPostEventRecordToType = @convention(c) (
    UnsafeMutableRawPointer,
    UnsafeMutablePointer<UInt8>
) -> CGError

private var postEventRecordPtr: SLPSPostEventRecordToType?

private func loadPostEventRecordFunction() {
    guard postEventRecordPtr == nil else { return }
    loadSkyLightFunctions()
    guard let handle = skyLightHandle else { return }
    
    if let symbol = dlsym(handle, "SLPSPostEventRecordTo") {
        postEventRecordPtr = unsafeBitCast(symbol, to: SLPSPostEventRecordToType.self)
    }
}

func SLPSPostEventRecordTo(_ psn: UnsafeMutablePointer<ProcessSerialNumber>, _ bytes: UnsafeMutablePointer<UInt8>) -> CGError {
    loadPostEventRecordFunction()
    guard let fn = postEventRecordPtr else { return CGError(rawValue: -1)! }
    return fn(psn, bytes)
}

// MARK: - Make Key Window

/// 使用 SkyLight 私有 API 将窗口设为 key window
/// 参考 DockDoor 和 Hammerspoon: https://github.com/Hammerspoon/hammerspoon/issues/370#issuecomment-545545468
func makeKeyWindow(_ psn: inout ProcessSerialNumber, windowID: CGWindowID) {
    var bytes = [UInt8](repeating: 0, count: 0xF8)
    bytes[0x04] = 0xF8
    bytes[0x3A] = 0x10
    var wid = UInt32(windowID)
    memcpy(&bytes[0x3C], &wid, MemoryLayout<UInt32>.size)
    memset(&bytes[0x20], 0xFF, 0x10)
    bytes[0x08] = 0x01
    _ = SLPSPostEventRecordTo(&psn, &bytes)
    bytes[0x08] = 0x02
    _ = SLPSPostEventRecordTo(&psn, &bytes)
}


// MARK: - Dock Position Detection

enum DockPosition {
    case bottom
    case left
    case right
}

class DockPositionManager {
    static let shared = DockPositionManager()
    
    // MARK: - Dock 偏好缓存（放大效果相关）
    
    /// 是否启用放大效果（com.apple.dock magnification）
    private(set) var isMagnificationEnabled: Bool = false
    /// 静态图标边长（com.apple.dock tilesize），单位 px
    private(set) var dockTileSize: CGFloat = 64
    /// 放大后图标边长（com.apple.dock largesize），单位 px
    private(set) var dockLargeSize: CGFloat = 128
    
    /// 放大倍数：未启用时返回 1.0，启用时返回 largesize/tilesize（最小 1.0）
    var magnificationScale: CGFloat {
        guard isMagnificationEnabled else { return 1.0 }
        let tile = max(dockTileSize, 1)
        return max(1.0, dockLargeSize / tile)
    }
    
    private init() {
        loadDockPreferences()
        // 监听 Dock 偏好变更，自动刷新（用户在系统设置里改了 Dock 大小/放大会立即触发）
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(dockPreferencesChanged),
            name: NSNotification.Name("com.apple.dock.prefchanged"),
            object: nil
        )
    }
    
    @objc private func dockPreferencesChanged() {
        // 偏好变更通知到来时稍后刷新一次（避免读到中间状态）
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.loadDockPreferences()
        }
    }
    
    /// 强制重新读取 Dock 偏好（也可由外部主动调用）
    func loadDockPreferences() {
        let appId = "com.apple.dock" as CFString
        
        if let value = CFPreferencesCopyAppValue("magnification" as CFString, appId) as? Bool {
            isMagnificationEnabled = value
        }
        if let value = CFPreferencesCopyAppValue("tilesize" as CFString, appId) as? CGFloat {
            dockTileSize = value
        } else if let value = CFPreferencesCopyAppValue("tilesize" as CFString, appId) as? Double {
            dockTileSize = CGFloat(value)
        }
        if let value = CFPreferencesCopyAppValue("largesize" as CFString, appId) as? CGFloat {
            dockLargeSize = value
        } else if let value = CFPreferencesCopyAppValue("largesize" as CFString, appId) as? Double {
            dockLargeSize = CGFloat(value)
        }
    }
    
    /// 获取主显示器上的 Dock 位置（旧 API，保留兼容）
    /// ⚠️ 多显示器场景请使用 `position(for:)` 传入具体屏幕
    var currentPosition: DockPosition {
        return position(for: NSScreen.main)
    }
    
    /// 获取 Dock 的厚度（通常为 100px 左右的检测范围）
    var dockDetectionThickness: CGFloat {
        return 100
    }
    
    /// 获取主显示器 Dock 的真实像素厚度（旧 API，保留兼容）
    var realDockThickness: CGFloat {
        return realDockThickness(for: NSScreen.main)
    }
    
    // MARK: - 多显示器支持（推荐 API）
    
    /// 获取指定屏幕上的 Dock 位置
    /// - Parameter screen: 目标屏幕；nil 时退化为 .bottom
    /// - Returns: Dock 在该屏的视觉位置
    /// - Note: macOS 仅会在「鼠标所在屏幕」或「主屏」上显示 Dock。
    ///   本方法通过 visibleFrame 与 frame 的差值判断；如果该屏没有 Dock（被菜单栏屏占用），
    ///   会按差值最大的方向兜底（一般落在 .bottom）。
    func position(for screen: NSScreen?) -> DockPosition {
        guard let screen = screen else { return .bottom }
        
        let frame = screen.frame
        let visibleFrame = screen.visibleFrame
        
        // AppKit 坐标：y 向上为正。底部 Dock 让 visibleFrame.minY 高于 frame.minY
        if visibleFrame.origin.y > frame.origin.y + 0.5 {
            return .bottom
        }
        if visibleFrame.origin.x > frame.origin.x + 0.5 {
            return .left
        }
        if visibleFrame.size.width < frame.size.width - 0.5 {
            return .right
        }
        return .bottom
    }
    
    /// 获取指定屏幕上的 Dock 真实像素厚度
    /// - Parameter screen: 目标屏幕；nil 时返回 60 兜底
    func realDockThickness(for screen: NSScreen?) -> CGFloat {
        guard let screen = screen else { return 60 }
        let frame = screen.frame
        let visibleFrame = screen.visibleFrame
        let pos = position(for: screen)
        
        switch pos {
        case .bottom:
            return max(0, visibleFrame.origin.y - frame.origin.y)
        case .left:
            return max(0, visibleFrame.origin.x - frame.origin.x)
        case .right:
            let leftPad = visibleFrame.origin.x - frame.origin.x
            return max(0, frame.width - leftPad - visibleFrame.width)
        }
    }
}

// MARK: - 屏幕坐标工具

/// 多显示器下的屏幕辅助工具
/// 用于在 EventTap 拿到的 CG 全局坐标 (左上原点) 与 AppKit 坐标 (左下原点) 之间正确转换。
enum ScreenLocator {
    /// 把 CG 全局坐标 (主屏左上为原点) 转换为 AppKit 全局坐标 (主屏左下为原点)
    /// 注意：CG.y=0 等价于 AppKit.y = primaryScreen.frame.maxY
    /// 这条规则在多屏排列下也成立（即使副屏在主屏左侧 / 上方）。
    static func appKitPoint(fromCGGlobal cgPoint: CGPoint) -> CGPoint {
        let primaryMaxY: CGFloat = NSScreen.screens.first.map { $0.frame.origin.y + $0.frame.height } ?? 0
        return CGPoint(x: cgPoint.x, y: primaryMaxY - cgPoint.y)
    }
    
    /// 把 AppKit 全局坐标 (主屏左下为原点) 转换为 CG 全局坐标 (主屏左上为原点)
    static func cgPoint(fromAppKitGlobal akPoint: CGPoint) -> CGPoint {
        let primaryMaxY: CGFloat = NSScreen.screens.first.map { $0.frame.origin.y + $0.frame.height } ?? 0
        return CGPoint(x: akPoint.x, y: primaryMaxY - akPoint.y)
    }
    
    /// 用 CG 全局坐标定位包含该点的屏幕
    static func screenContainingCG(point cgPoint: CGPoint) -> NSScreen? {

        let akPoint = appKitPoint(fromCGGlobal: cgPoint)
        return screenContainingAppKit(point: akPoint)
    }
    
    /// 用 AppKit 全局坐标定位包含该点的屏幕
    static func screenContainingAppKit(point akPoint: CGPoint) -> NSScreen? {
        for screen in NSScreen.screens {
            if screen.frame.contains(akPoint) {
                return screen
            }
        }
        // 落在屏幕缝隙时取最近的一块，避免返回 nil
        var closest: NSScreen?
        var closestDist = CGFloat.greatestFiniteMagnitude
        for screen in NSScreen.screens {
            let center = CGPoint(x: screen.frame.midX, y: screen.frame.midY)
            let dx = center.x - akPoint.x
            let dy = center.y - akPoint.y
            let dist = dx * dx + dy * dy
            if dist < closestDist {
                closestDist = dist
                closest = screen
            }
        }
        return closest ?? NSScreen.main
    }
}

