import Foundation
import SwiftData

/// Manages the shared SwiftData container accessible by both the main app and helper
@MainActor
public final class DatabaseManager {
    public static let shared = DatabaseManager()

    /// App Group identifier for shared container
    public static let appGroupIdentifier = "group.com.ambient.agent"

    public let container: ModelContainer

    private init() {
        let schema = Schema([
            // Raw Store
            RawItem.self,
            SyncCursor.self,
            // Unified Store
            AmbientEvent.self,
            AmbientTask.self,
            ActivityLog.self,
            // Ambient Graph
            Entity.self,
            Edge.self
        ])

        let configuration = ModelConfiguration(
            "AmbientAgent",
            schema: schema,
            isStoredInMemoryOnly: false,
            allowsSave: true,
            groupContainer: .identifier(Self.appGroupIdentifier)
        )

        do {
            container = try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            fatalError("Failed to create ModelContainer: \(error)")
        }
    }

    public var mainContext: ModelContext {
        container.mainContext
    }

    /// Create a new background context for async operations
    public func newBackgroundContext() -> ModelContext {
        ModelContext(container)
    }
}

// MARK: - Query Helpers

public extension DatabaseManager {
    /// Fetch today's events
    func fetchTodayEvents() throws -> [AmbientEvent] {
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: Date())
        let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay)!

        let predicate = #Predicate<AmbientEvent> { event in
            event.startDate >= startOfDay && event.startDate < endOfDay
        }

        let descriptor = FetchDescriptor<AmbientEvent>(
            predicate: predicate,
            sortBy: [SortDescriptor(\.startDate)]
        )

        return try mainContext.fetch(descriptor)
    }

    /// Fetch upcoming events
    func fetchUpcomingEvents(days: Int = 7) throws -> [AmbientEvent] {
        let now = Date()
        let endDate = Calendar.current.date(byAdding: .day, value: days, to: now)!

        let predicate = #Predicate<AmbientEvent> { event in
            event.startDate >= now && event.startDate <= endDate
        }

        let descriptor = FetchDescriptor<AmbientEvent>(
            predicate: predicate,
            sortBy: [SortDescriptor(\.startDate)]
        )

        return try mainContext.fetch(descriptor)
    }

    /// Fetch pending tasks
    func fetchPendingTasks() throws -> [AmbientTask] {
        let pendingStatus = TaskStatus.pending
        let inProgressStatus = TaskStatus.inProgress
        let predicate = #Predicate<AmbientTask> { task in
            task.status == pendingStatus || task.status == inProgressStatus
        }

        let descriptor = FetchDescriptor<AmbientTask>(
            predicate: predicate,
            sortBy: [
                SortDescriptor(\.priorityRaw, order: .reverse),
                SortDescriptor(\.dueDate)
            ]
        )

        return try mainContext.fetch(descriptor)
    }

    /// Fetch recent activity
    func fetchRecentActivity(limit: Int = 50) throws -> [ActivityLog] {
        var descriptor = FetchDescriptor<ActivityLog>(
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )
        descriptor.fetchLimit = limit

        return try mainContext.fetch(descriptor)
    }

    /// Find existing event by source identifier
    func findEvent(sourceType: SourceType, sourceIdentifier: String) throws -> AmbientEvent? {
        let sourceTypeRaw = sourceType.rawValue
        let predicate = #Predicate<AmbientEvent> { event in
            event.sourceTypeRaw == sourceTypeRaw && event.sourceIdentifier == sourceIdentifier
        }

        let descriptor = FetchDescriptor<AmbientEvent>(predicate: predicate)
        return try mainContext.fetch(descriptor).first
    }

    /// Find existing task by source identifier
    func findTask(sourceType: SourceType, sourceIdentifier: String) throws -> AmbientTask? {
        let sourceTypeRaw = sourceType.rawValue
        let predicate = #Predicate<AmbientTask> { task in
            task.sourceTypeRaw == sourceTypeRaw && task.sourceIdentifier == sourceIdentifier
        }

        let descriptor = FetchDescriptor<AmbientTask>(predicate: predicate)
        return try mainContext.fetch(descriptor).first
    }

    /// Log an activity
    func logActivity(
        type: ActivityType,
        message: String,
        sourceType: SourceType? = nil,
        metadata: [String: String]? = nil
    ) {
        let log = ActivityLog(type: type, message: message, sourceType: sourceType)
        if let metadata {
            log.metadata = metadata
        }
        mainContext.insert(log)
        try? mainContext.save()
    }
}

// MARK: - Raw Store Queries

public extension DatabaseManager {
    /// Find or create a raw item
    func upsertRawItem(
        sourceType: SourceType,
        stableID: String,
        content: Data,
        contentType: RawContentType,
        sourceTimestamp: Date,
        metadata: [String: String]? = nil
    ) throws -> RawItem {
        let compositeKey = "\(sourceType.rawValue):\(stableID)"

        let predicate = #Predicate<RawItem> { item in
            item.compositeKey == compositeKey
        }
        let descriptor = FetchDescriptor<RawItem>(predicate: predicate)

        if let existing = try mainContext.fetch(descriptor).first {
            // Update content if changed
            existing.contentData = content
            if let metadata {
                existing.metadata = metadata
            }
            return existing
        }

        let item = RawItem(
            sourceType: sourceType,
            stableID: stableID,
            content: content,
            contentType: contentType,
            sourceTimestamp: sourceTimestamp
        )
        if let metadata {
            item.metadata = metadata
        }
        mainContext.insert(item)
        return item
    }

    /// Get items needing extraction
    func fetchItemsNeedingExtraction(
        extractionVersion: String,
        limit: Int = 100
    ) throws -> [RawItem] {
        // Fetch items that haven't been extracted or have old version
        let predicate = #Predicate<RawItem> { item in
            item.extractionVersion == nil || item.extractionVersion != extractionVersion
        }

        var descriptor = FetchDescriptor<RawItem>(
            predicate: predicate,
            sortBy: [SortDescriptor(\.fetchedAt, order: .reverse)]
        )
        descriptor.fetchLimit = limit

        return try mainContext.fetch(descriptor)
    }

    /// Get or update sync cursor
    func getSyncCursor(for sourceType: SourceType) throws -> SyncCursor {
        let sourceTypeRaw = sourceType.rawValue
        let predicate = #Predicate<SyncCursor> { cursor in
            cursor.sourceTypeRaw == sourceTypeRaw
        }
        let descriptor = FetchDescriptor<SyncCursor>(predicate: predicate)

        if let existing = try mainContext.fetch(descriptor).first {
            return existing
        }

        let cursor = SyncCursor(sourceType: sourceType)
        mainContext.insert(cursor)
        return cursor
    }
}

// MARK: - Ambient Graph Queries

public extension DatabaseManager {
    /// Find entity by type and name
    func findEntity(type: EntityType, name: String) throws -> Entity? {
        let entityType = type
        let entityName = name
        let predicate = #Predicate<Entity> { entity in
            entity.entityType == entityType && entity.name == entityName
        }
        let descriptor = FetchDescriptor<Entity>(predicate: predicate)
        return try mainContext.fetch(descriptor).first
    }

    /// Find person by email
    func findPerson(email: String) throws -> Entity? {
        let lowercased = email.lowercased()
        let personType = EntityType.person
        let predicate = #Predicate<Entity> { entity in
            entity.entityType == personType && entity.email == lowercased
        }
        let descriptor = FetchDescriptor<Entity>(predicate: predicate)
        return try mainContext.fetch(descriptor).first
    }

    /// Get all edges for an entity
    func getEdges(for entity: Entity) throws -> (outgoing: [Edge], incoming: [Edge]) {
        // SwiftData predicates don't handle optional entity comparisons well
        // So we fetch all edges and filter in memory
        let allEdges = try mainContext.fetch(FetchDescriptor<Edge>())

        let outgoing = allEdges.filter { $0.fromEntity?.id == entity.id }
        let incoming = allEdges.filter { $0.toEntity?.id == entity.id }

        return (outgoing, incoming)
    }

    /// Find related entities (one hop)
    func findRelatedEntities(
        to entity: Entity,
        ofType type: EntityType? = nil
    ) throws -> [Entity] {
        let (outgoing, incoming) = try getEdges(for: entity)

        var related: Set<UUID> = []
        for edge in outgoing {
            if let to = edge.toEntity {
                if type == nil || to.entityType == type {
                    related.insert(to.id)
                }
            }
        }
        for edge in incoming {
            if let from = edge.fromEntity {
                if type == nil || from.entityType == type {
                    related.insert(from.id)
                }
            }
        }

        // Fetch the entities
        let predicate = #Predicate<Entity> { entity in
            related.contains(entity.id)
        }
        return try mainContext.fetch(FetchDescriptor<Entity>(predicate: predicate))
    }
}

// MARK: - Background Context for Helper

public extension DatabaseManager {
    /// Creates a database manager for use in the helper process
    /// Call this on a background thread
    nonisolated static func createForHelper() -> ModelContainer {
        let schema = Schema([
            // Raw Store
            RawItem.self,
            SyncCursor.self,
            // Unified Store
            AmbientEvent.self,
            AmbientTask.self,
            ActivityLog.self,
            // Ambient Graph
            Entity.self,
            Edge.self
        ])

        let configuration = ModelConfiguration(
            "AmbientAgent",
            schema: schema,
            isStoredInMemoryOnly: false,
            allowsSave: true,
            groupContainer: .identifier(appGroupIdentifier)
        )

        do {
            return try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            fatalError("Failed to create ModelContainer for helper: \(error)")
        }
    }
}
