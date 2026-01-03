import Foundation
import EventKit
import SwiftData
import AmbientCore

/// Monitors Apple Calendar and Reminders using EventKit
actor CalendarMonitor: DataSourceMonitor {
    let sourceType: SourceType = .calendar
    private(set) var isMonitoring = false

    private let eventStore = EKEventStore()
    private let context: ModelContext
    private let includeReminders: Bool

    private var notificationTask: Task<Void, Never>?

    init(context: ModelContext, includeReminders: Bool = false) {
        self.context = context
        self.includeReminders = includeReminders
    }

    // MARK: - DataSourceMonitor

    func startMonitoring() async throws {
        AmbientLogger.monitors.info("Starting Calendar monitor")

        // Request access
        let granted = try await requestAccess()
        guard granted else {
            throw AmbientAgentError.permissionDenied("Calendar")
        }

        isMonitoring = true

        // Subscribe to calendar changes
        notificationTask = Task { [weak self] in
            let notifications = NotificationCenter.default.notifications(
                named: .EKEventStoreChanged
            )

            for await _ in notifications {
                guard let self else { break }
                AmbientLogger.monitors.debug("Calendar changed, syncing...")
                try? await self.forceSync()
            }
        }

        // Initial sync
        try await forceSync()
    }

    func stopMonitoring() async {
        AmbientLogger.monitors.info("Stopping Calendar monitor")
        isMonitoring = false
        notificationTask?.cancel()
        notificationTask = nil
    }

    func forceSync() async throws {
        AmbientLogger.monitors.info("Syncing calendar events")

        // Fetch events for the next 30 days
        let startDate = Date()
        let endDate = Calendar.current.date(byAdding: .day, value: 30, to: startDate)!

        let predicate = eventStore.predicateForEvents(
            withStart: startDate,
            end: endDate,
            calendars: nil
        )

        let ekEvents = eventStore.events(matching: predicate)
        AmbientLogger.monitors.info("Found \(ekEvents.count) calendar events")

        for ekEvent in ekEvents {
            try await upsertEvent(from: ekEvent)
        }

        try context.save()

        // Also sync reminders if enabled
        if includeReminders {
            try await syncReminders()
        }

        logActivity(type: .syncCompleted, message: "Synced \(ekEvents.count) calendar events")
    }

    // MARK: - Private

    private func requestAccess() async throws -> Bool {
        if #available(macOS 14.0, *) {
            return try await eventStore.requestFullAccessToEvents()
        } else {
            return try await withCheckedThrowingContinuation { continuation in
                eventStore.requestAccess(to: .event) { granted, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(returning: granted)
                    }
                }
            }
        }
    }

    private func upsertEvent(from ekEvent: EKEvent) async throws {
        let sourceIdentifier = ekEvent.eventIdentifier ?? UUID().uuidString
        let calendarTypeRaw = SourceType.calendar.rawValue

        // Check if event already exists
        let predicate = #Predicate<AmbientEvent> { event in
            event.sourceTypeRaw == calendarTypeRaw && event.sourceIdentifier == sourceIdentifier
        }

        let descriptor = FetchDescriptor<AmbientEvent>(predicate: predicate)
        let existing = try context.fetch(descriptor).first

        if let existing {
            // Update existing event
            existing.title = ekEvent.title ?? "Untitled Event"
            existing.startDate = ekEvent.startDate
            existing.endDate = ekEvent.endDate
            existing.isAllDay = ekEvent.isAllDay
            existing.location = ekEvent.location
            existing.eventDescription = ekEvent.notes
            existing.updatedAt = Date()

            // Update attendees
            if let attendees = ekEvent.attendees {
                existing.attendees = attendees.map { participant in
                    AmbientEvent.Attendee(
                        name: participant.name,
                        email: participant.url.absoluteString.replacingOccurrences(of: "mailto:", with: ""),
                        isOrganizer: participant.isCurrentUser && ekEvent.organizer == participant
                    )
                }
            }

            // Check for virtual meeting URL
            if let url = ekEvent.url {
                existing.virtualMeetingURL = url.absoluteString
                existing.virtualMeetingType = detectMeetingType(from: url)
            }

        } else {
            // Create new event
            let event = AmbientEvent(
                title: ekEvent.title ?? "Untitled Event",
                startDate: ekEvent.startDate,
                sourceType: .calendar,
                sourceIdentifier: sourceIdentifier,
                confidence: .high
            )

            event.endDate = ekEvent.endDate
            event.isAllDay = ekEvent.isAllDay
            event.location = ekEvent.location
            event.eventDescription = ekEvent.notes

            // Add attendees
            if let attendees = ekEvent.attendees {
                event.attendees = attendees.map { participant in
                    AmbientEvent.Attendee(
                        name: participant.name,
                        email: participant.url.absoluteString.replacingOccurrences(of: "mailto:", with: ""),
                        isOrganizer: participant.isCurrentUser && ekEvent.organizer == participant
                    )
                }
            }

            // Check for virtual meeting URL
            if let url = ekEvent.url {
                event.virtualMeetingURL = url.absoluteString
                event.virtualMeetingType = detectMeetingType(from: url)
            }

            context.insert(event)
        }
    }

    private func syncReminders() async throws {
        let granted: Bool
        if #available(macOS 14.0, *) {
            granted = try await eventStore.requestFullAccessToReminders()
        } else {
            granted = try await withCheckedThrowingContinuation { continuation in
                eventStore.requestAccess(to: .reminder) { granted, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(returning: granted)
                    }
                }
            }
        }

        guard granted else { return }

        // Fetch incomplete reminders
        let predicate = eventStore.predicateForIncompleteReminders(
            withDueDateStarting: nil,
            ending: nil,
            calendars: nil
        )

        let reminders = await withCheckedContinuation { continuation in
            eventStore.fetchReminders(matching: predicate) { reminders in
                continuation.resume(returning: reminders ?? [])
            }
        }

        AmbientLogger.monitors.info("Found \(reminders.count) reminders")

        for reminder in reminders {
            try await upsertTask(from: reminder)
        }

        try context.save()
    }

    private func upsertTask(from reminder: EKReminder) async throws {
        let sourceIdentifier = reminder.calendarItemIdentifier
        let remindersTypeRaw = SourceType.reminders.rawValue

        let predicate = #Predicate<AmbientTask> { task in
            task.sourceTypeRaw == remindersTypeRaw && task.sourceIdentifier == sourceIdentifier
        }

        let descriptor = FetchDescriptor<AmbientTask>(predicate: predicate)
        let existing = try context.fetch(descriptor).first

        if let existing {
            existing.title = reminder.title ?? "Untitled Reminder"
            existing.dueDate = reminder.dueDateComponents?.date
            existing.priority = mapPriority(from: reminder.priority)
            existing.status = reminder.isCompleted ? .completed : .pending
            existing.updatedAt = Date()
            if reminder.isCompleted {
                existing.completedAt = reminder.completionDate
            }
        } else {
            let task = AmbientTask(
                title: reminder.title ?? "Untitled Reminder",
                sourceType: .reminders,
                sourceIdentifier: sourceIdentifier,
                confidence: .high
            )

            task.dueDate = reminder.dueDateComponents?.date
            task.priority = mapPriority(from: reminder.priority)
            task.status = reminder.isCompleted ? .completed : .pending
            task.taskDescription = reminder.notes

            context.insert(task)
        }
    }

    private func mapPriority(from ekPriority: Int) -> TaskPriority {
        switch ekPriority {
        case 1...3: return .high
        case 4...6: return .medium
        case 7...9: return .low
        default: return .none
        }
    }

    private func detectMeetingType(from url: URL) -> String? {
        let host = url.host?.lowercased() ?? ""

        if host.contains("zoom") {
            return "zoom"
        } else if host.contains("meet.google") {
            return "google_meet"
        } else if host.contains("teams.microsoft") {
            return "teams"
        } else if host.contains("webex") {
            return "webex"
        }

        return nil
    }

    private func logActivity(type: ActivityType, message: String) {
        let log = ActivityLog(type: type, message: message, sourceType: .calendar)
        context.insert(log)
        try? context.save()
    }
}
