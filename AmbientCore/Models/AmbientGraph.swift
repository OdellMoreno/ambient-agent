import Foundation
import SwiftData

// MARK: - Ambient Graph
// Derived knowledge graph with entities and relationships
// Powers "show me everything relevant to X" queries

// MARK: - Entity Types

public enum EntityType: String, Codable, CaseIterable, Sendable {
    case person = "person"
    case organization = "organization"
    case location = "location"
    case project = "project"
    case thread = "thread"
    case topic = "topic"
    case event = "event"
    case task = "task"
}

// MARK: - Edge Types

public enum EdgeType: String, Codable, CaseIterable, Sendable {
    // Person relationships
    case knows = "knows"                    // Person ↔ Person
    case worksAt = "works_at"              // Person → Organization
    case attendedWith = "attended_with"    // Person ↔ Person (via event)

    // Thread/conversation
    case participatedIn = "participated_in" // Person → Thread
    case mentionedIn = "mentioned_in"       // Entity → Thread/Message

    // Event relationships
    case organizes = "organizes"           // Person → Event
    case attends = "attends"               // Person → Event
    case relatedTo = "related_to"          // Event ↔ Task

    // Task relationships
    case assignedTo = "assigned_to"        // Task → Person
    case assignedBy = "assigned_by"        // Task → Person
    case blockedBy = "blocked_by"          // Task → Task

    // Location relationships
    case locatedAt = "located_at"          // Event → Location
    case basedIn = "based_in"              // Person/Org → Location

    // Topic/Project relationships
    case taggedWith = "tagged_with"        // Any → Topic
    case partOf = "part_of"                // Task → Project
}

// MARK: - Entity Model

@Model
public final class Entity {
    @Attribute(.unique)
    public var id: UUID

    /// Entity type
    public var entityType: EntityType

    /// Canonical name/title
    public var name: String

    /// Alternative names/aliases (JSON array)
    public var aliasesData: Data?

    /// Entity-specific attributes (JSON)
    public var attributesData: Data?

    // Person-specific
    public var email: String?
    public var phone: String?

    // Organization-specific
    public var domain: String?

    // Location-specific
    public var address: String?
    public var coordinates: String? // "lat,lng"

    // Timestamps
    public var createdAt: Date
    public var updatedAt: Date

    /// First seen in raw item
    public var firstSeenAt: Date?

    /// Last seen in raw item
    public var lastSeenAt: Date?

    /// Outgoing edges from this entity
    @Relationship(deleteRule: .cascade, inverse: \Edge.fromEntity)
    public var outgoingEdges: [Edge]?

    /// Incoming edges to this entity
    @Relationship(deleteRule: .cascade, inverse: \Edge.toEntity)
    public var incomingEdges: [Edge]?

    // MARK: - Initialization

    public init(type: EntityType, name: String) {
        self.id = UUID()
        self.entityType = type
        self.name = name
        self.createdAt = Date()
        self.updatedAt = Date()
    }

    // MARK: - Convenience

    public var aliases: [String] {
        get {
            guard let data = aliasesData else { return [] }
            return (try? JSONDecoder().decode([String].self, from: data)) ?? []
        }
        set {
            aliasesData = try? JSONEncoder().encode(newValue)
        }
    }

    public var attributes: [String: String] {
        get {
            guard let data = attributesData else { return [:] }
            return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
        }
        set {
            attributesData = try? JSONEncoder().encode(newValue)
        }
    }

    /// Add an alias if not already present
    public func addAlias(_ alias: String) {
        var current = aliases
        if !current.contains(alias) && alias != name {
            current.append(alias)
            aliases = current
        }
    }
}

// MARK: - Edge Model

@Model
public final class Edge {
    @Attribute(.unique)
    public var id: UUID

    /// Edge type
    public var edgeType: EdgeType

    /// Source entity
    public var fromEntity: Entity?

    /// Target entity
    public var toEntity: Entity?

    /// Confidence score (0.0 - 1.0)
    public var confidence: Double

    /// Extraction version that created this edge
    public var extractionVersion: String

    // MARK: - Provenance

    /// Raw item IDs that support this edge (JSON array of composite keys)
    public var provenanceData: Data?

    /// When this edge was first created
    public var createdAt: Date

    /// When this edge was last updated
    public var updatedAt: Date

    /// Last time we saw evidence for this edge
    public var lastEvidenceAt: Date

    /// Number of raw items supporting this edge
    public var evidenceCount: Int

    // MARK: - Edge Attributes

    /// Additional edge-specific data (JSON)
    public var attributesData: Data?

    // MARK: - Initialization

    public init(
        type: EdgeType,
        from: Entity,
        to: Entity,
        confidence: Double,
        extractionVersion: String
    ) {
        self.id = UUID()
        self.edgeType = type
        self.fromEntity = from
        self.toEntity = to
        self.confidence = confidence
        self.extractionVersion = extractionVersion
        self.createdAt = Date()
        self.updatedAt = Date()
        self.lastEvidenceAt = Date()
        self.evidenceCount = 1
    }

    // MARK: - Convenience

    public var provenance: [String] {
        get {
            guard let data = provenanceData else { return [] }
            return (try? JSONDecoder().decode([String].self, from: data)) ?? []
        }
        set {
            provenanceData = try? JSONEncoder().encode(newValue)
        }
    }

    public var attributes: [String: String] {
        get {
            guard let data = attributesData else { return [:] }
            return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
        }
        set {
            attributesData = try? JSONEncoder().encode(newValue)
        }
    }

    /// Add provenance from a raw item
    public func addProvenance(rawItemKey: String) {
        var current = provenance
        if !current.contains(rawItemKey) {
            current.append(rawItemKey)
            provenance = current
            evidenceCount = current.count
            lastEvidenceAt = Date()
        }
    }
}

// MARK: - Sendable

extension Entity: @unchecked Sendable {}
extension Edge: @unchecked Sendable {}

// MARK: - Entity Resolution Helper

public struct EntityResolver {
    /// Find or create a Person entity by email
    public static func findOrCreatePerson(
        email: String?,
        name: String?,
        in context: ModelContext
    ) throws -> Entity? {
        let personType = EntityType.person

        guard let email = email?.lowercased(), !email.isEmpty else {
            guard let name = name, !name.isEmpty else { return nil }

            // Try to find by name
            let namePredicate = #Predicate<Entity> { entity in
                entity.entityType == personType && entity.name == name
            }
            let descriptor = FetchDescriptor<Entity>(predicate: namePredicate)
            if let existing = try context.fetch(descriptor).first {
                return existing
            }

            // Create new person without email
            let person = Entity(type: .person, name: name)
            context.insert(person)
            return person
        }

        // Try to find by email
        let emailPredicate = #Predicate<Entity> { entity in
            entity.entityType == personType && entity.email == email
        }
        let descriptor = FetchDescriptor<Entity>(predicate: emailPredicate)

        if let existing = try context.fetch(descriptor).first {
            // Update name if we have a better one
            if let name = name, !name.isEmpty, existing.name.contains("@") {
                existing.name = name
                existing.updatedAt = Date()
            }
            return existing
        }

        // Create new person
        let displayName = name ?? email
        let person = Entity(type: .person, name: displayName)
        person.email = email
        context.insert(person)

        return person
    }
}
