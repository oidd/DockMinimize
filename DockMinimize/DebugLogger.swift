//
//  DebugLogger.swift
//  DockMinimize
//
//  Debug logger with floating window + persistent file logging
//

import Cocoa
import SwiftUI

class DebugLogger: ObservableObject {
    static let shared = DebugLogger()
    
    @Published var logs: [String] = []
    private var debugWindow: NSWindow?
    
    // MARK: - 文件日志
    
    /// 日志目录：~/Library/Logs/DockMinimize/
    private let logDirectory: URL = {
        let logsDir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Logs")
            .appendingPathComponent("DockMinimize")
        try? FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
        return logsDir
    }()
    
    /// 当前日志文件路径
    private var currentLogFile: URL {
        return logDirectory.appendingPathComponent("dockminimize.log")
    }
    
    /// 文件写入句柄
    private var fileHandle: FileHandle?
    
    /// 单文件上限 2MB
    private let maxFileSize: UInt64 = 2 * 1024 * 1024
    
    /// 保留最近 3 个轮转文件
    private let maxRotatedFiles: Int = 3
    
    /// 文件写入队列（串行，防止并发写入冲突）
    private let fileQueue = DispatchQueue(label: "com.dockminimize.logger.file", qos: .utility)
    
    private init() {
        setupFileLogging()
        log("🚀 DebugLogger initialized (persistent logging enabled)")
        log("📁 Log directory: \(logDirectory.path)")
    }
    
    deinit {
        fileHandle?.closeFile()
    }
    
    // MARK: - 日志写入
    
    func log(_ message: String) {
        let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        let logMessage = "[\(timestamp)] \(message)"
        
        // 内存日志（UI 用）
        DispatchQueue.main.async {
            self.logs.append(logMessage)
            if self.logs.count > 500 {
                self.logs.removeFirst()
            }
        }
        
        // 控制台输出
        print(logMessage)
        
        // 文件持久化
        fileQueue.async { [weak self] in
            self?.writeToFile(logMessage)
        }
    }
    
    /// 记录关键崩溃事件（同步写入，确保闪退前数据落盘）
    func logCritical(_ message: String) {
        let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        let logMessage = "[\(timestamp)] 🚨 CRITICAL: \(message)"
        
        print(logMessage)
        
        // 同步写入，确保数据落盘
        fileQueue.sync {
            writeToFile(logMessage)
            fileHandle?.synchronizeFile()
        }
    }
    
    /// 强制将缓冲区写入磁盘（闪退前调用）
    func flush() {
        fileQueue.sync {
            fileHandle?.synchronizeFile()
        }
    }
    
    // MARK: - 文件日志管理
    
    private func setupFileLogging() {
        fileQueue.sync {
            let filePath = currentLogFile.path
            
            // 如果文件不存在，创建它
            if !FileManager.default.fileExists(atPath: filePath) {
                FileManager.default.createFile(atPath: filePath, contents: nil)
            }
            
            // 检查是否需要轮转
            rotateIfNeeded()
            
            // 打开文件句柄
            fileHandle = FileHandle(forWritingAtPath: filePath)
            fileHandle?.seekToEndOfFile()
            
            // 写入启动分隔线
            let separator = "\n========== DockMinimize Session Start: \(Date()) ==========\n"
            if let data = separator.data(using: .utf8) {
                fileHandle?.write(data)
            }
        }
    }
    
    private func writeToFile(_ message: String) {
        guard let data = (message + "\n").data(using: .utf8) else { return }
        fileHandle?.write(data)
        
        // 每 100 条检查一次文件大小，避免频繁 IO
        rotateIfNeeded()
    }
    
    /// 日志轮转：文件超过上限时重命名旧文件
    private func rotateIfNeeded() {
        let filePath = currentLogFile.path
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: filePath),
              let fileSize = attributes[.size] as? UInt64,
              fileSize > maxFileSize else {
            return
        }
        
        // 关闭当前句柄
        fileHandle?.closeFile()
        fileHandle = nil
        
        // 删除最老的轮转文件
        let oldestLog = logDirectory.appendingPathComponent("dockminimize.\(maxRotatedFiles).log")
        try? FileManager.default.removeItem(at: oldestLog)
        
        // 依次重命名 N-1 -> N
        for i in stride(from: maxRotatedFiles - 1, through: 1, by: -1) {
            let src = logDirectory.appendingPathComponent("dockminimize.\(i).log")
            let dst = logDirectory.appendingPathComponent("dockminimize.\(i + 1).log")
            try? FileManager.default.moveItem(at: src, to: dst)
        }
        
        // 当前文件 -> .1.log
        let rotatedPath = logDirectory.appendingPathComponent("dockminimize.1.log")
        try? FileManager.default.moveItem(at: currentLogFile, to: rotatedPath)
        
        // 创建新文件
        FileManager.default.createFile(atPath: filePath, contents: nil)
        fileHandle = FileHandle(forWritingAtPath: filePath)
        fileHandle?.seekToEndOfFile()
    }
    
    // MARK: - Debug Window (保持不变)
    
    func showDebugWindow() {
        debugWindow?.close()
        debugWindow = nil
        
        let contentView = DebugLogView()
        
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 500, height: 300),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Dock Minimize Debug"
        window.contentView = NSHostingView(rootView: contentView)
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.center()
        window.makeKeyAndOrderFront(nil)
        
        debugWindow = window
        
        log("Debug window opened")
    }
    
    func closeDebugWindow() {
        debugWindow?.close()
        debugWindow = nil
    }
}

struct DebugLogView: View {
    @ObservedObject var logger = DebugLogger.shared
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Debug Logs")
                    .font(.headline)
                Spacer()
                Button("Clear") {
                    logger.logs.removeAll()
                }
            }
            .padding(.horizontal)
            .padding(.top, 8)
            
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(logger.logs.enumerated()), id: \.offset) { index, log in
                            Text(log)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(.green)
                                .id(index)
                        }
                    }
                    .padding(.horizontal)
                }
                .onChange(of: logger.logs.count) { _ in
                    if let lastIndex = logger.logs.indices.last {
                        proxy.scrollTo(lastIndex, anchor: .bottom)
                    }
                }
            }
            .background(Color.black)
        }
        .frame(minWidth: 400, minHeight: 200)
    }
}
