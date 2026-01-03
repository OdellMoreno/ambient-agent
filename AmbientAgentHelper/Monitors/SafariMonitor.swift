import Foundation
import SwiftData
import AmbientCore
import ScriptingBridge
import SQLite3

// MARK: - Safari ScriptingBridge Protocol

@objc protocol SafariApplication {
    @objc optional var windows: SBElementArray { get }
    @objc optional var name: String { get }
}

@objc protocol SafariWindow {
    @objc optional var tabs: SBElementArray { get }
    @objc optional var currentTab: SafariTab { get }
    @objc optional var name: String { get }
    @objc optional var index: Int { get }
}

@objc protocol SafariTab {
    @objc optional var URL: String { get }
    @objc optional var name: String { get }
    @objc optional var source: String { get }
    @objc optional var text: String { get }
}

extension SBApplication: SafariApplication {}
extension SBObject: SafariWindow, SafariTab {}

// MARK: - Safari Monitor

/// Monitors Safari for tab changes and history updates
actor SafariMonitor: DataSourceMonitor {
    let sourceType: SourceType = .safari
    private(set) var isMonitoring = false

    private let context: ModelContext
    private var pollingTask: Task<Void, Never>?
    private var historyWatcher: DispatchSourceFileSystemObject?

    // Track previously seen tabs to detect changes
    private var previousTabURLs: Set<String> = []

    // Safari history database path
    private let historyDBPath = NSHomeDirectory() + "/Library/Safari/History.db"

    // Polling interval for tabs (Safari doesn't have change notifications)
    private let tabPollingInterval: TimeInterval = 2.0

    // Track last history timestamp
    private var lastHistoryTimestamp: Double = 0

    init(context: ModelContext) {
        self.context = context
    }

    // MARK: - DataSourceMonitor

    func startMonitoring() async throws {
        guard !isMonitoring else { return }

        AmbientLogger.monitors.info("Starting Safari monitor")
        isMonitoring = true

        // Start tab polling
        pollingTask = Task { [weak self] in
            await self?.pollSafariTabs()
        }

        // Start history file watching
        startHistoryWatcher()

        // Initial sync
        try await forceSync()
    }

    func stopMonitoring() async {
        AmbientLogger.monitors.info("Stopping Safari monitor")
        isMonitoring = false

        pollingTask?.cancel()
        pollingTask = nil

        historyWatcher?.cancel()
        historyWatcher = nil
    }

    func forceSync() async throws {
        AmbientLogger.monitors.info("Syncing Safari data")

        await syncCurrentTabs()
        try await syncHistory()

        logActivity(type: .syncCompleted, message: "Safari sync completed")
    }

    // MARK: - Tab Monitoring

    private func pollSafariTabs() async {
        while isMonitoring {
            await syncCurrentTabs()

            do {
                try await Task.sleep(for: .seconds(tabPollingInterval))
            } catch {
                break
            }
        }
    }

    private func syncCurrentTabs() async {
        guard let safari = SBApplication(bundleIdentifier: "com.apple.Safari") as? SafariApplication else {
            AmbientLogger.monitors.debug("Could not connect to Safari (may not be running)")
            return
        }

        var currentTabURLs: Set<String> = []
        var tabs: [(url: String, title: String)] = []

        // Get all tabs from all windows
        if let windows = safari.windows {
            for window in windows {
                guard let safariWindow = window as? SafariWindow,
                      let windowTabs = safariWindow.tabs else { continue }

                for tab in windowTabs {
                    guard let safariTab = tab as? SafariTab,
                          let urlString = safariTab.URL,
                          let title = safariTab.name,
                          !urlString.isEmpty else { continue }

                    currentTabURLs.insert(urlString)
                    tabs.append((url: urlString, title: title))
                }
            }
        }

        // Find newly opened tabs
        let newTabs = currentTabURLs.subtracting(previousTabURLs)
        previousTabURLs = currentTabURLs

        // Store new tab visits to Raw Store
        if !newTabs.isEmpty {
            for (url, title) in tabs where newTabs.contains(url) {
                storeTabVisit(url: url, title: title)
            }

            try? context.save()
            AmbientLogger.monitors.debug("Detected \(newTabs.count) new Safari tab(s)")
        }
    }

    private func storeTabVisit(url: String, title: String) {
        // Skip internal Safari URLs
        guard !url.hasPrefix("safari-"),
              !url.hasPrefix("file://"),
              !url.hasPrefix("about:") else { return }

        // Skip common non-actionable pages (search results)
        let skipPatterns = ["google.com/search", "duckduckgo.com/?q", "bing.com/search"]
        if skipPatterns.contains(where: { url.contains($0) }) {
            return
        }

        let stableID = "tab:\(url.hashValue)"
        let compositeKey = "\(SourceType.safari.rawValue):\(stableID)"

        // Check if already exists
        let predicate = #Predicate<RawItem> { $0.compositeKey == compositeKey }
        var descriptor = FetchDescriptor<RawItem>(predicate: predicate)
        descriptor.fetchLimit = 1

        if let _ = try? context.fetch(descriptor).first {
            return // Already have this URL
        }

        // Create content structure
        let content: [String: Any] = [
            "url": url,
            "title": title,
            "visitedAt": ISO8601DateFormatter().string(from: Date()),
            "source": "tab"
        ]

        guard let contentData = try? JSONSerialization.data(withJSONObject: content) else {
            return
        }

        let rawItem = RawItem(
            sourceType: .safari,
            stableID: stableID,
            contentData: contentData,
            contentType: .webPage
        )
        rawItem.subject = title
        rawItem.metadata = ["url": url]

        context.insert(rawItem)
    }

    // MARK: - History Monitoring

    private func startHistoryWatcher() {
        let fileDescriptor = open(historyDBPath, O_EVTONLY)
        guard fileDescriptor >= 0 else {
            AmbientLogger.monitors.warning("Could not open Safari history for watching (needs Full Disk Access)")
            return
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileDescriptor,
            eventMask: [.write, .extend],
            queue: DispatchQueue.global(qos: .utility)
        )

        source.setEventHandler { [weak self] in
            Task {
                try? await self?.syncHistory()
            }
        }

        source.setCancelHandler {
            close(fileDescriptor)
        }

        source.resume()
        historyWatcher = source

        AmbientLogger.monitors.debug("Started Safari history watcher")
    }

    private func syncHistory() async throws {
        guard FileManager.default.fileExists(atPath: historyDBPath) else {
            AmbientLogger.monitors.warning("Safari history database not found")
            return
        }

        // Open database in read-only mode
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(historyDBPath, &db, flags, nil) == SQLITE_OK else {
            AmbientLogger.monitors.warning("Could not open Safari history database (needs Full Disk Access)")
            return
        }
        defer { sqlite3_close(db) }

        // Query recent history items
        // Safari stores time as Core Foundation absolute time (seconds since Jan 1, 2001)
        let query = """
            SELECT history_items.url, history_visits.title, history_visits.visit_time
            FROM history_visits
            INNER JOIN history_items ON history_visits.history_item = history_items.id
            WHERE history_visits.visit_time > ?
            ORDER BY history_visits.visit_time ASC
            LIMIT 100
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else {
            AmbientLogger.monitors.error("Failed to prepare Safari history query")
            return
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_double(statement, 1, lastHistoryTimestamp)

        var newItems = 0
        var latestTime = lastHistoryTimestamp

        while sqlite3_step(statement) == SQLITE_ROW {
            guard let urlPtr = sqlite3_column_text(statement, 0) else { continue }
            let url = String(cString: urlPtr)

            let title: String
            if let titlePtr = sqlite3_column_text(statement, 1) {
                title = String(cString: titlePtr)
            } else {
                title = url
            }

            let visitTime = sqlite3_column_double(statement, 2)
            let visitDate = Date(timeIntervalSinceReferenceDate: visitTime)

            // Update latest time
            if visitTime > latestTime {
                latestTime = visitTime
            }

            // Store the history item
            storeHistoryItem(url: url, title: title, visitDate: visitDate)
            newItems += 1
        }

        if newItems > 0 {
            lastHistoryTimestamp = latestTime
            try context.save()
            AmbientLogger.monitors.info("Synced \(newItems) Safari history item(s)")
        }
    }

    private func storeHistoryItem(url: String, title: String, visitDate: Date) {
        // Skip internal URLs
        guard !url.hasPrefix("safari-"),
              !url.hasPrefix("file://"),
              !url.hasPrefix("about:") else { return }

        let stableID = "history:\(url.hashValue):\(Int(visitDate.timeIntervalSince1970))"
        let compositeKey = "\(SourceType.safari.rawValue):\(stableID)"

        // Check if already exists
        let predicate = #Predicate<RawItem> { $0.compositeKey == compositeKey }
        var descriptor = FetchDescriptor<RawItem>(predicate: predicate)
        descriptor.fetchLimit = 1

        if let _ = try? context.fetch(descriptor).first {
            return
        }

        // Create content
        let content: [String: Any] = [
            "url": url,
            "title": title,
            "visitedAt": ISO8601DateFormatter().string(from: visitDate),
            "source": "history"
        ]

        guard let contentData = try? JSONSerialization.data(withJSONObject: content) else {
            return
        }

        let rawItem = RawItem(
            sourceType: .safari,
            stableID: stableID,
            contentData: contentData,
            contentType: .webPage
        )
        rawItem.subject = title
        rawItem.metadata = ["url": url]
        rawItem.fetchedAt = visitDate

        context.insert(rawItem)
    }

    // MARK: - Helpers

    private func logActivity(type: ActivityType, message: String) {
        let log = ActivityLog(type: type, message: message, sourceType: .safari)
        context.insert(log)
        try? context.save()
    }
}

// MARK: - Page Content Fetcher

/// Fetches and extracts text content from web pages for extraction
actor SafariPageContentFetcher {

    /// Fetch text content from the current Safari tab
    func fetchCurrentTabContent() async -> (url: String, title: String, content: String)? {
        guard let safari = SBApplication(bundleIdentifier: "com.apple.Safari") as? SafariApplication,
              let windows = safari.windows,
              let firstWindow = windows.firstObject as? SafariWindow,
              let currentTab = firstWindow.currentTab,
              let url = currentTab.URL,
              let title = currentTab.name else {
            return nil
        }

        // Get page text (requires Automation permission)
        let text = currentTab.text ?? ""

        return (url: url, title: title, content: text)
    }

    /// Fetch content from a specific URL
    func fetchPageContent(url: URL) async throws -> String {
        let (data, _) = try await URLSession.shared.data(from: url)

        guard let html = String(data: data, encoding: .utf8) else {
            throw SafariError.invalidContent
        }

        return extractTextFromHTML(html)
    }

    private func extractTextFromHTML(_ html: String) -> String {
        var text = html

        // Remove script and style tags with content
        let patterns = [
            "<script[^>]*>.*?</script>",
            "<style[^>]*>.*?</style>",
            "<[^>]+>",  // All other tags
        ]

        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) {
                text = regex.stringByReplacingMatches(
                    in: text,
                    range: NSRange(text.startIndex..., in: text),
                    withTemplate: " "
                )
            }
        }

        // Decode HTML entities
        text = text.replacingOccurrences(of: "&nbsp;", with: " ")
        text = text.replacingOccurrences(of: "&amp;", with: "&")
        text = text.replacingOccurrences(of: "&lt;", with: "<")
        text = text.replacingOccurrences(of: "&gt;", with: ">")
        text = text.replacingOccurrences(of: "&quot;", with: "\"")

        // Clean up whitespace
        text = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // Truncate if too long
        if text.count > 10000 {
            text = String(text.prefix(10000))
        }

        return text
    }
}

enum SafariError: Error {
    case notAccessible
    case invalidContent
    case historyNotAvailable
}
