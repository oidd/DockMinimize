//
//  DebugLogger.swift
//  DockMinimize
//
//  Debug logger with floating window
//

import Cocoa
import SwiftUI

class DebugLogger: ObservableObject {
    static let shared = DebugLogger()
    
    @Published var logs: [String] = []
    private var debugWindow: NSWindow?
    
    private init() {}
    
    func log(_ message: String) {
        let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        let logMessage = "[\(timestamp)] \(message)"
        
        DispatchQueue.main.async {
            self.logs.append(logMessage)
            // 限制日志数量
            if self.logs.count > 50 {
                self.logs.removeFirst()
            }
            print(logMessage) // 同时输出到控制台
        }
    }
    
    func showDebugWindow() {
        // 关闭旧窗口
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
