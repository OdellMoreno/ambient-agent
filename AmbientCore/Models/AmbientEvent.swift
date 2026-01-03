import Foundation
import SwiftData

@Model
public final class AmbientEvent {
    // MARK: - Identity

    @Attribute(.unique)
    public var id: UUID

    /// Hash of source content for deduplication
    public var contentHash: String?

    // MARK: - Core Properties

    public var title: String
    public var eventDescription: String?
    public var startDate: Date
    public var endDate: Date?
    public var isAllDay: Bool

    // MARK: - Location

    public var location: String?
    public var locationAddress: String?
    public var virtualMeetingURL: String?
    public var virtualMeetingType: String? // zoom, meet, teams

    // MARK: - Attendees (stored as JSON)

    public var attendeesData: Data?

    // MARK: - Source Tracking (stored as raw values for SwiftData)

    public var sourceTypeRaw: String
    public var sourceIdentifier: String // calendar event ID, message ID, etc.
    public var sourceConversationID: String? // for grouping related messages

    public var sourceType: SourceType {
        get { SourceType(rawValue: sourceTypeRaw) ?? .calendar }
        set { sourceTypeRaw = newValue.rawValue }
    }

    // MARK: - Extraction Metadata

    public var confidenceRaw: String
    public var rawSnippet: String? // original text snippet
    public var extractedAt: Date

    public var confidence: ExtractionConfidence {
        get { ExtractionConfidence(rawValue: confidenceRaw) ?? .medium }
        set { confidenceRaw = newValue.rawValue }
    }

    // MARK: - Timestamps

    public var createdAt: Date
    public var updatedAt: Date

    // MARK: - Relationships

    @Relationship(deleteRule: .nullify, inverse: \AmbientTask.relatedEvent)
    public var relatedTasks: [AmbientTask]?

    /// Canonical event if this is a duplicate
    @Relationship(deleteRule: .nullify)
    public var canonicalEvent: AmbientEvent?

    /// Duplicate events pointing to this as canonical
    @Relationship(deleteRule: .nullify, inverse: \AmbientEvent.canonicalEvent)
    public var duplicateEvents: [AmbientEvent]?

    // MARK: - Initialization

    public init(
        title: String,
        startDate: Date,
        sourceType: SourceType,
        sourceIdentifier: String,
        confidence: ExtractionConfidence = .high
    ) {
        self.id = UUID()
        self.title = title
        self.startDate = startDate
        self.isAllDay = false
        self.sourceTypeRaw = sourceType.rawValue
        self.sourceIdentifier = sourceIdentifier
        self.confidenceRaw = confidence.rawValue
        self.extractedAt = Date()
        self.createdAt = Date()
        self.updatedAt = Date()
    }

    // MARK: - Attendees

    public struct Attendee: Codable, Hashable, Sendable {
        public var name: String?
        public var email: String?
        public var phone: String?
        public var isOrganizer: Bool

        public init(name: String? = nil, email: String? = nil, phone: String? = nil, isOrganizer: Bool = false) {
            self.name = name
            self.email = email
            self.phone = phone
            self.isOrganizer = isOrganizer
        }
    }

    public var attendees: [Attendee] {
        get {
            guard let data = attendeesData else { return [] }
            return (try? JSONDecoder().decode([Attendee].self, from: data)) ?? []
        }
        set {
            attendeesData = try? JSONEncoder().encode(newValue)
        }
    }

    // MARK: - Computed Properties

    public var isUpcoming: Bool {
        startDate > Date()
    }

    public var isToday: Bool {
        Calendar.current.isDateInToday(startDate)
    }

    public var duration: TimeInterval? {
        guard let endDate else { return nil }
        return endDate.timeIntervalSince(startDate)
    }

    public var hasVirtualMeeting: Bool {
        virtualMeetingURL != nil
    }
}

// MARK: - Sendable

extension AmbientEvent: @unchecked Sendable {}
