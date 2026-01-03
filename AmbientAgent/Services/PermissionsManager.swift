import Foundation
import EventKit
import AppKit
import AmbientCore

/// Manages and checks all required permissions
@Observable
@MainActor
public final class PermissionsManager {
    static let shared = PermissionsManager()

    // MARK: - Permission States

    var calendarPermission: PermissionState = .unknown
    var remindersPermission: PermissionState = .unknown
    var automationPermission: PermissionState = .unknown
    var fullDiskAccessPermission: PermissionState = .unknown
    var notificationsPermission: PermissionState = .unknown

    // MARK: - Computed Properties

    var hasRequiredPermissions: Bool {
        calendarPermission == .granted
    }

    var hasAllPermissions: Bool {
        calendarPermission == .granted &&
        fullDiskAccessPermission == .granted &&
        automationPermission == .granted
    }

    var needsOnboarding: Bool {
        !hasRequiredPermissions
    }

    // MARK: - Initialization

    private init() {
        checkAllPermissions()
    }

    // MARK: - Check All Permissions

    func checkAllPermissions() {
        checkCalendarPermission()
        checkRemindersPermission()
        checkFullDiskAccess()
        checkAutomationPermission()
    }

    // MARK: - Calendar Permission

    func checkCalendarPermission() {
        let status = EKEventStore.authorizationStatus(for: .event)
        switch status {
        case .notDetermined:
            calendarPermission = .notRequested
        case .restricted, .denied:
            calendarPermission = .denied
        case .fullAccess, .writeOnly:
            calendarPermission = .granted
        @unknown default:
            calendarPermission = .unknown
        }
    }

    func requestCalendarPermission() async -> Bool {
        let eventStore = EKEventStore()
        do {
            if #available(macOS 14.0, *) {
                let granted = try await eventStore.requestFullAccessToEvents()
                calendarPermission = granted ? .granted : .denied
                return granted
            } else {
                let granted: Bool = try await withCheckedThrowingContinuation { continuation in
                    eventStore.requestAccess(to: .event) { granted, error in
                        if let error {
                            continuation.resume(throwing: error)
                        } else {
                            continuation.resume(returning: granted)
                        }
                    }
                }
                calendarPermission = granted ? .granted : .denied
                return granted
            }
        } catch {
            calendarPermission = .denied
            return false
        }
    }

    // MARK: - Reminders Permission

    func checkRemindersPermission() {
        let status = EKEventStore.authorizationStatus(for: .reminder)
        switch status {
        case .notDetermined:
            remindersPermission = .notRequested
        case .restricted, .denied:
            remindersPermission = .denied
        case .fullAccess, .writeOnly:
            remindersPermission = .granted
        @unknown default:
            remindersPermission = .unknown
        }
    }

    func requestRemindersPermission() async -> Bool {
        let eventStore = EKEventStore()
        do {
            if #available(macOS 14.0, *) {
                let granted = try await eventStore.requestFullAccessToReminders()
                remindersPermission = granted ? .granted : .denied
                return granted
            } else {
                let granted: Bool = try await withCheckedThrowingContinuation { continuation in
                    eventStore.requestAccess(to: .reminder) { granted, error in
                        if let error {
                            continuation.resume(throwing: error)
                        } else {
                            continuation.resume(returning: granted)
                        }
                    }
                }
                remindersPermission = granted ? .granted : .denied
                return granted
            }
        } catch {
            remindersPermission = .denied
            return false
        }
    }

    // MARK: - Full Disk Access

    func checkFullDiskAccess() {
        // Check if we can read the Messages database (requires FDA)
        let messagesPath = NSHomeDirectory() + "/Library/Messages/chat.db"
        let safariHistoryPath = NSHomeDirectory() + "/Library/Safari/History.db"

        let canReadMessages = FileManager.default.isReadableFile(atPath: messagesPath)
        let canReadSafari = FileManager.default.isReadableFile(atPath: safariHistoryPath)

        if canReadMessages || canReadSafari {
            fullDiskAccessPermission = .granted
        } else {
            // Try to actually open one to be sure
            if let _ = try? FileHandle(forReadingFrom: URL(fileURLWithPath: messagesPath)) {
                fullDiskAccessPermission = .granted
            } else {
                fullDiskAccessPermission = .denied
            }
        }
    }

    func openFullDiskAccessSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
        NSWorkspace.shared.open(url)
    }

    // MARK: - Automation Permission

    func checkAutomationPermission() {
        // We can't directly check Automation permission - we have to try and see if it works
        // For now, assume not requested until we try
        automationPermission = .unknown
    }

    func requestAutomationPermission(for appBundleID: String) async -> Bool {
        // Try to execute a simple AppleScript to trigger the permission dialog
        let script: String
        switch appBundleID {
        case "com.apple.Safari":
            script = "tell application \"Safari\" to return name"
        case "com.apple.mail":
            script = "tell application \"Mail\" to return name"
        case "com.apple.Notes":
            script = "tell application \"Notes\" to return name"
        default:
            return false
        }

        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var error: NSDictionary?
                let appleScript = NSAppleScript(source: script)
                let _ = appleScript?.executeAndReturnError(&error)

                DispatchQueue.main.async {
                    if error == nil {
                        self.automationPermission = .granted
                        continuation.resume(returning: true)
                    } else {
                        // Error -1743 means user denied permission
                        let errorNumber = error?[NSAppleScript.errorNumber] as? Int
                        if errorNumber == -1743 {
                            self.automationPermission = .denied
                        }
                        continuation.resume(returning: false)
                    }
                }
            }
        }
    }

    func openAutomationSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!
        NSWorkspace.shared.open(url)
    }

    // MARK: - Notifications Permission

    func requestNotificationsPermission() async -> Bool {
        let center = UNUserNotificationCenter.current()
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
            notificationsPermission = granted ? .granted : .denied
            return granted
        } catch {
            notificationsPermission = .denied
            return false
        }
    }

    func checkNotificationsPermission() async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()

        switch settings.authorizationStatus {
        case .notDetermined:
            notificationsPermission = .notRequested
        case .denied:
            notificationsPermission = .denied
        case .authorized, .provisional, .ephemeral:
            notificationsPermission = .granted
        @unknown default:
            notificationsPermission = .unknown
        }
    }
}

// MARK: - Permission State

enum PermissionState: String {
    case unknown
    case notRequested
    case granted
    case denied

    var icon: String {
        switch self {
        case .unknown: return "questionmark.circle"
        case .notRequested: return "circle"
        case .granted: return "checkmark.circle.fill"
        case .denied: return "xmark.circle.fill"
        }
    }

    var color: NSColor {
        switch self {
        case .unknown: return .secondaryLabelColor
        case .notRequested: return .secondaryLabelColor
        case .granted: return .systemGreen
        case .denied: return .systemRed
        }
    }
}

import UserNotifications
