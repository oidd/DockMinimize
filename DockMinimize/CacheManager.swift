//
//  CacheManager.swift
//  DockMinimize
//
//  窗口缩略图本地磁盘存储与清理管理
//

import Cocoa

class CacheManager: ObservableObject {
    static let shared = CacheManager()
    
    private let log = DebugLogger.shared
    private let fileManager = FileManager.default
    
    /// 默认缓存文件夹名称
    private let defaultFolderName = "DockMinimize_Cache"
    
    /// 缓存过期时间（24小时）
    private let expirationInterval: TimeInterval = 24 * 60 * 60
    
    /// 最大缓存大小（200MB）
    private let maxCacheSize: Int64 = 200 * 1024 * 1024
    
    private init() {
        // 启动时尝试清理
        DispatchQueue.global(qos: .background).async {
            self.autoCleanup()
        }
    }
    
    /// 获取当前生效的缓存路径
    func getCacheURL() -> URL? {
        if let savedPath = UserDefaults.standard.string(forKey: "customCachePath") {
            return URL(fileURLWithPath: savedPath)
        }
        
        // --- 核心修复：严禁默认使用“文稿”或“下载”文件夹 ---
        // 应该使用标准的 Application Support 路径
        guard let appSupportURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        
        let bundleID = Bundle.main.bundleIdentifier ?? "com.dockminimize.app"
        let cacheURL = appSupportURL.appendingPathComponent(bundleID).appendingPathComponent("Thumbnails")
        
        return cacheURL
    }
    
    /// 检查权限是否已就绪（文件夹是否存在且可写）
    func checkStoragePermission() -> Bool {
        guard let url = getCacheURL() else { return false }
        
        var isDir: ObjCBool = false
        if fileManager.fileExists(atPath: url.path, isDirectory: &isDir) {
            return isDir.boolValue && fileManager.isWritableFile(atPath: url.path)
        }
        
        // 如果不存在，尝试创建（如果父目录可写）
        do {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
            return true
        } catch {
            return false
        }
    }
    
    /// 保存缩略图到磁盘
    func saveThumbnail(image: NSImage, windowId: CGWindowID) {
        guard let url = getCacheURL() else { return }
        
        // 确保目录存在
        if !fileManager.fileExists(atPath: url.path) {
            try? fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        }
        
        let fileURL = url.appendingPathComponent("\(windowId).png")
        
        DispatchQueue.global(qos: .background).async {
            guard let tiffData = image.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiffData),
                  let pngData = bitmap.representation(using: .png, properties: [:]) else {
                return
            }
            
            do {
                try pngData.write(to: fileURL)
            } catch {
                self.log.log("⚠️ Failed to save cache for window \(windowId): \(error)")
            }
        }
    }
    
    /// 从磁盘加载缩略图
    func loadThumbnail(windowId: CGWindowID) -> NSImage? {
        guard let url = getCacheURL() else { return nil }
        let fileURL = url.appendingPathComponent("\(windowId).png")
        
        if fileManager.fileExists(atPath: fileURL.path) {
            // 更新访问时间，防止被清理
            try? fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: fileURL.path)
            return NSImage(contentsOf: fileURL)
        }
        return nil
    }
    
    /// 自动清理逻辑
    func autoCleanup() {
        guard let url = getCacheURL(), fileManager.fileExists(atPath: url.path) else { return }
        
        do {
            let resourceKeys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
            let files = try fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: resourceKeys, options: [])
            
            var totalSize: Int64 = 0
            let now = Date()
            
            for fileURL in files {
                let resourceValues = try fileURL.resourceValues(forKeys: Set(resourceKeys))
                
                // 1. 按时间清理
                if let modDate = resourceValues.contentModificationDate,
                   now.timeIntervalSince(modDate) > expirationInterval {
                    try fileManager.removeItem(at: fileURL)
                    continue
                }
                
                if let size = resourceValues.fileSize {
                    totalSize += Int64(size)
                }
            }
            
            // 2. 按容量清理（如果超过最大限制，删除最旧的文件）
            if totalSize > maxCacheSize {
                log.log("🧹 Cache size (\(totalSize / 1024 / 1024)MB) exceeds limit, deep cleaning...")
                let sortedFiles = try files.sorted { (u1, u2) -> Bool in
                    let d1 = try u1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? Date.distantPast
                    let d2 = try u2.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? Date.distantPast
                    return d1 < d2
                }
                
                var currentTotal = totalSize
                for fileURL in sortedFiles {
                    if currentTotal <= (maxCacheSize / 2) { break } // 清理到一半大小
                    let size = try fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                    try fileManager.removeItem(at: fileURL)
                    currentTotal -= Int64(size)
                }
            }
            
        } catch {
            log.log("⚠️ Cache cleanup error: \(error)")
        }
    }
    
    /// 用户选择新路径
    func setCustomPath(_ url: URL) {
        UserDefaults.standard.set(url.path, forKey: "customCachePath")
        log.log("📂 Cache path changed to: \(url.path)")
        
        // 确保新路径可写
        _ = checkStoragePermission()
    }
}
