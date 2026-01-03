import Foundation
import SwiftData
import AmbientCore

/// XPC Service implementation for the background helper
final class AgentService: NSObject, AmbientAgentProtocol {
    static let shared = AgentService()

    private var modelContainer: ModelContainer?
    private var monitorCoordinator: MonitorCoordinator?
    private var pipelineCoordinator: PipelineCoordinator?
    private var isRunning = false

    override init() {
        super.init()
        setupDatabase()
    }

    private func setupDatabase() {
        modelContainer = DatabaseManager.createForHelper()
        AmbientLogger.database.info("Database initialized for helper")
    }

    // MARK: - AmbientAgentProtocol

    func startMonitoring(sources: [String], reply: @escaping (Bool, String?) -> Void) {
        AmbientLogger.monitors.info("Starting monitoring for sources: \(sources)")

        guard let container = modelContainer else {
            reply(false, "Database not initialized")
            return
        }

        let sourceTypes = sources.compactMap { SourceType(rawValue: $0) }

        if sourceTypes.isEmpty {
            reply(false, "No valid sources specified")
            return
        }

        // Initialize monitor coordinator if needed
        if monitorCoordinator == nil {
            monitorCoordinator = MonitorCoordinator(modelContainer: container)
        }

        // Initialize pipeline coordinator
        if pipelineCoordinator == nil {
            pipelineCoordinator = PipelineCoordinator(modelContainer: container)
        }

        Task {
            do {
                try await monitorCoordinator?.startMonitoring(sources: sourceTypes)

                // Start the pipeline if messages are being monitored
                if sourceTypes.contains(.messages) {
                    await pipelineCoordinator?.start()
                    AmbientLogger.extraction.info("Pipeline started for message analysis")
                }

                isRunning = true
                reply(true, nil)
            } catch {
                AmbientLogger.monitors.error("Failed to start monitoring: \(error.localizedDescription)")
                reply(false, error.localizedDescription)
            }
        }
    }

    func stopMonitoring(reply: @escaping (Bool) -> Void) {
        AmbientLogger.monitors.info("Stopping monitoring")

        Task {
            await monitorCoordinator?.stopMonitoring()
            await pipelineCoordinator?.stop()
            isRunning = false
            reply(true)
        }
    }

    func forceSync(source: String, reply: @escaping (Bool, String?) -> Void) {
        guard let sourceType = SourceType(rawValue: source) else {
            reply(false, "Invalid source: \(source)")
            return
        }

        AmbientLogger.monitors.info("Force syncing: \(source)")

        Task {
            do {
                try await monitorCoordinator?.forceSync(source: sourceType)
                reply(true, nil)
            } catch {
                reply(false, error.localizedDescription)
            }
        }
    }

    func getStatus(reply: @escaping ([String: String]) -> Void) {
        Task {
            var status: [String: String] = [
                MonitorStatusKeys.isRunning: String(isRunning)
            ]

            if let coordinator = monitorCoordinator {
                let activeMonitors = await coordinator.activeMonitors.map(\.rawValue).joined(separator: ",")
                status[MonitorStatusKeys.activeMonitors] = activeMonitors

                if let lastSync = await coordinator.lastSyncDate {
                    status[MonitorStatusKeys.lastSyncDate] = ISO8601DateFormatter().string(from: lastSync)
                }
            }

            // Get counts from database
            if let container = modelContainer {
                let context = ModelContext(container)

                // Count today's events
                let calendar = Calendar.current
                let startOfDay = calendar.startOfDay(for: Date())
                let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay)!

                let eventPredicate = #Predicate<AmbientEvent> { event in
                    event.startDate >= startOfDay && event.startDate < endOfDay
                }

                if let count = try? context.fetchCount(FetchDescriptor<AmbientEvent>(predicate: eventPredicate)) {
                    status[MonitorStatusKeys.eventsToday] = String(count)
                }

                // Count pending tasks
                let pendingStatus = TaskStatus.pending
                let inProgressStatus = TaskStatus.inProgress
                let taskPredicate = #Predicate<AmbientTask> { task in
                    task.status == pendingStatus || task.status == inProgressStatus
                }

                if let count = try? context.fetchCount(FetchDescriptor<AmbientTask>(predicate: taskPredicate)) {
                    status[MonitorStatusKeys.pendingTasks] = String(count)
                }
            }

            reply(status)
        }
    }

    func ping(reply: @escaping (Bool) -> Void) {
        reply(true)
    }
}
