//
//  UpdateChecker.swift
//  DockMinimize
//
//  检查更新：从服务器拉取 version.json，与本地版本比较
//

import Cocoa

class UpdateChecker {
    static let shared = UpdateChecker()
    
    private let updateInfoURL = URL(string: "https://www.ivean.com/dockminimize/updates/version.json")!
    
    private let t: (String, String) -> String = { zh, en in
        SettingsManager.shared.t(zh, en)
    }
    
    func checkForUpdates(manual: Bool = false) {
        var request = URLRequest(url: updateInfoURL)
        request.timeoutInterval = 5
        // 禁用缓存，确保每次都拉最新数据
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        
        URLSession.shared.dataTask(with: request) { data, response, error in
            guard let data = data, error == nil else {
                if manual {
                    DispatchQueue.main.async {
                        self.showAlert(
                            title: self.t("检查更新失败", "Update Check Failed"),
                            message: self.t("无法连接到服务器，请检查网络设置。", "Unable to connect to server. Please check your network settings.")
                        )
                    }
                }
                return
            }
            
            do {
                if let json = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
                   let latestVersion = json["version"] as? String {
                    
                    let downloadURLString = json["download_url"] as? String
                    
                    if let finalURLString = downloadURLString, let downloadURL = URL(string: finalURLString) {
                        
                        let releaseNotes = json["release_notes"] as? String ?? self.t("包含重要的性能改进与功能更新。", "Includes important performance improvements and feature updates.")
                        
                        let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
                        
                        if self.isVersionGreaterThan(latestVersion, currentVersion) {
                            DispatchQueue.main.async {
                                self.showUpdateAlert(latestVersion: latestVersion, releaseNotes: releaseNotes, downloadURL: downloadURL)
                            }
                        } else {
                            if manual {
                                DispatchQueue.main.async {
                                    self.showAlert(
                                        title: self.t("已是最新版本", "Up to Date"),
                                        message: self.t("当前 DockMinimize 版本 ", "Current DockMinimize version ") + currentVersion + self.t(" 已经是最新版。", " is the latest.")
                                    )
                                }
                            }
                        }
                    }
                }
            } catch {
                if manual {
                    DispatchQueue.main.async {
                        self.showAlert(
                            title: self.t("解析失败", "Parse Error"),
                            message: self.t("服务器返回的数据格式不正确。", "Server returned an invalid data format.")
                        )
                    }
                }
            }
        }.resume()
    }
    
    private func isVersionGreaterThan(_ v1: String, _ v2: String) -> Bool {
        let parts1 = v1.split(separator: ".").compactMap { Int($0) }
        let parts2 = v2.split(separator: ".").compactMap { Int($0) }
        
        let maxCount = max(parts1.count, parts2.count)
        
        for i in 0..<maxCount {
            let p1 = i < parts1.count ? parts1[i] : 0
            let p2 = i < parts2.count ? parts2[i] : 0
            
            if p1 > p2 { return true }
            if p1 < p2 { return false }
        }
        
        return false
    }
    
    private func showUpdateAlert(latestVersion: String, releaseNotes: String, downloadURL: URL) {
        let alert = NSAlert()
        alert.messageText = t("发现新版本: ", "New version found: ") + latestVersion
        alert.informativeText = releaseNotes
        alert.alertStyle = .informational
        
        alert.addButton(withTitle: t("前往下载", "Download"))
        alert.addButton(withTitle: t("稍后", "Later"))
        
        NSApp.activate(ignoringOtherApps: true)
        
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            NSWorkspace.shared.open(downloadURL)
        }
    }
    
    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: t("确定", "OK"))
        
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
