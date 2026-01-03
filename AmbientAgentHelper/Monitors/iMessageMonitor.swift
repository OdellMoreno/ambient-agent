import Foundation
import SQLite3
import SwiftData
import AmbientCore

/// Monitors iMessage by reading the chat.db SQLite database
actor iMessageMonitor: DataSourceMonitor {
    let sourceType: SourceType = .messages
    private(set) var isMonitoring = false

    private let context: ModelContext
    private let dbPath: String

    private var db: OpaquePointer?
    private var fileWatcher: FileSystemWatcher?
    private var lastProcessedRowID: Int64 = 0

    init(context: ModelContext) {
        self.context = context
        self.dbPath = NSHomeDirectory() + "/Library/Messages/chat.db"
    }

    // MARK: - DataSourceMonitor

    func startMonitoring() async throws {
        AmbientLogger.monitors.info("Starting iMessage monitor")

        // Check for Full Disk Access
        guard FileManager.default.isReadableFile(atPath: dbPath) else {
            throw AmbientAgentError.permissionDenied("Full Disk Access required for Messages")
        }

        // Open database connection
        try openDatabase()

        // Get the latest row ID to start from
        lastProcessedRowID = getLatestRowID()

        isMonitoring = true

        // Start file system watcher
        let messagesDir = NSHomeDirectory() + "/Library/Messages"
        fileWatcher = FileSystemWatcher(path: messagesDir) { [weak self] in
            Task {
                try? await self?.checkForNewMessages()
            }
        }
        fileWatcher?.start()

        // Initial sync of recent messages
        try await forceSync()
    }

    func stopMonitoring() async {
        AmbientLogger.monitors.info("Stopping iMessage monitor")
        isMonitoring = false
        fileWatcher?.stop()
        fileWatcher = nil
        closeDatabase()
    }

    func forceSync() async throws {
        AmbientLogger.monitors.info("Syncing iMessage")

        // Fetch messages from the last 7 days for initial sync
        let messages = try fetchRecentMessages(days: 7)
        AmbientLogger.monitors.info("Found \(messages.count) recent messages")

        // Store raw messages for LLM extraction
        for message in messages {
            try await storeRawMessage(message)
        }

        try context.save()
        logActivity(type: .syncCompleted, message: "Synced \(messages.count) messages")
    }

    // MARK: - Private

    private func openDatabase() throws {
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(dbPath, &db, flags, nil) == SQLITE_OK else {
            throw AmbientAgentError.syncFailed("Failed to open Messages database")
        }
    }

    private func closeDatabase() {
        if let db {
            sqlite3_close(db)
            self.db = nil
        }
    }

    private func getLatestRowID() -> Int64 {
        guard let db else { return 0 }

        let query = "SELECT MAX(ROWID) FROM message"
        var stmt: OpaquePointer?

        guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else {
            return 0
        }
        defer { sqlite3_finalize(stmt) }

        if sqlite3_step(stmt) == SQLITE_ROW {
            return sqlite3_column_int64(stmt, 0)
        }

        return 0
    }

    private func checkForNewMessages() async throws {
        guard isMonitoring else { return }

        let messages = try fetchMessagesSince(rowID: lastProcessedRowID)

        if !messages.isEmpty {
            AmbientLogger.monitors.debug("Found \(messages.count) new messages")

            for message in messages {
                try await storeRawMessage(message)
                lastProcessedRowID = max(lastProcessedRowID, message.rowID)
            }

            try context.save()
        }
    }

    private func fetchRecentMessages(days: Int) throws -> [RawMessage] {
        guard let db else { return [] }

        // iMessage uses nanoseconds since 2001-01-01
        let referenceDate = Date(timeIntervalSinceReferenceDate: 0)
        let startDate = Calendar.current.date(byAdding: .day, value: -days, to: Date())!
        let startTimestamp = Int64(startDate.timeIntervalSince(referenceDate) * 1_000_000_000)

        let query = """
            SELECT
                m.ROWID,
                m.guid,
                m.text,
                m.date,
                m.is_from_me,
                h.id as sender_id,
                c.chat_identifier,
                c.display_name
            FROM message m
            LEFT JOIN handle h ON m.handle_id = h.ROWID
            LEFT JOIN chat_message_join cmj ON m.ROWID = cmj.message_id
            LEFT JOIN chat c ON cmj.chat_id = c.ROWID
            WHERE m.date > ?
            ORDER BY m.date DESC
            LIMIT 500
        """

        return try executeMessageQuery(query, bindings: [startTimestamp])
    }

    private func fetchMessagesSince(rowID: Int64) throws -> [RawMessage] {
        guard let db else { return [] }

        let query = """
            SELECT
                m.ROWID,
                m.guid,
                m.text,
                m.date,
                m.is_from_me,
                h.id as sender_id,
                c.chat_identifier,
                c.display_name
            FROM message m
            LEFT JOIN handle h ON m.handle_id = h.ROWID
            LEFT JOIN chat_message_join cmj ON m.ROWID = cmj.message_id
            LEFT JOIN chat c ON cmj.chat_id = c.ROWID
            WHERE m.ROWID > ?
            ORDER BY m.date ASC
        """

        return try executeMessageQuery(query, bindings: [rowID])
    }

    private func executeMessageQuery(_ query: String, bindings: [Int64]) throws -> [RawMessage] {
        guard let db else { return [] }

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else {
            throw AmbientAgentError.syncFailed("Failed to prepare query")
        }
        defer { sqlite3_finalize(stmt) }

        for (index, value) in bindings.enumerated() {
            sqlite3_bind_int64(stmt, Int32(index + 1), value)
        }

        var messages: [RawMessage] = []

        while sqlite3_step(stmt) == SQLITE_ROW {
            let rowID = sqlite3_column_int64(stmt, 0)
            let guid = getString(stmt, column: 1) ?? ""
            let text = getString(stmt, column: 2)
            let dateNanos = sqlite3_column_int64(stmt, 3)
            let isFromMe = sqlite3_column_int(stmt, 4) == 1
            let senderID = getString(stmt, column: 5)
            let chatIdentifier = getString(stmt, column: 6)
            let displayName = getString(stmt, column: 7)

            // Convert nanoseconds since 2001-01-01 to Date
            let seconds = Double(dateNanos) / 1_000_000_000.0
            let date = Date(timeIntervalSinceReferenceDate: seconds)

            let message = RawMessage(
                rowID: rowID,
                guid: guid,
                text: text,
                date: date,
                isFromMe: isFromMe,
                senderID: senderID,
                chatIdentifier: chatIdentifier,
                displayName: displayName
            )

            messages.append(message)
        }

        return messages
    }

    private func getString(_ stmt: OpaquePointer?, column: Int32) -> String? {
        guard let ptr = sqlite3_column_text(stmt, column) else { return nil }
        return String(cString: ptr)
    }

    private func storeRawMessage(_ message: RawMessage) async throws {
        // Skip empty messages
        guard let text = message.text, !text.isEmpty else { return }

        // Store in Raw Store for provenance and reprocessing
        let compositeKey = "\(SourceType.messages.rawValue):\(message.guid)"

        // Check if already stored
        let existingPredicate = #Predicate<RawItem> { item in
            item.compositeKey == compositeKey
        }

        let descriptor = FetchDescriptor<RawItem>(predicate: existingPredicate)
        if let _ = try? context.fetch(descriptor).first {
            return // Already stored
        }

        // Create raw item content as JSON
        let content: [String: Any] = [
            "text": text,
            "sender": message.senderID ?? "",
            "chat": message.chatIdentifier ?? "",
            "displayName": message.displayName ?? "",
            "isFromMe": message.isFromMe,
            "rowID": message.rowID
        ]

        guard let contentData = try? JSONSerialization.data(withJSONObject: content) else {
            return
        }

        let rawItem = RawItem(
            sourceType: .messages,
            stableID: message.guid,
            content: contentData,
            contentType: .json,
            sourceTimestamp: message.date
        )

        rawItem.threadID = message.chatIdentifier
        rawItem.participants = [message.senderID].compactMap { $0 }
        rawItem.metadata = [
            "isFromMe": String(message.isFromMe),
            "displayName": message.displayName ?? ""
        ]

        context.insert(rawItem)
    }

    private func logActivity(type: ActivityType, message: String) {
        let log = ActivityLog(type: type, message: message, sourceType: .messages)
        context.insert(log)
        try? context.save()
    }
}

// MARK: - Raw Message Model

struct RawMessage {
    let rowID: Int64
    let guid: String
    let text: String?
    let date: Date
    let isFromMe: Bool
    let senderID: String?
    let chatIdentifier: String?
    let displayName: String?
}

// MARK: - File System Watcher

final class FileSystemWatcher: @unchecked Sendable {
    private var eventStream: FSEventStreamRef?
    private let path: String
    private let callback: () -> Void
    private let queue = DispatchQueue(label: "com.ambient.fsevents")

    init(path: String, callback: @escaping () -> Void) {
        self.path = path
        self.callback = callback
    }

    func start() {
        let pathsToWatch = [path] as CFArray

        var context = FSEventStreamContext()
        context.info = Unmanaged.passUnretained(self).toOpaque()

        let flags: FSEventStreamCreateFlags = UInt32(
            kFSEventStreamCreateFlagUseCFTypes |
            kFSEventStreamCreateFlagFileEvents |
            kFSEventStreamCreateFlagNoDefer
        )

        eventStream = FSEventStreamCreate(
            nil,
            { (_, clientInfo, numEvents, eventPaths, eventFlags, _) in
                guard let info = clientInfo else { return }
                let watcher = Unmanaged<FileSystemWatcher>.fromOpaque(info).takeUnretainedValue()

                let paths = unsafeBitCast(eventPaths, to: NSArray.self) as! [String]

                // Check if any events are for the database
                for path in paths {
                    if path.contains("chat.db") {
                        watcher.callback()
                        break
                    }
                }
            },
            &context,
            pathsToWatch,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.5, // 500ms latency
            flags
        )

        if let stream = eventStream {
            FSEventStreamSetDispatchQueue(stream, queue)
            FSEventStreamStart(stream)
        }
    }

    func stop() {
        if let stream = eventStream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            eventStream = nil
        }
    }

    deinit {
        stop()
    }
}
