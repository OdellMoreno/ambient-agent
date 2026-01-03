import Foundation
import SwiftData

@Model
public final class ActivityLog {
    @Attribute(.unique)
    public var id: UUID

    public var timestamp: Date
    public var activityType: ActivityType
    public var message: String
    public var sourceType: SourceType?

    /// Additional metadata as JSON
    public var metadataData: Data?

    public init(
        type: ActivityType,
        message: String,
        sourceType: SourceType? = nil
    ) {
        self.id = UUID()
        self.timestamp = Date()
        self.activityType = type
        self.message = message
        self.sourceType = sourceType
    }

    // MARK: - Metadata

    public var metadata: [String: String] {
        get {
            guard let data = metadataData else { return [:] }
            return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
        }
        set {
            metadataData = try? JSONEncoder().encode(newValue)
        }
    }
}

extension ActivityLog: @unchecked Sendable {}
