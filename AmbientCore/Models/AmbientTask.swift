import Foundation
import SwiftData

@Model
public final class AmbientTask {
    // MARK: - Identity

    @Attribute(.unique)
    public var id: UUID

    /// Hash of source content for deduplication
    public var contentHash: String?

    // MARK: - Core Properties

    public var title: String
    public var taskDescription: String?
    public var dueDate: Date?

    // Store enums as raw values for SwiftData compatibility
    public var priorityRaw: Int
    public var statusRaw: String

    public var priority: TaskPriority {
        get { TaskPriority(rawValue: priorityRaw) ?? .medium }
        set { priorityRaw = newValue.rawValue }
    }

    public var status: TaskStatus {
        get { TaskStatus(rawValue: statusRaw) ?? .pending }
        set { statusRaw = newValue.rawValue }
    }

    // MARK: - Assignment

    public var assigneeName: String?
    public var assigneeEmail: String?
    public var assignerName: String?
    public var assignerEmail: String?

    // MARK: - Context

    public var context: String? // why this task exists
    public var tagsData: Data?

    public var tags: [String]? {
        get {
            guard let data = tagsData else { return nil }
            return try? JSONDecoder().decode([String].self, from: data)
        }
        set {
            tagsData = try? JSONEncoder().encode(newValue)
        }
    }

    // MARK: - Source Tracking

    public var sourceTypeRaw: String
    public var sourceIdentifier: String
    public var sourceConversationID: String?

    public var sourceType: SourceType {
        get { SourceType(rawValue: sourceTypeRaw) ?? .calendar }
        set { sourceTypeRaw = newValue.rawValue }
    }

    // MARK: - Extraction Metadata

    public var confidenceRaw: String
    public var rawSnippet: String?
    public var extractedAt: Date

    public var confidence: ExtractionConfidence {
        get { ExtractionConfidence(rawValue: confidenceRaw) ?? .medium }
        set { confidenceRaw = newValue.rawValue }
    }

    // MARK: - Timestamps

    public var createdAt: Date
    public var updatedAt: Date
    public var completedAt: Date?

    // MARK: - Relationships

    public var relatedEvent: AmbientEvent?

    @Relationship(deleteRule: .cascade, inverse: \AmbientTask.parentTask)
    public var subtasks: [AmbientTask]?

    public var parentTask: AmbientTask?

    /// Canonical task if this is a duplicate
    @Relationship(deleteRule: .nullify)
    public var canonicalTask: AmbientTask?

    /// Duplicate tasks pointing to this as canonical
    @Relationship(deleteRule: .nullify, inverse: \AmbientTask.canonicalTask)
    public var duplicateTasks: [AmbientTask]?

    // MARK: - Initialization

    public init(
        title: String,
        sourceType: SourceType,
        sourceIdentifier: String,
        confidence: ExtractionConfidence = .high
    ) {
        self.id = UUID()
        self.title = title
        self.priorityRaw = TaskPriority.medium.rawValue
        self.statusRaw = TaskStatus.pending.rawValue
        self.sourceTypeRaw = sourceType.rawValue
        self.sourceIdentifier = sourceIdentifier
        self.confidenceRaw = confidence.rawValue
        self.extractedAt = Date()
        self.createdAt = Date()
        self.updatedAt = Date()
    }

    // MARK: - Computed Properties

    public var isOverdue: Bool {
        guard let dueDate, status != .completed && status != .cancelled else {
            return false
        }
        return dueDate < Date()
    }

    public var isDueToday: Bool {
        guard let dueDate else { return false }
        return Calendar.current.isDateInToday(dueDate)
    }

    public var isDueSoon: Bool {
        guard let dueDate else { return false }
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Date())!
        return dueDate <= tomorrow
    }

    public var isCompleted: Bool {
        status == .completed
    }

    // MARK: - Actions

    public func markCompleted() {
        status = .completed
        completedAt = Date()
        updatedAt = Date()
    }

    public func markInProgress() {
        status = .inProgress
        updatedAt = Date()
    }
}

// MARK: - Sendable

extension AmbientTask: @unchecked Sendable {}
