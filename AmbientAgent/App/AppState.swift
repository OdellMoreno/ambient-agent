import SwiftUI
import SwiftData
import Observation
import EventKit
import SQLite3
import AmbientCore

/// Observable app-wide state
@Observable
@MainActor
public final class AppState {
    // MARK: - Navigation

    var selectedTab: DashboardTab = .insights
    var selectedEvent: AmbientEvent?
    var selectedTask: AmbientTask?
    var selectedEntity: Entity?

    // MARK: - UI State

    var isRefreshing = false
    var hasUnreadItems = false
    var showingSettings = false
    var showingAbout = false
    var searchText = ""

    // MARK: - Monitoring State

    var isMonitoringActive = false
    var lastSyncDate: Date?
    var syncError: String?
    var sourceErrors: [SourceType: String] = [:]

    // MARK: - XPC Client

    private let xpcClient = XPCClient.shared

    // MARK: - Initialization

    init() {
        // XPC helper connection is handled separately
        // Auto-sync is triggered via .task modifier in the view
    }

    // MARK: - Actions

    func connectToHelper() async {
        do {
            try xpcClient.connect()

            // Check if helper is registered
            let status = xpcClient.helperStatus
            if status != .enabled {
                try xpcClient.registerHelper()
            }

            // Ping to verify connection
            let isRunning = await xpcClient.ping()
            isMonitoringActive = isRunning

            await xpcClient.refreshStatus()
        } catch {
            AmbientLogger.xpc.error("Failed to connect to helper: \(error.localizedDescription)")
            syncError = error.localizedDescription
        }
    }

    func startMonitoring() async {
        do {
            // Start with calendar and messages for MVP
            try await xpcClient.startMonitoring(sources: [.calendar, .messages])
            isMonitoringActive = true
            syncError = nil
        } catch {
            syncError = error.localizedDescription
        }
    }

    func stopMonitoring() async {
        do {
            try await xpcClient.stopMonitoring()
            isMonitoringActive = false
        } catch {
            syncError = error.localizedDescription
        }
    }

    private func debugLog(_ message: String) {
        // Use app group container for logging (sandbox-safe)
        let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.ambient.agent")
        let logPath = containerURL?.appendingPathComponent("debug.log").path ?? "/tmp/ambient_debug.log"
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = "[\(timestamp)] \(message)\n"

        // Also log to system log
        NSLog("AmbientAgent: %@", message)

        if let data = line.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: logPath) {
                if let handle = FileHandle(forWritingAtPath: logPath) {
                    handle.seekToEndOfFile()
                    handle.write(data)
                    handle.closeFile()
                }
            } else {
                try? data.write(to: URL(fileURLWithPath: logPath))
            }
        }
        print(message)
    }

    func syncAll() async {
        debugLog("🔄 syncAll() called")
        isRefreshing = true
        defer { isRefreshing = false }

        // For development: sync directly without XPC helper
        // Clear previous errors
        sourceErrors = [:]

        await syncCalendarDirect()
        await syncMessagesDirect()
        await syncSafariDirect()
        await syncMailDirect()
        await syncNotesDirect()

        // Load insights data for all tabs (People, Insights, Activity, Graph, AI)
        debugLog("📊 Loading insights data...")
        await InsightsService.shared.loadAllInsights()
        InsightsService.shared.generateReachOutSuggestions()
        InsightsService.shared.computeWeeklyTrend()
        debugLog("✅ Insights data loaded")

        lastSyncDate = Date()
        debugLog("✅ syncAll() completed")
    }

    /// Direct calendar sync for development (no XPC helper needed)
    private func syncCalendarDirect() async {
        debugLog("📅 Starting calendar sync...")
        let eventStore = EKEventStore()

        do {
            // Request access
            let granted: Bool
            if #available(macOS 14.0, *) {
                granted = try await eventStore.requestFullAccessToEvents()
            } else {
                granted = try await withCheckedThrowingContinuation { continuation in
                    eventStore.requestAccess(to: .event) { granted, error in
                        if let error { continuation.resume(throwing: error) }
                        else { continuation.resume(returning: granted) }
                    }
                }
            }

            guard granted else {
                debugLog("❌ Calendar access denied")
                syncError = "Calendar access denied"
                return
            }
            debugLog("✅ Calendar access granted")

            // Fetch events for next 30 days
            let startDate = Date()
            let endDate = Calendar.current.date(byAdding: .day, value: 30, to: startDate)!
            let predicate = eventStore.predicateForEvents(withStart: startDate, end: endDate, calendars: nil)
            let ekEvents = eventStore.events(matching: predicate)

            // Get model context
            let container = DatabaseManager.shared.container
            let context = ModelContext(container)

            // Convert to AmbientEvents
            for ekEvent in ekEvents {
                let sourceId = ekEvent.eventIdentifier ?? UUID().uuidString
                let sourceTypeRaw = SourceType.calendar.rawValue

                // Check if exists
                let fetchDescriptor = FetchDescriptor<AmbientEvent>(
                    predicate: #Predicate { $0.sourceTypeRaw == sourceTypeRaw && $0.sourceIdentifier == sourceId }
                )

                if let existing = try? context.fetch(fetchDescriptor).first {
                    // Update
                    existing.title = ekEvent.title ?? "Untitled"
                    existing.startDate = ekEvent.startDate
                    existing.endDate = ekEvent.endDate
                    existing.location = ekEvent.location
                    existing.isAllDay = ekEvent.isAllDay
                    existing.updatedAt = Date()
                } else {
                    // Create new
                    let event = AmbientEvent(
                        title: ekEvent.title ?? "Untitled",
                        startDate: ekEvent.startDate,
                        sourceType: .calendar,
                        sourceIdentifier: sourceId,
                        confidence: .high
                    )
                    event.endDate = ekEvent.endDate
                    event.location = ekEvent.location
                    event.isAllDay = ekEvent.isAllDay
                    context.insert(event)
                }
            }

            try context.save()
            syncError = nil
            debugLog("📅 Synced \(ekEvents.count) calendar events")
            AmbientLogger.general.info("Synced \(ekEvents.count) calendar events")

        } catch {
            debugLog("❌ Calendar sync failed: \(error.localizedDescription)")
            syncError = error.localizedDescription
            AmbientLogger.general.error("Calendar sync failed: \(error.localizedDescription)")
        }
    }

    /// Direct iMessage sync for development (requires Full Disk Access)
    private func syncMessagesDirect() async {
        debugLog("💬 Starting iMessage sync...")
        let chatDBPath = NSHomeDirectory() + "/Library/Messages/chat.db"

        guard FileManager.default.fileExists(atPath: chatDBPath) else {
            debugLog("❌ Messages database not found at: \(chatDBPath)")
            AmbientLogger.general.warning("Messages database not found")
            return
        }
        debugLog("✅ Messages database found")

        var db: OpaquePointer?
        guard sqlite3_open_v2(chatDBPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            debugLog("❌ Failed to open Messages database - need Full Disk Access")
            AmbientLogger.general.error("Failed to open Messages database - need Full Disk Access")
            syncError = "Grant Full Disk Access in System Settings > Privacy & Security"
            return
        }
        defer { sqlite3_close(db) }
        debugLog("✅ Messages database opened")

        // Query recent messages (last 7 days)
        let query = """
            SELECT
                m.ROWID,
                m.guid,
                m.text,
                m.date/1000000000 + 978307200 as unix_date,
                m.is_from_me,
                h.id as handle_id,
                c.display_name as chat_name
            FROM message m
            LEFT JOIN handle h ON m.handle_id = h.ROWID
            LEFT JOIN chat_message_join cmj ON m.ROWID = cmj.message_id
            LEFT JOIN chat c ON cmj.chat_id = c.ROWID
            WHERE m.text IS NOT NULL
                AND m.text != ''
                AND m.date/1000000000 + 978307200 > \(Date().timeIntervalSince1970 - 7*24*60*60)
            ORDER BY m.date DESC
            LIMIT 500
            """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else {
            AmbientLogger.general.error("Failed to prepare Messages query")
            return
        }
        defer { sqlite3_finalize(stmt) }

        let container = DatabaseManager.shared.container
        let context = ModelContext(container)
        var messageCount = 0

        while sqlite3_step(stmt) == SQLITE_ROW {
            let rowId = sqlite3_column_int64(stmt, 0)
            let guid = String(cString: sqlite3_column_text(stmt, 1))
            let text = sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? ""
            let unixDate = sqlite3_column_double(stmt, 3)
            let isFromMe = sqlite3_column_int(stmt, 4) == 1
            let handleId = sqlite3_column_text(stmt, 5).map { String(cString: $0) }
            let chatName = sqlite3_column_text(stmt, 6).map { String(cString: $0) }

            let messageDate = Date(timeIntervalSince1970: unixDate)
            let sourceId = guid
            let sourceTypeRaw = SourceType.messages.rawValue

            // Check if this message might contain event/task info (simple heuristics)
            let lowerText = text.lowercased()
            let mightHaveEvent = lowerText.contains("meet") ||
                                 lowerText.contains("call") ||
                                 lowerText.contains("tomorrow") ||
                                 lowerText.contains("tonight") ||
                                 lowerText.contains("next week") ||
                                 lowerText.contains("lunch") ||
                                 lowerText.contains("dinner") ||
                                 lowerText.contains("coffee")

            let mightHaveTask = lowerText.contains("todo") ||
                                lowerText.contains("remind") ||
                                lowerText.contains("don't forget") ||
                                lowerText.contains("need to") ||
                                lowerText.contains("should")

            // For now, store messages that might have events as potential events
            if mightHaveEvent && !isFromMe {
                let fetchDescriptor = FetchDescriptor<AmbientEvent>(
                    predicate: #Predicate { $0.sourceTypeRaw == sourceTypeRaw && $0.sourceIdentifier == sourceId }
                )

                if (try? context.fetch(fetchDescriptor).first) == nil {
                    let event = AmbientEvent(
                        title: "Potential: \(text.prefix(50))...",
                        startDate: messageDate,
                        sourceType: .messages,
                        sourceIdentifier: sourceId,
                        confidence: .low
                    )
                    event.rawSnippet = text
                    event.eventDescription = "From: \(handleId ?? chatName ?? "Unknown")"
                    context.insert(event)
                    messageCount += 1
                }
            }

            // Store messages that might have tasks
            if mightHaveTask {
                let taskSourceTypeRaw = SourceType.messages.rawValue
                let fetchDescriptor = FetchDescriptor<AmbientTask>(
                    predicate: #Predicate { $0.sourceTypeRaw == taskSourceTypeRaw && $0.sourceIdentifier == sourceId }
                )

                if (try? context.fetch(fetchDescriptor).first) == nil {
                    let task = AmbientTask(
                        title: String(text.prefix(100)),
                        sourceType: .messages,
                        sourceIdentifier: sourceId,
                        confidence: .low
                    )
                    task.rawSnippet = text
                    task.context = "From: \(handleId ?? chatName ?? "Unknown")"
                    context.insert(task)
                    messageCount += 1
                }
            }
        }

        do {
            try context.save()
            debugLog("💬 Processed \(messageCount) potential items from Messages")
            AmbientLogger.general.info("Processed \(messageCount) potential items from Messages")
        } catch {
            debugLog("❌ Failed to save message items: \(error)")
            AmbientLogger.general.error("Failed to save message items: \(error)")
        }
    }

    /// Direct Safari history sync (requires Full Disk Access)
    private func syncSafariDirect() async {
        debugLog("🌐 Starting Safari sync...")
        let historyDBPath = NSHomeDirectory() + "/Library/Safari/History.db"

        guard FileManager.default.fileExists(atPath: historyDBPath) else {
            debugLog("❌ Safari history database not found")
            return
        }

        var db: OpaquePointer?
        guard sqlite3_open_v2(historyDBPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            debugLog("❌ Failed to open Safari history - need Full Disk Access")
            sourceErrors[.safari] = "Grant Full Disk Access in System Settings"
            return
        }
        defer { sqlite3_close(db) }

        // Query recent history (last 7 days)
        let query = """
            SELECT
                hi.id,
                hi.url,
                hv.title,
                hv.visit_time + 978307200 as unix_time
            FROM history_items hi
            JOIN history_visits hv ON hi.id = hv.history_item
            WHERE hv.visit_time + 978307200 > \(Date().timeIntervalSince1970 - 7*24*60*60)
            ORDER BY hv.visit_time DESC
            LIMIT 200
            """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else {
            debugLog("❌ Failed to prepare Safari query")
            return
        }
        defer { sqlite3_finalize(stmt) }

        let container = DatabaseManager.shared.container
        let context = ModelContext(container)
        var historyCount = 0

        while sqlite3_step(stmt) == SQLITE_ROW {
            let itemId = sqlite3_column_int64(stmt, 0)
            let url = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
            let title = sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? ""
            let unixTime = sqlite3_column_double(stmt, 3)

            let visitDate = Date(timeIntervalSince1970: unixTime)
            let sourceId = "safari-\(itemId)"
            let sourceTypeRaw = SourceType.safari.rawValue

            // Skip common non-content URLs
            let lowerUrl = url.lowercased()
            if lowerUrl.contains("google.com/search") ||
               lowerUrl.contains("favicon") ||
               lowerUrl.contains("analytics") {
                continue
            }

            // Check for potential event/task content in title
            let lowerTitle = title.lowercased()
            let mightHaveEvent = lowerTitle.contains("event") ||
                                 lowerTitle.contains("ticket") ||
                                 lowerTitle.contains("reservation") ||
                                 lowerTitle.contains("booking") ||
                                 lowerTitle.contains("appointment")

            if mightHaveEvent {
                let fetchDescriptor = FetchDescriptor<AmbientEvent>(
                    predicate: #Predicate { $0.sourceTypeRaw == sourceTypeRaw && $0.sourceIdentifier == sourceId }
                )

                if (try? context.fetch(fetchDescriptor).first) == nil {
                    let event = AmbientEvent(
                        title: "Web: \(title.prefix(50))",
                        startDate: visitDate,
                        sourceType: .safari,
                        sourceIdentifier: sourceId,
                        confidence: .low
                    )
                    event.rawSnippet = url
                    context.insert(event)
                    historyCount += 1
                }
            }
        }

        do {
            try context.save()
            debugLog("🌐 Processed \(historyCount) potential items from Safari")
        } catch {
            debugLog("❌ Failed to save Safari items: \(error)")
        }
    }

    /// Direct Apple Mail sync (requires Automation permission)
    private func syncMailDirect() async {
        debugLog("📧 Starting Mail sync...")

        let script = """
            tell application "Mail"
                set recentMessages to {}
                try
                    set inboxMessages to messages of inbox
                    repeat with i from 1 to (count of inboxMessages)
                        if i > 50 then exit repeat
                        set msg to item i of inboxMessages
                        set msgDate to date received of msg
                        if msgDate > (current date) - 7 * days then
                            set msgInfo to {subject of msg, sender of msg, msgDate as string, id of msg}
                            set end of recentMessages to msgInfo
                        end if
                    end repeat
                end try
                return recentMessages
            end tell
            """

        var error: NSDictionary?
        guard let appleScript = NSAppleScript(source: script) else {
            debugLog("❌ Failed to create Mail AppleScript")
            return
        }

        let result = appleScript.executeAndReturnError(&error)

        if let error = error {
            let errorMessage = error["NSAppleScriptErrorMessage"] as? String ?? "Unknown error"
            debugLog("❌ Mail sync error: \(errorMessage)")
            if errorMessage.contains("not allowed") || errorMessage.contains("permission") {
                sourceErrors[.email] = "Grant Automation permission for Mail"
            }
            return
        }

        guard result.numberOfItems > 0 else {
            debugLog("📧 No recent emails found")
            return
        }

        let container = DatabaseManager.shared.container
        let context = ModelContext(container)
        var emailCount = 0

        for i in 1...result.numberOfItems {
            guard let item = result.atIndex(i),
                  item.numberOfItems >= 4,
                  let subject = item.atIndex(1)?.stringValue,
                  let sender = item.atIndex(2)?.stringValue,
                  let msgId = item.atIndex(4)?.stringValue else {
                continue
            }

            let sourceId = "mail-\(msgId)"
            let sourceTypeRaw = SourceType.email.rawValue

            // Check for potential events in subject
            let lowerSubject = subject.lowercased()
            let mightHaveEvent = lowerSubject.contains("invitation") ||
                                 lowerSubject.contains("meeting") ||
                                 lowerSubject.contains("calendar") ||
                                 lowerSubject.contains("rsvp") ||
                                 lowerSubject.contains("reminder")

            let mightHaveTask = lowerSubject.contains("action required") ||
                                lowerSubject.contains("please review") ||
                                lowerSubject.contains("todo") ||
                                lowerSubject.contains("deadline")

            if mightHaveEvent {
                let fetchDescriptor = FetchDescriptor<AmbientEvent>(
                    predicate: #Predicate { $0.sourceTypeRaw == sourceTypeRaw && $0.sourceIdentifier == sourceId }
                )

                if (try? context.fetch(fetchDescriptor).first) == nil {
                    let event = AmbientEvent(
                        title: "Email: \(subject.prefix(50))",
                        startDate: Date(),
                        sourceType: .email,
                        sourceIdentifier: sourceId,
                        confidence: .low
                    )
                    event.eventDescription = "From: \(sender)"
                    context.insert(event)
                    emailCount += 1
                }
            }

            if mightHaveTask {
                let fetchDescriptor = FetchDescriptor<AmbientTask>(
                    predicate: #Predicate { $0.sourceTypeRaw == sourceTypeRaw && $0.sourceIdentifier == sourceId }
                )

                if (try? context.fetch(fetchDescriptor).first) == nil {
                    let task = AmbientTask(
                        title: subject,
                        sourceType: .email,
                        sourceIdentifier: sourceId,
                        confidence: .low
                    )
                    task.context = "From: \(sender)"
                    context.insert(task)
                    emailCount += 1
                }
            }
        }

        do {
            try context.save()
            debugLog("📧 Processed \(emailCount) potential items from Mail")
        } catch {
            debugLog("❌ Failed to save Mail items: \(error)")
        }
    }

    /// Direct Notes sync (requires Automation permission)
    private func syncNotesDirect() async {
        debugLog("📝 Starting Notes sync...")

        let script = """
            tell application "Notes"
                set notesList to {}
                try
                    repeat with aNote in notes
                        set noteInfo to {name of aNote, id of aNote, modification date of aNote as string}
                        set end of notesList to noteInfo
                        if (count of notesList) > 50 then exit repeat
                    end repeat
                end try
                return notesList
            end tell
            """

        var error: NSDictionary?
        guard let appleScript = NSAppleScript(source: script) else {
            debugLog("❌ Failed to create Notes AppleScript")
            return
        }

        let result = appleScript.executeAndReturnError(&error)

        if let error = error {
            let errorMessage = error["NSAppleScriptErrorMessage"] as? String ?? "Unknown error"
            debugLog("❌ Notes sync error: \(errorMessage)")
            if errorMessage.contains("not allowed") || errorMessage.contains("permission") {
                sourceErrors[.notes] = "Grant Automation permission for Notes"
            }
            return
        }

        guard result.numberOfItems > 0 else {
            debugLog("📝 No notes found")
            return
        }

        let container = DatabaseManager.shared.container
        let context = ModelContext(container)
        var notesCount = 0

        for i in 1...result.numberOfItems {
            guard let item = result.atIndex(i),
                  item.numberOfItems >= 2,
                  let title = item.atIndex(1)?.stringValue,
                  let noteId = item.atIndex(2)?.stringValue else {
                continue
            }

            let sourceId = "notes-\(noteId)"
            let sourceTypeRaw = SourceType.notes.rawValue

            // Check for potential tasks in title
            let lowerTitle = title.lowercased()
            let mightHaveTask = lowerTitle.contains("todo") ||
                                lowerTitle.contains("task") ||
                                lowerTitle.contains("checklist") ||
                                lowerTitle.contains("reminder") ||
                                lowerTitle.contains("action")

            if mightHaveTask {
                let fetchDescriptor = FetchDescriptor<AmbientTask>(
                    predicate: #Predicate { $0.sourceTypeRaw == sourceTypeRaw && $0.sourceIdentifier == sourceId }
                )

                if (try? context.fetch(fetchDescriptor).first) == nil {
                    let task = AmbientTask(
                        title: "Note: \(title.prefix(50))",
                        sourceType: .notes,
                        sourceIdentifier: sourceId,
                        confidence: .low
                    )
                    context.insert(task)
                    notesCount += 1
                }
            }
        }

        do {
            try context.save()
            debugLog("📝 Processed \(notesCount) potential items from Notes")
        } catch {
            debugLog("❌ Failed to save Notes items: \(error)")
        }
    }

    func refreshStatus() async {
        await xpcClient.refreshStatus()
        isMonitoringActive = xpcClient.isHelperRunning
    }
}

// MARK: - Dashboard Tabs

enum DashboardTab: String, CaseIterable, Identifiable {
    case today = "Today"
    case upcoming = "Upcoming"
    case tasks = "Tasks"
    case insights = "Insights"
    case people = "People"
    case activity = "Activity"
    case graph = "Graph"
    case ai = "AI"
    case sources = "Sources"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .today: return "sun.max.fill"
        case .upcoming: return "calendar"
        case .tasks: return "checklist"
        case .insights: return "brain.head.profile"
        case .people: return "person.2.fill"
        case .activity: return "waveform.path.ecg"
        case .graph: return "point.3.connected.trianglepath.dotted"
        case .ai: return "sparkles"
        case .sources: return "arrow.triangle.2.circlepath"
        }
    }
}
