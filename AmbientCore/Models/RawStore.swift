import Foundation
import SwiftData

// MARK: - Raw Store
// Append-only storage of raw items with full provenance
// This is the ground truth for reprocessing

/// Raw item from any data source - stored exactly as received
@Model
public final class RawItem {
    // MARK: - Identity

    /// Composite key: (sourceType, stableID)
    @Attribute(.unique)
    public var compositeKey: String

    /// Source type (calendar, messages, email, etc.)
    public var sourceType: SourceType

    /// Stable identifier from the source (message GUID, calendar event ID, etc.)
    public var stableID: String

    // MARK: - Content

    /// Raw content blob (JSON, text, or encrypted data)
    public var contentData: Data

    /// Content type hint
    public var contentType: RawContentType

    /// Whether content is encrypted
    public var isEncrypted: Bool

    // MARK: - Metadata

    /// When this item was created in the source
    public var sourceTimestamp: Date

    /// When we fetched this item
    public var fetchedAt: Date

    /// Participants (sender, recipients, attendees - as JSON array)
    public var participantsData: Data?

    /// Subject/title from source
    public var subject: String?

    /// Thread/conversation identifier
    public var threadID: String?

    /// Folder/container in source
    public var folder: String?

    /// Additional source-specific metadata as JSON
    public var metadataData: Data?

    // MARK: - Cursor State

    /// Source cursor at time of fetch (for incremental sync)
    public var cursorValue: String?

    // MARK: - Processing State

    /// Current extraction version applied (nil = never extracted)
    public var extractionVersion: String?

    /// Last extraction timestamp
    public var lastExtractedAt: Date?

    /// Extraction error if any
    public var extractionError: String?

    // MARK: - Initialization

    public init(
        sourceType: SourceType,
        stableID: String,
        content: Data,
        contentType: RawContentType,
        sourceTimestamp: Date
    ) {
        self.compositeKey = "\(sourceType.rawValue):\(stableID)"
        self.sourceType = sourceType
        self.stableID = stableID
        self.contentData = content
        self.contentType = contentType
        self.isEncrypted = false
        self.sourceTimestamp = sourceTimestamp
        self.fetchedAt = Date()
    }

    /// Convenience initializer used by monitors (uses current time as sourceTimestamp)
    public init(
        sourceType: SourceType,
        stableID: String,
        contentData: Data,
        contentType: RawContentType
    ) {
        self.compositeKey = "\(sourceType.rawValue):\(stableID)"
        self.sourceType = sourceType
        self.stableID = stableID
        self.contentData = contentData
        self.contentType = contentType
        self.isEncrypted = false
        self.sourceTimestamp = Date()
        self.fetchedAt = Date()
    }

    // MARK: - Convenience

    public var content: String? {
        get {
            return String(data: contentData, encoding: .utf8)
        }
        set {
            if let newValue = newValue {
                contentData = Data(newValue.utf8)
            }
        }
    }

    public var participants: [String] {
        get {
            guard let data = participantsData else { return [] }
            return (try? JSONDecoder().decode([String].self, from: data)) ?? []
        }
        set {
            participantsData = try? JSONEncoder().encode(newValue)
        }
    }

    public var metadata: [String: String] {
        get {
            guard let data = metadataData else { return [:] }
            return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
        }
        set {
            metadataData = try? JSONEncoder().encode(newValue)
        }
    }

    /// Check if this item needs (re)extraction
    public func needsExtraction(currentVersion: String) -> Bool {
        guard extractionError == nil else { return true } // Retry errors
        guard let version = extractionVersion else { return true } // Never extracted
        return version != currentVersion // Version mismatch
    }
}

// MARK: - Content Type

public enum RawContentType: String, Codable, Sendable {
    case text = "text"
    case json = "json"
    case html = "html"
    case binary = "binary"
    case ics = "ics"      // Calendar data
    case eml = "eml"      // Email format
    case email = "email"  // Email content
    case webPage = "webpage"
    case note = "note"
    case message = "message"
}

// MARK: - Cursor State (for incremental sync)

@Model
public final class SyncCursor {
    @Attribute(.unique)
    public var sourceTypeRaw: String

    public var sourceType: SourceType {
        get { SourceType(rawValue: sourceTypeRaw) ?? .calendar }
        set { sourceTypeRaw = newValue.rawValue }
    }

    /// Last processed row ID (for SQLite-based sources)
    public var lastRowID: Int64?

    /// Last modified timestamp
    public var lastModified: Date?

    /// Source-specific cursor (e.g., Gmail historyId)
    public var cursorValue: String?

    /// Last successful sync
    public var lastSyncAt: Date

    /// Sync error if any
    public var lastError: String?

    public init(sourceType: SourceType) {
        self.sourceTypeRaw = sourceType.rawValue
        self.lastSyncAt = Date()
    }
}

extension RawItem: @unchecked Sendable {}
extension SyncCursor: @unchecked Sendable {}
