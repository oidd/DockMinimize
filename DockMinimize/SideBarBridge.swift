//
//  SideBarBridge.swift
//  DockMinimize
//

import Cocoa
import Foundation

extension Notification.Name {
    static let sideBarBridgeStateChanged = Notification.Name("sideBarBridgeStateChanged")
}

struct SideBarHotkeyClaim: Codable, Equatable {
    enum HotkeyOwner: String, Codable {
        case dockminimize
        case sidebar
    }

    let hotkeyOwner: HotkeyOwner
    let state: String
    let sessionID: String?
    let lastChangedAt: String?

    var shouldRouteToSideBar: Bool {
        hotkeyOwner == .sidebar
    }
}

private struct SideBarDockExclusionsPayload: Codable {
    let version: Int
    let updatedAt: String?
    let bundleIDs: [String]
    let reasons: [String: [String]]?
}

private struct SideBarHotkeyRuntimePayload: Codable {
    let version: Int
    let updatedAt: String?
    let sidebarRunning: Bool
    let claims: [String: SideBarHotkeyClaim]
}

private struct DockMinimizeHotkeyBindingsPayload: Codable {
    struct Binding: Codable {
        let bundleID: String
        let keyCode: Int
        let modifierFlagsRawValue: UInt64
        let displayString: String
    }

    let version: Int
    let updatedAt: String
    let bindings: [Binding]
}

final class SideBarBridge: NSObject {
    static let shared = SideBarBridge()

    private struct NotificationNames {
        static let legacyManagedAppsChanged = NSNotification.Name("com.ivean.SideBar.managedAppsDidChange")
        static let dockExclusionsChanged = NSNotification.Name("com.ivean.SideBar.dockExclusionsDidChange")
        static let hotkeyRuntimeChanged = NSNotification.Name("com.ivean.SideBar.hotkeyRuntimeDidChange")
        static let requestSideBarHotkeyAction = NSNotification.Name("com.ivean.DockMinimize.requestSideBarHotkeyAction")
        static let sideBarHotkeyActionAck = NSNotification.Name("com.ivean.SideBar.sideBarHotkeyActionAck")
        static let hotkeyBindingsChanged = NSNotification.Name("com.ivean.DockMinimize.hotkeyBindingsDidChange")
    }

    private struct FileNames {
        static let sharedDirectory = "Library/Application Support/ivean.shared"
        static let legacyManagedApps = "sidebar_managed_apps.json"
        static let dockExclusions = "sidebar_dock_exclusions.v1.json"
        static let hotkeyRuntime = "sidebar_hotkey_runtime.v1.json"
        static let dockMinimizeHotkeys = "dockminimize_hotkey_bindings.v1.json"
    }

    private struct PendingHotkeyRequest {
        let bundleID: String
        let completion: (Bool) -> Void
        let timeoutWorkItem: DispatchWorkItem
    }

    private let sideBarBundleID = "com.ivean.SideBar"
    private let requestTimeout: TimeInterval = 0.35
    private let distributedCenter = DistributedNotificationCenter.default()
    private let notificationCenter = NotificationCenter.default
    private let fileManager = FileManager.default
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()
    private let logger = DebugLogger.shared
    // Guard against stale SideBar claims during drag-out transitions.
    private let edgeOwnershipTolerance: CGFloat = 48
    // Only keep a tiny protection window right after SideBar hands a detached window back to DockMinimize.
    private let detachedFloatingHandoffGuard: TimeInterval = 0.8

    private var didStart = false
    private var pendingRequests: [String: PendingHotkeyRequest] = [:]

    private(set) var dockExcludedBundleIDs: [String] = []
    private(set) var hotkeyClaims: [String: SideBarHotkeyClaim] = [:]

    private override init() {
        super.init()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }

    func loadInitialState() {
        applySharedState(
            dockExcludedBundleIDs: loadDockExclusions(),
            hotkeyClaims: loadHotkeyRuntimeClaims()
        )
    }

    func start(with hotkeyBindings: [AppHotkeyBinding]) {
        if !didStart {
            didStart = true

            notificationCenter.addObserver(
                self,
                selector: #selector(handleLocalHotkeyBindingsChanged),
                name: .hotkeyBindingsChanged,
                object: nil
            )

            notificationCenter.addObserver(
                self,
                selector: #selector(handleAppTermination(_:)),
                name: NSWorkspace.didTerminateApplicationNotification,
                object: nil
            )

            distributedCenter.addObserver(
                self,
                selector: #selector(handleDockExclusionsChanged(_:)),
                name: NotificationNames.dockExclusionsChanged,
                object: nil
            )

            distributedCenter.addObserver(
                self,
                selector: #selector(handleLegacyManagedAppsChanged(_:)),
                name: NotificationNames.legacyManagedAppsChanged,
                object: nil
            )

            distributedCenter.addObserver(
                self,
                selector: #selector(handleHotkeyRuntimeChanged(_:)),
                name: NotificationNames.hotkeyRuntimeChanged,
                object: nil
            )

            distributedCenter.addObserver(
                self,
                selector: #selector(handleHotkeyActionAck(_:)),
                name: NotificationNames.sideBarHotkeyActionAck,
                object: nil
            )
        }

        loadInitialState()
        exportHotkeyBindings(hotkeyBindings)
    }

    func stop() {
        resolveAllPendingRequests(handled: false)
    }

    func shouldForwardHotkey(for bundleID: String) -> Bool {
        guard isSideBarRunning else { return false }
        guard let claim = hotkeyClaims[bundleID], claim.shouldRouteToSideBar else {
            return false
        }
        return shouldHonorHotkeyClaim(claim, for: bundleID)
    }

    func requestSideBarHotkeyAction(
        bundleID: String,
        shortcut: KeyboardShortcut,
        completion: @escaping (Bool) -> Void
    ) {
        DispatchQueue.main.async {
            guard self.shouldForwardHotkey(for: bundleID) else {
                completion(false)
                return
            }

            let requestID = UUID().uuidString
            let timeoutWorkItem = DispatchWorkItem { [weak self] in
                self?.resolvePendingRequest(requestID: requestID, handled: false)
            }

            self.pendingRequests[requestID] = PendingHotkeyRequest(
                bundleID: bundleID,
                completion: completion,
                timeoutWorkItem: timeoutWorkItem
            )

            DispatchQueue.main.asyncAfter(deadline: .now() + self.requestTimeout, execute: timeoutWorkItem)

            let userInfo: [String: Any] = [
                "requestID": requestID,
                "bundleID": bundleID,
                "triggerSource": "dockminimize_global_hotkey",
                "keyCode": shortcut.keyCode,
                "modifierFlagsRawValue": shortcut.modifierFlagsRawValue,
                "sentAt": Self.iso8601String(from: Date())
            ]

            self.distributedCenter.postNotificationName(
                NotificationNames.requestSideBarHotkeyAction,
                object: nil,
                userInfo: userInfo,
                deliverImmediately: true
            )
        }
    }

    func requiresDetachedFloatingGuard(for bundleID: String) -> Bool {
        guard let claim = hotkeyClaims[bundleID] else { return false }
        guard claim.hotkeyOwner == .dockminimize, claim.state == "floating" else {
            return false
        }
        guard let changedAt = parseISO8601Date(claim.lastChangedAt) else {
            return false
        }
        return Date().timeIntervalSince(changedAt) <= detachedFloatingHandoffGuard
    }

    func exportHotkeyBindings(_ hotkeyBindings: [AppHotkeyBinding]) {
        let bindings = hotkeyBindings.compactMap { binding -> DockMinimizeHotkeyBindingsPayload.Binding? in
            guard let shortcut = binding.shortcut else { return nil }
            return DockMinimizeHotkeyBindingsPayload.Binding(
                bundleID: binding.bundleID,
                keyCode: shortcut.keyCode,
                modifierFlagsRawValue: shortcut.modifierFlagsRawValue,
                displayString: shortcut.displayString
            )
        }.sorted { $0.bundleID < $1.bundleID }

        let payload = DockMinimizeHotkeyBindingsPayload(
            version: 1,
            updatedAt: Self.iso8601String(from: Date()),
            bindings: bindings
        )

        do {
            try ensureSharedDirectoryExists()
            let data = try encoder.encode(payload)
            try data.write(to: dockMinimizeHotkeysURL, options: .atomic)
            distributedCenter.postNotificationName(
                NotificationNames.hotkeyBindingsChanged,
                object: nil,
                userInfo: nil,
                deliverImmediately: true
            )
        } catch {
            logger.log("⚠️ [SideBarBridge] Failed to export DockMinimize hotkeys: \(error)")
        }
    }

    @objc private func handleLocalHotkeyBindingsChanged() {
        exportHotkeyBindings(SettingsManager.shared.hotkeyBindings)
    }

    @objc private func handleDockExclusionsChanged(_ notification: Notification) {
        let claims = loadHotkeyRuntimeClaims()
        let exclusions = loadDockExclusions()
        applySharedState(dockExcludedBundleIDs: exclusions, hotkeyClaims: claims)
    }

    @objc private func handleLegacyManagedAppsChanged(_ notification: Notification) {
        let claims = loadHotkeyRuntimeClaims()
        let exclusions = loadDockExclusions()
        applySharedState(dockExcludedBundleIDs: exclusions, hotkeyClaims: claims)
    }

    @objc private func handleHotkeyRuntimeChanged(_ notification: Notification) {
        let claims = loadHotkeyRuntimeClaims()
        let exclusions = loadDockExclusions()
        applySharedState(dockExcludedBundleIDs: exclusions, hotkeyClaims: claims)
    }

    @objc private func handleHotkeyActionAck(_ notification: Notification) {
        guard let userInfo = notification.userInfo else { return }

        DispatchQueue.main.async {
            let requestID = userInfo["requestID"] as? String ?? ""
            guard !requestID.isEmpty else { return }

            let handled = userInfo["handled"] as? Bool ?? false
            self.resolvePendingRequest(requestID: requestID, handled: handled)
        }
    }

    @objc private func handleAppTermination(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              app.bundleIdentifier == sideBarBundleID else {
            return
        }

        applySharedState(dockExcludedBundleIDs: [], hotkeyClaims: [:])
        resolveAllPendingRequests(handled: false)
    }

    private func loadDockExclusions() -> [String] {
        guard isSideBarRunning else { return [] }

        if let payload: SideBarDockExclusionsPayload = decodeJSONFile(at: dockExclusionsURL) {
            return normalizedBundleIDs(payload.bundleIDs)
        }

        if let legacyBundleIDs = loadLegacyManagedApps() {
            return normalizedBundleIDs(legacyBundleIDs)
        }

        return []
    }

    private func loadLegacyManagedApps() -> [String]? {
        guard fileManager.fileExists(atPath: legacyManagedAppsURL.path) else { return nil }

        do {
            let data = try Data(contentsOf: legacyManagedAppsURL)
            return try JSONSerialization.jsonObject(with: data) as? [String]
        } catch {
            logger.log("⚠️ [SideBarBridge] Failed to read legacy SideBar managed apps: \(error)")
            return nil
        }
    }

    private func loadHotkeyRuntimeClaims() -> [String: SideBarHotkeyClaim] {
        guard isSideBarRunning else { return [:] }
        guard let payload: SideBarHotkeyRuntimePayload = decodeJSONFile(at: hotkeyRuntimeURL),
              payload.sidebarRunning else {
            return [:]
        }

        return payload.claims.filter { $0.value.shouldRouteToSideBar || $0.value.hotkeyOwner == .dockminimize }
    }

    private func shouldHonorHotkeyClaim(_ claim: SideBarHotkeyClaim, for bundleID: String) -> Bool {
        switch claim.state {
        case "snapped_hidden":
            // A snapped hidden SideBar window intentionally lives mostly off-screen with only a tiny edge sliver.
            // Treat the runtime claim as authoritative here; geometry heuristics are only safe for expanded windows.
            return true

        case "expanded_visible":
            let windows = activeVisibleWindows(for: bundleID)
            return windows.contains { isWindowNearManagedEdge($0.bounds) }

        default:
            return claim.shouldRouteToSideBar
        }
    }

    private func activeVisibleWindows(for bundleID: String) -> [WindowThumbnailService.WindowInfo] {
        WindowThumbnailService.shared.getWindows(for: bundleID, respectDockExclusions: false)
            .filter { !$0.isMinimized }
            .filter { !CFEqual($0.axElement, $0.appAxElement) }
    }

    private func isWindowNearManagedEdge(_ bounds: CGRect) -> Bool {
        for screen in NSScreen.screens {
            let leftDistance = abs(bounds.minX - screen.frame.minX)
            let rightDistance = abs(bounds.maxX - screen.frame.maxX)
            if min(leftDistance, rightDistance) <= edgeOwnershipTolerance {
                return true
            }
        }
        return false
    }

    private func applySharedState(
        dockExcludedBundleIDs newDockExcludedBundleIDs: [String],
        hotkeyClaims newHotkeyClaims: [String: SideBarHotkeyClaim]
    ) {
        let normalizedExclusions = normalizedBundleIDs(newDockExcludedBundleIDs)
        let normalizedClaims = Dictionary(uniqueKeysWithValues: newHotkeyClaims.sorted { $0.key < $1.key })

        let exclusionsChanged = normalizedExclusions != dockExcludedBundleIDs
        let claimsChanged = normalizedClaims != hotkeyClaims
        guard exclusionsChanged || claimsChanged else { return }

        dockExcludedBundleIDs = normalizedExclusions
        hotkeyClaims = normalizedClaims
        notificationCenter.post(name: .sideBarBridgeStateChanged, object: nil)
    }

    private func resolvePendingRequest(requestID: String, handled: Bool) {
        guard let pendingRequest = pendingRequests.removeValue(forKey: requestID) else { return }
        pendingRequest.timeoutWorkItem.cancel()
        pendingRequest.completion(handled)
    }

    private func resolveAllPendingRequests(handled: Bool) {
        let requestIDs = pendingRequests.keys
        for requestID in requestIDs {
            resolvePendingRequest(requestID: requestID, handled: handled)
        }
    }

    private func decodeJSONFile<T: Decodable>(at url: URL) -> T? {
        guard fileManager.fileExists(atPath: url.path) else { return nil }

        do {
            let data = try Data(contentsOf: url)
            return try decoder.decode(T.self, from: data)
        } catch {
            logger.log("⚠️ [SideBarBridge] Failed to decode \(url.lastPathComponent): \(error)")
            return nil
        }
    }

    private func ensureSharedDirectoryExists() throws {
        try fileManager.createDirectory(
            at: sharedDirectoryURL,
            withIntermediateDirectories: true,
            attributes: nil
        )
    }

    private func normalizedBundleIDs(_ bundleIDs: [String]) -> [String] {
        Array(Set(bundleIDs.filter { !$0.isEmpty })).sorted()
    }

    private static func iso8601String(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private func parseISO8601Date(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let parsed = formatter.date(from: value) {
            return parsed
        }

        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    private var isSideBarRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: sideBarBundleID).isEmpty
    }

    private var sharedDirectoryURL: URL {
        fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(FileNames.sharedDirectory, isDirectory: true)
    }

    private var legacyManagedAppsURL: URL {
        sharedDirectoryURL.appendingPathComponent(FileNames.legacyManagedApps)
    }

    private var dockExclusionsURL: URL {
        sharedDirectoryURL.appendingPathComponent(FileNames.dockExclusions)
    }

    private var hotkeyRuntimeURL: URL {
        sharedDirectoryURL.appendingPathComponent(FileNames.hotkeyRuntime)
    }

    private var dockMinimizeHotkeysURL: URL {
        sharedDirectoryURL.appendingPathComponent(FileNames.dockMinimizeHotkeys)
    }
}
