import Foundation
import SQLite3

// MARK: - Insights Service
// Queries real data from Messages, Safari, etc. to compute insights

@MainActor
class InsightsService: ObservableObject {
    static let shared = InsightsService()

    // MARK: - Gemini AI Integration

    @Published var geminiAPIKey: String? {
        didSet { UserDefaults.standard.set(geminiAPIKey, forKey: "gemini_api_key") }
    }
    @Published var isAnalyzingAI = false
    @Published var reachOutSuggestions: [ReachOutSuggestion] = []
    @Published var weeklyTrend: WeeklyTrend?

    struct ReachOutSuggestion: Identifiable {
        let id = UUID()
        let contactId: String
        let contactName: String
        let reason: String
        let daysSinceContact: Int
        let priority: Int // 1=low, 2=medium, 3=high
    }

    struct WeeklyTrend {
        let thisWeekMessages: Int
        let lastWeekMessages: Int
        let percentChange: Double
        let busiestDay: String
        let avgPerDay: Double
    }

    var hasGeminiKey: Bool {
        guard let key = geminiAPIKey else { return false }
        return !key.isEmpty
    }

    @Published var contacts: [Contact] = []
    @Published var hourlyPattern: [Int: Int] = [:]
    @Published var dailyVolume: [String: Int] = [:]
    @Published var dayOfWeekPattern: [Int: Int] = [:] // 0=Sunday, 6=Saturday
    @Published var groupChats: [GroupChat] = []
    @Published var wellbeingScore: WellbeingData?
    @Published var recentInsights: [Insight] = []
    @Published var isLoading = false
    @Published var unreadMessages: [(contact: String, count: Int, oldestDate: Date)] = []

    // Privacy settings
    @Published var blockedContacts: [String] = []
    @Published var privacyBlurEnabled: Bool = false

    private let blockedContactsKey = "blockedContacts"
    private let privacyBlurKey = "privacyBlurEnabled"

    struct GroupChat: Identifiable {
        let id: String
        let name: String
        let messageCount: Int
        let participantCount: Int
    }

    private init() {
        // Load privacy settings from UserDefaults
        if let saved = UserDefaults.standard.array(forKey: blockedContactsKey) as? [String] {
            blockedContacts = saved
        }
        privacyBlurEnabled = UserDefaults.standard.bool(forKey: privacyBlurKey)
        geminiAPIKey = UserDefaults.standard.string(forKey: "gemini_api_key")
    }

    // MARK: - AI Features

    func generateReachOutSuggestions() {
        var suggestions: [ReachOutSuggestion] = []

        for contact in contacts {
            let daysSince = contact.daysSinceContact

            if contact.relationshipStrength >= 0.6 && daysSince >= 14 {
                suggestions.append(ReachOutSuggestion(
                    contactId: contact.id,
                    contactName: contact.displayName ?? contact.phoneOrEmail,
                    reason: "You usually talk more often - it's been \(daysSince) days",
                    daysSinceContact: daysSince,
                    priority: daysSince > 30 ? 3 : 2
                ))
            } else if contact.heartReactions > 10 && daysSince >= 21 {
                suggestions.append(ReachOutSuggestion(
                    contactId: contact.id,
                    contactName: contact.displayName ?? contact.phoneOrEmail,
                    reason: "Close connection - haven't heard from them in \(daysSince) days",
                    daysSinceContact: daysSince,
                    priority: 3
                ))
            } else if contact.messageCount >= 30 && daysSince >= 30 {
                suggestions.append(ReachOutSuggestion(
                    contactId: contact.id,
                    contactName: contact.displayName ?? contact.phoneOrEmail,
                    reason: "It's been a month since you last talked",
                    daysSinceContact: daysSince,
                    priority: 1
                ))
            }
        }

        reachOutSuggestions = suggestions.sorted { $0.priority > $1.priority }
    }

    func computeWeeklyTrend() {
        // Get this week vs last week from daily volume
        let sortedDays = dailyVolume.sorted { $0.key > $1.key }
        let thisWeek = sortedDays.prefix(7)
        let lastWeek = sortedDays.dropFirst(7).prefix(7)

        let thisWeekTotal = thisWeek.reduce(0) { $0 + $1.value }
        let lastWeekTotal = lastWeek.reduce(0) { $0 + $1.value }

        let change: Double
        if lastWeekTotal > 0 {
            change = Double(thisWeekTotal - lastWeekTotal) / Double(lastWeekTotal) * 100
        } else {
            change = 0
        }

        // Find busiest day
        let dayTotals = Dictionary(grouping: thisWeek, by: { dayOfWeek(from: $0.key) })
            .mapValues { $0.reduce(0) { $0 + $1.value } }
        let busiest = dayTotals.max(by: { $0.value < $1.value })?.key ?? "Unknown"

        weeklyTrend = WeeklyTrend(
            thisWeekMessages: thisWeekTotal,
            lastWeekMessages: lastWeekTotal,
            percentChange: change,
            busiestDay: busiest,
            avgPerDay: thisWeek.isEmpty ? 0 : Double(thisWeekTotal) / Double(thisWeek.count)
        )
    }

    /// Load recent messages for a contact (for AI analysis)
    func loadRecentMessages(for contactId: String, limit: Int = 30) async -> [String] {
        let realHome = FileManager.default.homeDirectoryForCurrentUser.path
        let chatDBPath = realHome + "/Library/Messages/chat.db"

        var db: OpaquePointer?
        guard sqlite3_open_v2(chatDBPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_close(db) }

        let query = """
            SELECT m.text
            FROM message m
            JOIN handle h ON m.handle_id = h.ROWID
            WHERE h.id = ?
                AND m.text IS NOT NULL
                AND m.text != ''
            ORDER BY m.date DESC
            LIMIT \(limit)
            """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, contactId, -1, nil)

        var messages: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let textPtr = sqlite3_column_text(stmt, 0) {
                let text = String(cString: textPtr)
                messages.append(text)
            }
        }

        return messages
    }

    private func dayOfWeek(from dateString: String) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        guard let date = formatter.date(from: dateString) else { return "Unknown" }
        let dayFormatter = DateFormatter()
        dayFormatter.dateFormat = "EEEE"
        return dayFormatter.string(from: date)
    }

    // MARK: - Privacy Controls

    func blockContact(_ contactId: String) {
        let normalized = normalizeContactId(contactId)
        guard !blockedContacts.contains(normalized) else { return }
        blockedContacts.append(normalized)
        UserDefaults.standard.set(blockedContacts, forKey: blockedContactsKey)

        // Remove from current contacts list (check both normalized and original)
        contacts.removeAll { normalizeContactId($0.id) == normalized }

        // Recompute insights without this contact
        computeWellbeing()
        detectInsights()
    }

    func unblockContact(_ contactId: String) {
        let normalized = normalizeContactId(contactId)
        blockedContacts.removeAll { $0 == normalized }
        UserDefaults.standard.set(blockedContacts, forKey: blockedContactsKey)
    }

    /// Normalize contact ID for consistent matching (strips +1, spaces, dashes)
    private func normalizeContactId(_ id: String) -> String {
        var cleaned = id.replacingOccurrences(of: " ", with: "")
                        .replacingOccurrences(of: "-", with: "")
                        .replacingOccurrences(of: "(", with: "")
                        .replacingOccurrences(of: ")", with: "")

        // Remove +1 prefix for US numbers
        if cleaned.hasPrefix("+1") && cleaned.count == 12 {
            cleaned = String(cleaned.dropFirst(2))
        } else if cleaned.hasPrefix("1") && cleaned.count == 11 {
            cleaned = String(cleaned.dropFirst(1))
        }

        return cleaned.lowercased()
    }

    /// Check if a contact ID is blocked (handles format variations)
    func isBlocked(_ contactId: String) -> Bool {
        let normalized = normalizeContactId(contactId)
        return blockedContacts.contains { normalizeContactId($0) == normalized }
    }

    func togglePrivacyBlur() {
        privacyBlurEnabled.toggle()
        UserDefaults.standard.set(privacyBlurEnabled, forKey: privacyBlurKey)
    }

    /// Returns a privacy-safe display name (blurred if privacy mode enabled)
    func privacySafeName(_ name: String) -> String {
        guard privacyBlurEnabled else { return name }

        // Return redacted placeholder
        if name.contains("@") {
            return "••••••@••••••"
        } else if name.hasPrefix("+") || name.first?.isNumber == true {
            return "(•••) •••-••••"
        } else {
            // For names, show first initial only
            let parts = name.components(separatedBy: " ")
            if parts.count >= 2 {
                return "\(parts[0].prefix(1)). \(parts[1].prefix(1))."
            }
            return "\(name.prefix(1))••••"
        }
    }

    // MARK: - Data Models

    struct Contact: Identifiable {
        let id: String
        let phoneOrEmail: String
        let displayName: String?
        let messageCount: Int
        let lastMessageDate: Date
        let firstMessageDate: Date
        let sentiment: Double // -1 to 1

        // Rich metadata
        var sentCount: Int = 0
        var receivedCount: Int = 0
        var heartReactions: Int = 0
        var thumbsUpReactions: Int = 0
        var hahaReactions: Int = 0
        var attachmentCount: Int = 0
        var imageCount: Int = 0
        var avgResponseMinutes: Double = 0

        var relationshipStrength: Double {
            min(1.0, Double(messageCount) / 500.0)
        }

        var daysSinceContact: Int {
            Calendar.current.dateComponents([.day], from: lastMessageDate, to: Date()).day ?? 0
        }

        // Derived metrics
        var reciprocityRatio: Double {
            guard receivedCount > 0 else { return 1.0 }
            return Double(sentCount) / Double(receivedCount)
        }

        var engagementScore: Double {
            // Higher score = more engaged (reactions, media sharing)
            let reactionScore = Double(heartReactions + thumbsUpReactions + hahaReactions) / max(1.0, Double(messageCount)) * 100
            let mediaScore = Double(attachmentCount) / max(1.0, Double(messageCount)) * 50
            return min(100, reactionScore + mediaScore)
        }
    }

    struct WellbeingData {
        let overall: Double
        let sleepQuality: Double
        let socialConnection: Double
        let stressLevel: Double
        let sleepHourMessages: Int
        let supportNetworkSize: Int
    }

    struct Insight: Identifiable {
        let id = UUID()
        let type: InsightType
        let title: String
        let description: String
        let priority: Priority
        let date: Date

        enum InsightType: String {
            case volumeSpike = "volume_spike"
            case sleepDisruption = "sleep_disruption"
            case supportNetwork = "support_network"
            case lifeMilestone = "life_milestone"
        }

        enum Priority: Int {
            case low = 1, medium = 2, high = 3, critical = 4
        }
    }

    // MARK: - Load All Data

    func loadAllInsights() async {
        NSLog("[InsightsService] loadAllInsights() called")
        isLoading = true
        defer { isLoading = false }

        await loadContacts()
        await loadTimePatterns()
        await loadGroupChats()
        await loadUnreadMessages()
        computeWellbeing()
        detectInsights()
    }

    // MARK: - Load Contacts from Messages DB

    func loadContacts() async {
        // Use real home directory, not sandbox container
        let realHome = FileManager.default.homeDirectoryForCurrentUser.path
        let chatDBPath = realHome + "/Library/Messages/chat.db"
        NSLog("[InsightsService] Loading contacts from: %@", chatDBPath)

        guard FileManager.default.fileExists(atPath: chatDBPath) else {
            NSLog("[InsightsService] ERROR: Messages database not found")
            return
        }
        NSLog("[InsightsService] Database file exists")

        var db: OpaquePointer?
        let openResult = sqlite3_open_v2(chatDBPath, &db, SQLITE_OPEN_READONLY, nil)
        guard openResult == SQLITE_OK else {
            let errorMsg = String(cString: sqlite3_errmsg(db))
            NSLog("[InsightsService] ERROR: Failed to open database: %@ (code: %d)", errorMsg, openResult)
            return
        }
        defer { sqlite3_close(db) }
        NSLog("[InsightsService] Database opened successfully")

        // Rich query with sent/received, reactions, attachments
        let query = """
            SELECT
                h.id as contact,
                COUNT(*) as msg_count,
                MIN(m.date/1000000000 + 978307200) as first_msg,
                MAX(m.date/1000000000 + 978307200) as last_msg,
                SUM(CASE WHEN m.is_from_me = 1 THEN 1 ELSE 0 END) as sent_count,
                SUM(CASE WHEN m.is_from_me = 0 THEN 1 ELSE 0 END) as received_count,
                SUM(CASE WHEN m.associated_message_type = 2000 THEN 1 ELSE 0 END) as heart_reactions,
                SUM(CASE WHEN m.associated_message_type = 2001 THEN 1 ELSE 0 END) as thumbs_up,
                SUM(CASE WHEN m.associated_message_type = 2003 THEN 1 ELSE 0 END) as haha,
                SUM(CASE WHEN m.cache_has_attachments = 1 THEN 1 ELSE 0 END) as attachment_count
            FROM message m
            JOIN handle h ON m.handle_id = h.ROWID
            WHERE m.date/1000000000 + 978307200 > \(Date().timeIntervalSince1970 - 30*24*60*60)
            GROUP BY h.id
            ORDER BY msg_count DESC
            LIMIT 50
            """

        var stmt: OpaquePointer?
        let prepareResult = sqlite3_prepare_v2(db, query, -1, &stmt, nil)
        guard prepareResult == SQLITE_OK else {
            let errorMsg = String(cString: sqlite3_errmsg(db))
            NSLog("[InsightsService] ERROR: Failed to prepare query: %@ (code: %d)", errorMsg, prepareResult)
            return
        }
        defer { sqlite3_finalize(stmt) }
        NSLog("[InsightsService] Query prepared successfully")

        var loadedContacts: [Contact] = []

        var rowCount = 0
        while sqlite3_step(stmt) == SQLITE_ROW {
            rowCount += 1
            guard let contactPtr = sqlite3_column_text(stmt, 0) else {
                NSLog("[InsightsService] WARNING: Null contact at row %d", rowCount)
                continue
            }
            let contactId = String(cString: contactPtr)
            let msgCount = Int(sqlite3_column_int(stmt, 1))
            let firstMsgTime = sqlite3_column_double(stmt, 2)
            let lastMsgTime = sqlite3_column_double(stmt, 3)
            let sentCount = Int(sqlite3_column_int(stmt, 4))
            let receivedCount = Int(sqlite3_column_int(stmt, 5))
            let heartReactions = Int(sqlite3_column_int(stmt, 6))
            let thumbsUp = Int(sqlite3_column_int(stmt, 7))
            let haha = Int(sqlite3_column_int(stmt, 8))
            let attachmentCount = Int(sqlite3_column_int(stmt, 9))

            var contact = Contact(
                id: contactId,
                phoneOrEmail: contactId,
                displayName: formatContactName(contactId),
                messageCount: msgCount,
                lastMessageDate: Date(timeIntervalSince1970: lastMsgTime),
                firstMessageDate: Date(timeIntervalSince1970: firstMsgTime),
                sentiment: 0 // TODO: compute from message content
            )
            contact.sentCount = sentCount
            contact.receivedCount = receivedCount
            contact.heartReactions = heartReactions
            contact.thumbsUpReactions = thumbsUp
            contact.hahaReactions = haha
            contact.attachmentCount = attachmentCount
            loadedContacts.append(contact)
        }

        NSLog("[InsightsService] Loaded %d contacts from %d rows", loadedContacts.count, rowCount)

        // Filter out blocked contacts (using normalized matching)
        let filteredContacts = loadedContacts.filter { !isBlocked($0.id) }
        NSLog("[InsightsService] After filtering blocked (%d blocked): %d contacts remain", blockedContacts.count, filteredContacts.count)
        contacts = filteredContacts
    }

    // MARK: - Load Time Patterns

    func loadTimePatterns() async {
        // Use real home directory, not sandbox container
        let realHome = FileManager.default.homeDirectoryForCurrentUser.path
        let chatDBPath = realHome + "/Library/Messages/chat.db"

        var db: OpaquePointer?
        guard sqlite3_open_v2(chatDBPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            return
        }
        defer { sqlite3_close(db) }

        // Hourly pattern
        let hourlyQuery = """
            SELECT
                strftime('%H', datetime(m.date/1000000000 + 978307200, 'unixepoch', 'localtime')) as hour,
                COUNT(*) as count
            FROM message m
            WHERE m.date/1000000000 + 978307200 > \(Date().timeIntervalSince1970 - 30*24*60*60)
            GROUP BY hour
            ORDER BY hour
            """

        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, hourlyQuery, -1, &stmt, nil) == SQLITE_OK {
            var pattern: [Int: Int] = [:]
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let hourStr = sqlite3_column_text(stmt, 0) {
                    let hour = Int(String(cString: hourStr)) ?? 0
                    let count = Int(sqlite3_column_int(stmt, 1))
                    pattern[hour] = count
                }
            }
            hourlyPattern = pattern
            sqlite3_finalize(stmt)
        }

        // Daily volume
        let dailyQuery = """
            SELECT
                date(datetime(m.date/1000000000 + 978307200, 'unixepoch', 'localtime')) as day,
                COUNT(*) as count
            FROM message m
            WHERE m.date/1000000000 + 978307200 > \(Date().timeIntervalSince1970 - 14*24*60*60)
            GROUP BY day
            ORDER BY day
            """

        if sqlite3_prepare_v2(db, dailyQuery, -1, &stmt, nil) == SQLITE_OK {
            var volume: [String: Int] = [:]
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let dayStr = sqlite3_column_text(stmt, 0) {
                    let day = String(cString: dayStr)
                    let count = Int(sqlite3_column_int(stmt, 1))
                    volume[day] = count
                }
            }
            dailyVolume = volume
            sqlite3_finalize(stmt)
        }

        // Day of week pattern
        let dowQuery = """
            SELECT
                strftime('%w', datetime(m.date/1000000000 + 978307200, 'unixepoch', 'localtime')) as day_num,
                COUNT(*) as count
            FROM message m
            WHERE m.date/1000000000 + 978307200 > \(Date().timeIntervalSince1970 - 30*24*60*60)
            GROUP BY day_num
            ORDER BY day_num
            """

        if sqlite3_prepare_v2(db, dowQuery, -1, &stmt, nil) == SQLITE_OK {
            var pattern: [Int: Int] = [:]
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let dayStr = sqlite3_column_text(stmt, 0) {
                    let day = Int(String(cString: dayStr)) ?? 0
                    let count = Int(sqlite3_column_int(stmt, 1))
                    pattern[day] = count
                }
            }
            dayOfWeekPattern = pattern
            sqlite3_finalize(stmt)
        }
    }

    // MARK: - Load Group Chats

    func loadGroupChats() async {
        let realHome = FileManager.default.homeDirectoryForCurrentUser.path
        let chatDBPath = realHome + "/Library/Messages/chat.db"

        var db: OpaquePointer?
        guard sqlite3_open_v2(chatDBPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return }
        defer { sqlite3_close(db) }

        let query = """
            SELECT
                c.ROWID as chat_id,
                COALESCE(c.display_name, c.chat_identifier) as chat_name,
                COUNT(*) as message_count,
                COUNT(DISTINCT m.handle_id) as participants
            FROM message m
            JOIN chat_message_join cmj ON m.ROWID = cmj.message_id
            JOIN chat c ON cmj.chat_id = c.ROWID
            WHERE m.date/1000000000 + 978307200 > \(Date().timeIntervalSince1970 - 30*24*60*60)
                AND c.style = 43
            GROUP BY c.ROWID
            ORDER BY message_count DESC
            LIMIT 20
            """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }

        var chats: [GroupChat] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let chatId = String(sqlite3_column_int64(stmt, 0))
            let name = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? "Group"
            let msgCount = Int(sqlite3_column_int(stmt, 2))
            let participants = Int(sqlite3_column_int(stmt, 3))

            chats.append(GroupChat(
                id: chatId,
                name: name,
                messageCount: msgCount,
                participantCount: participants
            ))
        }
        groupChats = chats
    }

    // MARK: - Load Unread Messages

    func loadUnreadMessages() async {
        let realHome = FileManager.default.homeDirectoryForCurrentUser.path
        let chatDBPath = realHome + "/Library/Messages/chat.db"

        var db: OpaquePointer?
        guard sqlite3_open_v2(chatDBPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return }
        defer { sqlite3_close(db) }

        let query = """
            SELECT
                h.id as contact,
                COUNT(*) as unread_count,
                MIN(m.date/1000000000 + 978307200) as oldest_unread
            FROM message m
            JOIN handle h ON m.handle_id = h.ROWID
            WHERE m.is_from_me = 0
                AND m.is_read = 0
                AND m.date/1000000000 + 978307200 > \(Date().timeIntervalSince1970 - 30*24*60*60)
            GROUP BY h.id
            ORDER BY unread_count DESC
            LIMIT 10
            """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }

        var unreads: [(contact: String, count: Int, oldestDate: Date)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let contactPtr = sqlite3_column_text(stmt, 0) else { continue }
            let contact = String(cString: contactPtr)

            // Skip blocked contacts
            if isBlocked(contact) { continue }

            let count = Int(sqlite3_column_int(stmt, 1))
            let oldestTime = sqlite3_column_double(stmt, 2)

            unreads.append((contact: contact, count: count, oldestDate: Date(timeIntervalSince1970: oldestTime)))
        }
        unreadMessages = unreads
    }

    // MARK: - Compute Wellbeing

    private func computeWellbeing() {
        NSLog("[InsightsService] computeWellbeing - contacts count: %d, hourlyPattern keys: %d", contacts.count, hourlyPattern.count)

        // Sleep hours: midnight to 5am
        let sleepHourMessages = (0...5).reduce(0) { $0 + (hourlyPattern[$1] ?? 0) }
        NSLog("[InsightsService] sleepHourMessages: %d", sleepHourMessages)

        // Support network: contacts with 50+ messages
        let supportNetworkSize = contacts.filter { $0.messageCount >= 50 }.count
        NSLog("[InsightsService] supportNetworkSize: %d (threshold: 50 msgs)", supportNetworkSize)

        // Sleep quality: fewer sleep-hour messages = better
        let sleepQuality = max(0, 100 - Double(sleepHourMessages) * 2)

        // Social connection: more support contacts = better
        let socialConnection = min(100, Double(supportNetworkSize) * 20)

        // Stress level: based on volume spikes
        let volumes = Array(dailyVolume.values)
        let avgVolume = volumes.isEmpty ? 0 : Double(volumes.reduce(0, +)) / Double(volumes.count)
        let maxVolume = Double(volumes.max() ?? 0)
        let stressLevel = avgVolume > 0 ? min(100, (maxVolume / avgVolume - 1) * 30) : 0

        let overall = (sleepQuality + socialConnection + (100 - stressLevel)) / 3

        wellbeingScore = WellbeingData(
            overall: overall,
            sleepQuality: sleepQuality,
            socialConnection: socialConnection,
            stressLevel: stressLevel,
            sleepHourMessages: sleepHourMessages,
            supportNetworkSize: supportNetworkSize
        )
        NSLog("[InsightsService] wellbeingScore SET - sleepHourMessages: %d, supportNetworkSize: %d", sleepHourMessages, supportNetworkSize)
    }

    // MARK: - Detect Insights

    private func detectInsights() {
        var insights: [Insight] = []

        // Sleep disruption
        if let wb = wellbeingScore, wb.sleepHourMessages > 50 {
            insights.append(Insight(
                type: .sleepDisruption,
                title: "Sleep Pattern Disruption",
                description: "\(wb.sleepHourMessages) messages sent during sleep hours (midnight-5am) in the past 30 days. Consider setting boundaries.",
                priority: wb.sleepHourMessages > 100 ? .high : .medium,
                date: Date()
            ))
        }

        // Volume spike detection
        let volumes = Array(dailyVolume.values)
        let avgVolume = volumes.isEmpty ? 0 : Double(volumes.reduce(0, +)) / Double(volumes.count)

        for (day, count) in dailyVolume {
            if Double(count) > avgVolume * 2.5 {
                insights.append(Insight(
                    type: .volumeSpike,
                    title: "Communication Spike",
                    description: "\(count) messages on \(day) - \(String(format: "%.1f", Double(count)/avgVolume))x your average. Something significant may have happened.",
                    priority: Double(count) > avgVolume * 4 ? .high : .medium,
                    date: Date()
                ))
            }
        }

        // Support network
        if let wb = wellbeingScore, wb.supportNetworkSize >= 3 {
            insights.append(Insight(
                type: .supportNetwork,
                title: "Strong Support Network",
                description: "You have \(wb.supportNetworkSize) close contacts you communicate with regularly. This is great for wellbeing!",
                priority: .low,
                date: Date()
            ))
        }

        recentInsights = insights.sorted { $0.priority.rawValue > $1.priority.rawValue }
    }

    // MARK: - Helpers

    private func formatContactName(_ contact: String) -> String? {
        if contact.hasPrefix("+1") && contact.count == 12 {
            let clean = contact.dropFirst(2)
            return "(\(clean.prefix(3))) \(clean.dropFirst(3).prefix(3))-\(clean.suffix(4))"
        }
        return nil
    }
}

// MARK: - Gemini Service

@MainActor
class GeminiService: ObservableObject {
    static let shared = GeminiService()

    @Published var apiKey: String? {
        didSet {
            UserDefaults.standard.set(apiKey, forKey: "gemini_api_key")
            // Sync with InsightsService
            InsightsService.shared.geminiAPIKey = apiKey
        }
    }

    @Published var isAnalyzing = false
    @Published var lastError: String?

    var hasKey: Bool {
        guard let key = apiKey else { return false }
        return !key.isEmpty
    }

    private init() {
        apiKey = UserDefaults.standard.string(forKey: "gemini_api_key")
    }

    // MARK: - Gemini Flash API

    struct GeminiResponse: Codable {
        let candidates: [Candidate]?
        let error: GeminiError?

        struct Candidate: Codable {
            let content: Content
        }

        struct Content: Codable {
            let parts: [Part]
        }

        struct Part: Codable {
            let text: String?
        }

        struct GeminiError: Codable {
            let message: String
        }
    }

    func analyzeRelationship(_ contact: InsightsService.Contact, messages: [String]) async -> String? {
        guard let key = apiKey, !key.isEmpty else {
            lastError = "No API key configured"
            return nil
        }

        isAnalyzing = true
        defer { isAnalyzing = false }

        let prompt = """
        Analyze this relationship based on messaging patterns:

        Contact: \(contact.displayName ?? contact.phoneOrEmail)
        Total messages: \(contact.messageCount)
        Sent: \(contact.sentCount), Received: \(contact.receivedCount)
        Heart reactions: \(contact.heartReactions)
        Days since last contact: \(contact.daysSinceContact)

        Recent messages (sample):
        \(messages.prefix(20).joined(separator: "\n"))

        Provide a brief, empathetic 2-3 sentence summary of this relationship's health and communication style.
        """

        return await callGemini(prompt: prompt)
    }

    func detectLifeEvents(recentMessages: [(contact: String, text: String, date: Date)]) async -> [String]? {
        guard let key = apiKey, !key.isEmpty else { return nil }

        isAnalyzing = true
        defer { isAnalyzing = false }

        let messagesText = recentMessages.prefix(50).map { "\($0.contact): \($0.text)" }.joined(separator: "\n")

        let prompt = """
        Analyze these recent messages and identify any significant life events mentioned:

        \(messagesText)

        Look for:
        - Job changes, promotions, layoffs
        - Moves, new homes
        - Relationships (engagements, breakups, births)
        - Health events
        - Travel plans
        - Graduations, achievements

        Return a JSON array of detected events, each with "event", "person", "date_mentioned". If none found, return [].
        """

        guard let response = await callGemini(prompt: prompt) else { return nil }

        // Parse simple events from response
        return [response]
    }

    private func callGemini(prompt: String) async -> String? {
        guard let key = apiKey else { return nil }

        let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.0-flash-exp:generateContent?key=\(key)")!

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "contents": [
                ["parts": [["text": prompt]]]
            ],
            "generationConfig": [
                "temperature": 0.7,
                "maxOutputTokens": 500
            ]
        ]

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, _) = try await URLSession.shared.data(for: request)

            let response = try JSONDecoder().decode(GeminiResponse.self, from: data)

            if let error = response.error {
                lastError = error.message
                return nil
            }

            return response.candidates?.first?.content.parts.first?.text
        } catch {
            lastError = error.localizedDescription
            NSLog("[GeminiService] Error: %@", error.localizedDescription)
            return nil
        }
    }
}
