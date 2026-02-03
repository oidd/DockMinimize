//
//  DockMinimizeApp.swift
//  DockMinimize
//
//  Created by Dock Minimize
//

import SwiftUI

@main
struct DockMinimizeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}
