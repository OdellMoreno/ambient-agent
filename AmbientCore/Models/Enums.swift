import Foundation

// MARK: - Source Types

public enum SourceType: String, Codable, CaseIterable, Sendable {
    case calendar = "calendar"
    case reminders = "reminders"
    case messages = "messages"
    case email = "email"
    case gmail = "gmail"
    case safari = "safari"
    case notes = "notes"

    public var displayName: String {
        switch self {
        case .calendar: return "Calendar"
        case .reminders: return "Reminders"
        case .messages: return "Messages"
        case .email: return "Apple Mail"
        case .gmail: return "Gmail"
        case .safari: return "Safari"
        case .notes: return "Notes"
        }
    }

    public var iconName: String {
        switch self {
        case .calendar: return "calendar"
        case .reminders: return "checklist"
        case .messages: return "message.fill"
        case .email, .gmail: return "envelope.fill"
        case .safari: return "safari.fill"
        case .notes: return "note.text"
        }
    }
}

// MARK: - Task Priority

public enum TaskPriority: Int, Codable, Comparable, CaseIterable, Sendable {
    case none = 0
    case low = 1
    case medium = 2
    case high = 3
    case urgent = 4

    public static func < (lhs: TaskPriority, rhs: TaskPriority) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public var displayName: String {
        switch self {
        case .none: return "None"
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High"
        case .urgent: return "Urgent"
        }
    }

    public var color: String {
        switch self {
        case .none: return "gray"
        case .low: return "blue"
        case .medium: return "yellow"
        case .high: return "orange"
        case .urgent: return "red"
        }
    }
}

// MARK: - Task Status

public enum TaskStatus: String, Codable, CaseIterable, Sendable {
    case pending = "pending"
    case inProgress = "in_progress"
    case completed = "completed"
    case cancelled = "cancelled"
    case deferred = "deferred"

    public var displayName: String {
        switch self {
        case .pending: return "Pending"
        case .inProgress: return "In Progress"
        case .completed: return "Completed"
        case .cancelled: return "Cancelled"
        case .deferred: return "Deferred"
        }
    }
}

// MARK: - Extraction Confidence

public enum ExtractionConfidence: String, Codable, Sendable {
    case high = "high"
    case medium = "medium"
    case low = "low"

    public var threshold: Double {
        switch self {
        case .high: return 0.9
        case .medium: return 0.7
        case .low: return 0.5
        }
    }
}

// MARK: - Activity Types

public enum ActivityType: String, Codable, Sendable {
    case syncStarted = "sync_started"
    case syncCompleted = "sync_completed"
    case syncFailed = "sync_failed"
    case eventExtracted = "event_extracted"
    case taskExtracted = "task_extracted"
    case eventUpdated = "event_updated"
    case taskCompleted = "task_completed"
    case error = "error"

    public var iconName: String {
        switch self {
        case .syncStarted: return "arrow.triangle.2.circlepath"
        case .syncCompleted: return "checkmark.circle.fill"
        case .syncFailed: return "exclamationmark.triangle.fill"
        case .eventExtracted: return "calendar.badge.plus"
        case .taskExtracted: return "plus.circle.fill"
        case .eventUpdated: return "pencil.circle.fill"
        case .taskCompleted: return "checkmark.circle.fill"
        case .error: return "xmark.circle.fill"
        }
    }
}

// MARK: - Monitor Status

public enum MonitorStatus: String, Codable, Sendable {
    case idle = "idle"
    case monitoring = "monitoring"
    case syncing = "syncing"
    case error = "error"
    case permissionDenied = "permission_denied"
}
