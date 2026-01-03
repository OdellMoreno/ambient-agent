import Foundation

/// XPC Protocol for communication between main app and background helper
@objc public protocol AmbientAgentProtocol {
    /// Start monitoring specified sources
    func startMonitoring(sources: [String], reply: @escaping (Bool, String?) -> Void)

    /// Stop all monitoring
    func stopMonitoring(reply: @escaping (Bool) -> Void)

    /// Force sync a specific source
    func forceSync(source: String, reply: @escaping (Bool, String?) -> Void)

    /// Get current monitoring status
    func getStatus(reply: @escaping ([String: String]) -> Void)

    /// Ping to check if helper is running
    func ping(reply: @escaping (Bool) -> Void)
}

/// Service name for XPC connection
public let AmbientAgentServiceName = "com.ambient.agent.helper"

// MARK: - Status Keys

public struct MonitorStatusKeys {
    public static let isRunning = "isRunning"
    public static let activeMonitors = "activeMonitors"
    public static let lastSyncDate = "lastSyncDate"
    public static let errorMessage = "errorMessage"
    public static let eventsToday = "eventsToday"
    public static let pendingTasks = "pendingTasks"
}

// MARK: - XPC Error

public enum AmbientAgentError: Error, LocalizedError {
    case connectionFailed
    case serviceUnavailable
    case permissionDenied(String)
    case syncFailed(String)
    case invalidSource(String)

    public var errorDescription: String? {
        switch self {
        case .connectionFailed:
            return "Failed to connect to background service"
        case .serviceUnavailable:
            return "Background service is not running"
        case .permissionDenied(let source):
            return "Permission denied for \(source)"
        case .syncFailed(let reason):
            return "Sync failed: \(reason)"
        case .invalidSource(let source):
            return "Invalid source: \(source)"
        }
    }
}
