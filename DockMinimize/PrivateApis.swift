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
    
    private init() {}
    
    /// 获取当前主显示器上的 Dock 位置
    var currentPosition: DockPosition {
        guard let screen = NSScreen.main else { return .bottom }
        
        let frame = screen.frame
        let visibleFrame = screen.visibleFrame
        
        // 1. 判断底部：visibleFrame.origin.y > 0
        if visibleFrame.origin.y > frame.origin.y {
            return .bottom
        }
        
        // 2. 判断左侧：visibleFrame.origin.x > 0
        if visibleFrame.origin.x > frame.origin.x {
            return .left
        }
        
        // 3. 判断右侧：visibleFrame.size.width < frame.size.width
        if visibleFrame.size.width < frame.size.width {
            return .right
        }
        
        return .bottom
    }
    
    /// 获取 Dock 的厚度（通常为 100px 左右的检测范围）
    var dockDetectionThickness: CGFloat {
        return 100
    }
}
