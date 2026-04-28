//
//  DockOwnershipTipController.swift
//  DockMinimize
//

import Cocoa
import SwiftUI

final class DockOwnershipTipController: NSObject, ObservableObject {
    static let shared = DockOwnershipTipController()

    @Published private(set) var titleText: String = ""
    @Published private(set) var messageText: String = ""
    @Published private(set) var remainingSeconds: Int = 15

    private let panelWidth: CGFloat = 540
    private let panelHeight: CGFloat = 156

    private var currentOwner: SideBarHotkeyClaim.HotkeyOwner = .dockminimize
    private var window: NSPanel?
    private var countdownTimer: Timer?
    private var dismissWorkItem: DispatchWorkItem?

    private override init() {
        super.init()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleOwnershipTransferNotification(_:)),
            name: .sideBarBridgeOwnershipTransferReceived,
            object: nil
        )
    }

    func start() {
        ensureWindow()
    }

    @objc private func handleOwnershipTransferNotification(_ notification: Notification) {
        guard let notice = notification.object as? SideBarOwnershipTransferNotice else { return }
        show(notice: notice)
    }

    private func show(notice: SideBarOwnershipTransferNotice) {
        guard !SettingsManager.shared.shouldSuppressDockOwnershipTip(for: notice.owner) else { return }

        currentOwner = notice.owner
        titleText = SettingsManager.shared.t(
            "检测到复杂窗口环境",
            "Complex Window Environment Detected"
        )
        messageText = message(for: notice)
        remainingSeconds = 15

        ensureWindow()
        updateWindowPosition()

        dismissWorkItem?.cancel()
        countdownTimer?.invalidate()

        window?.alphaValue = 0
        window?.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            self.window?.animator().alphaValue = 1
        }

        countdownTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }

            if self.remainingSeconds <= 1 {
                timer.invalidate()
                self.dismiss(animated: true)
                return
            }

            self.remainingSeconds -= 1
        }

        let dismissWorkItem = DispatchWorkItem { [weak self] in
            self?.dismiss(animated: true)
        }
        self.dismissWorkItem = dismissWorkItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 15.0, execute: dismissWorkItem)
    }

    func dismissNow() {
        dismiss(animated: true)
    }

    func dismissAndSuppressFutureTips() {
        SettingsManager.shared.setSuppressDockOwnershipTip(true, for: currentOwner)
        dismiss(animated: true)
    }

    private func dismiss(animated: Bool) {
        dismissWorkItem?.cancel()
        dismissWorkItem = nil
        countdownTimer?.invalidate()
        countdownTimer = nil

        guard let window else { return }

        let hideWindow = {
            window.orderOut(nil)
        }

        guard animated, window.isVisible else {
            hideWindow()
            return
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.14
            window.animator().alphaValue = 0
        } completionHandler: {
            hideWindow()
        }
    }

    private func ensureWindow() {
        guard window == nil else {
            if let window {
                updateHostingView(for: window)
            }
            return
        }

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.ignoresMouseEvents = false
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isReleasedWhenClosed = false
        panel.alphaValue = 0
        panel.becomesKeyOnlyIfNeeded = true

        updateHostingView(for: panel)
        window = panel
    }

    private func updateHostingView(for panel: NSPanel) {
        panel.contentView = NSHostingView(rootView: DockOwnershipTipView(controller: self))
    }

    private func updateWindowPosition() {
        guard let window, let screen = NSScreen.main else { return }

        let width = panelWidth
        let height = panelHeight
        let dockPosition = DockPositionManager.shared.currentPosition
        let dockThickness = max(DockPositionManager.shared.realDockThickness, 24)
        let horizontalPadding: CGFloat = 20
        let verticalPadding: CGFloat = 18

        let origin: CGPoint
        switch dockPosition {
        case .bottom:
            origin = CGPoint(
                x: screen.frame.midX - width / 2,
                y: screen.frame.minY + dockThickness + verticalPadding
            )
        case .left:
            origin = CGPoint(
                x: screen.frame.minX + dockThickness + horizontalPadding,
                y: screen.frame.maxY - height - 56
            )
        case .right:
            origin = CGPoint(
                x: screen.frame.maxX - dockThickness - width - horizontalPadding,
                y: screen.frame.maxY - height - 56
            )
        }

        window.setFrameOrigin(origin)
    }

    private func message(for notice: SideBarOwnershipTransferNotice) -> String {
        switch notice.owner {
        case .dockminimize:
            return SettingsManager.shared.t(
                "“\(notice.appName)”的某个窗口已脱离边缘。为避免多窗口控制冲突，该软件的所有窗口将统一由 DockMinimize 接管。",
                "A window in \(notice.appName) left the managed edge. To avoid multi-window control conflicts, all windows from this app will now be handled by DockMinimize."
            )
        case .sidebar:
            return SettingsManager.shared.t(
                "“\(notice.appName)”的某个窗口已贴边隐藏。为避免多窗口控制冲突，该软件的所有窗口将统一由 SideBar 接管。",
                "A window in \(notice.appName) snapped back to the managed edge. To avoid multi-window control conflicts, all windows from this app will now be handled by SideBar."
            )
        }
    }
}

private struct DockOwnershipTipView: View {
    @ObservedObject var controller: DockOwnershipTipController

    var body: some View {
        ZStack {
            VisualEffectView(material: .hudWindow, blendingMode: .behindWindow)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Color.blue.opacity(0.9), lineWidth: 1.6)
                }

            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 12) {
                    Text(controller.titleText)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.primary)
                        .padding(.top, 2)

                    Spacer()

                    Button(action: controller.dismissNow) {
                        Text(controller.closeButtonTitle)
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                    }
                    .buttonStyle(.plain)
                    .background(
                        Capsule(style: .continuous)
                            .fill(Color.blue.opacity(0.95))
                    )

                    Button(action: controller.dismissAndSuppressFutureTips) {
                        Text(controller.dismissForeverButtonTitle)
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(.primary.opacity(0.78))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                    }
                    .buttonStyle(.plain)
                    .background(
                        Capsule(style: .continuous)
                            .fill(Color.white.opacity(0.1))
                    )
                    .overlay {
                        Capsule(style: .continuous)
                            .stroke(Color.white.opacity(0.16), lineWidth: 1)
                    }
                }

                Text(controller.messageText)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(.primary.opacity(0.92))
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 18)
        }
        .frame(width: 540, height: 156)
        .shadow(color: Color.blue.opacity(0.18), radius: 18, x: 0, y: 10)
    }
}

private extension DockOwnershipTipController {
    var closeButtonTitle: String {
        SettingsManager.shared.t(
            "关闭提示（\(remainingSeconds)）",
            "Dismiss Tip (\(remainingSeconds))"
        )
    }

    var dismissForeverButtonTitle: String {
        SettingsManager.shared.t(
            "不再提示",
            "Don't Show Again"
        )
    }
}
