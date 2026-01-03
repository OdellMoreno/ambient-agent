import Foundation
import SwiftData
import AmbientCore

/// Coordinates all data source monitors
actor MonitorCoordinator {
    private let modelContainer: ModelContainer
    private var monitors: [SourceType: any DataSourceMonitor] = [:]

    private(set) var activeMonitors: [SourceType] = []
    private(set) var lastSyncDate: Date?

    init(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
    }

    // MARK: - Public API

    func startMonitoring(sources: [SourceType]) async throws {
        AmbientLogger.monitors.info("Starting monitors for: \(sources.map(\.rawValue))")

        for source in sources {
            let monitor = try await getOrCreateMonitor(for: source)
            try await monitor.startMonitoring()
            activeMonitors.append(source)
        }

        // Perform initial sync
        try await syncAll()
    }

    func stopMonitoring() async {
        AmbientLogger.monitors.info("Stopping all monitors")

        for source in activeMonitors {
            if let monitor = monitors[source] {
                await monitor.stopMonitoring()
            }
        }

        activeMonitors.removeAll()
    }

    func forceSync(source: SourceType) async throws {
        guard let monitor = monitors[source] else {
            throw AmbientAgentError.invalidSource(source.rawValue)
        }

        try await monitor.forceSync()
        lastSyncDate = Date()
    }

    func syncAll() async throws {
        for source in activeMonitors {
            if let monitor = monitors[source] {
                try await monitor.forceSync()
            }
        }
        lastSyncDate = Date()
    }

    // MARK: - Private

    private func getOrCreateMonitor(for source: SourceType) async throws -> any DataSourceMonitor {
        if let existing = monitors[source] {
            return existing
        }

        let context = ModelContext(modelContainer)
        let monitor: any DataSourceMonitor

        switch source {
        case .calendar, .reminders:
            monitor = CalendarMonitor(context: context, includeReminders: source == .reminders)
        case .messages:
            monitor = iMessageMonitor(context: context)
        case .safari:
            monitor = SafariMonitor(context: context)
        case .email:
            monitor = MailMonitor(context: context)
        case .notes:
            monitor = NotesMonitor(context: context)
        case .gmail:
            // Gmail requires separate OAuth setup
            throw AmbientAgentError.permissionDenied("Gmail requires OAuth setup")
        }

        monitors[source] = monitor
        return monitor
    }
}

// MARK: - Data Source Monitor Protocol

public protocol DataSourceMonitor: Actor {
    var sourceType: SourceType { get }
    var isMonitoring: Bool { get }

    func startMonitoring() async throws
    func stopMonitoring() async
    func forceSync() async throws
}
