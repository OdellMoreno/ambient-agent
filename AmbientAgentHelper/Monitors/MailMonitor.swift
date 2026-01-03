import Foundation
import SwiftData
import AmbientCore
import ScriptingBridge

// MARK: - Mail ScriptingBridge Protocols

@objc protocol MailApplication {
    @objc optional var accounts: SBElementArray { get }
    @objc optional var inbox: MailMailbox { get }
    @objc optional var name: String { get }
    @objc optional func checkForNewMail(_ forAccount: Any?)
}

@objc protocol MailAccount {
    @objc optional var mailboxes: SBElementArray { get }
    @objc optional var name: String { get }
    @objc optional var fullName: String { get }
}

@objc protocol MailMailbox {
    @objc optional var messages: SBElementArray { get }
    @objc optional var name: String { get }
    @objc optional var unreadCount: Int { get }
}

@objc protocol MailMessage {
    @objc optional var id: Int { get }
    @objc optional var messageId: String { get }
    @objc optional var subject: String { get }
    @objc optional var sender: String { get }
    @objc optional var dateReceived: Date { get }
    @objc optional var dateSent: Date { get }
    @objc optional var content: String { get }
    @objc optional var wasRepliedTo: Bool { get }
    @objc optional var wasForwarded: Bool { get }
    @objc optional var wasRedirected: Bool { get }
    @objc optional var readStatus: Bool { get }
    @objc optional var flaggedStatus: Bool { get }
    @objc optional var deletedStatus: Bool { get }
    @objc optional var junkMailStatus: Bool { get }
    @objc optional var allHeaders: String { get }
    @objc optional var toRecipients: SBElementArray { get }
    @objc optional var ccRecipients: SBElementArray { get }
}

@objc protocol MailRecipient {
    @objc optional var name: String { get }
    @objc optional var address: String { get }
}

extension SBApplication: MailApplication {}
extension SBObject: MailAccount, MailMailbox, MailMessage, MailRecipient {}

// MARK: - Mail Monitor

/// Monitors Apple Mail for new messages
actor MailMonitor: DataSourceMonitor {
    let sourceType: SourceType = .email
    private(set) var isMonitoring = false

    private let context: ModelContext
    private var pollingTask: Task<Void, Never>?
    private var mailDirWatcher: DispatchSourceFileSystemObject?

    // Polling interval (Mail doesn't have reliable notifications)
    private let pollingInterval: TimeInterval = 30.0

    // Mail database paths (for FSEvents)
    private let mailDataPath = NSHomeDirectory() + "/Library/Mail"

    // Track processed message IDs
    private var processedMessageIDs: Set<String> = []

    // How far back to look for messages (days)
    private let lookbackDays: Int = 7

    init(context: ModelContext) {
        self.context = context
    }

    // MARK: - DataSourceMonitor

    func startMonitoring() async throws {
        guard !isMonitoring else { return }

        AmbientLogger.monitors.info("Starting Mail monitor")
        isMonitoring = true

        // Load previously processed message IDs
        loadProcessedMessageIDs()

        // Start polling
        pollingTask = Task { [weak self] in
            await self?.pollForNewMail()
        }

        // Start watching mail directory for changes
        startMailDirectoryWatcher()

        // Initial sync
        try await forceSync()
    }

    func stopMonitoring() async {
        AmbientLogger.monitors.info("Stopping Mail monitor")
        isMonitoring = false

        pollingTask?.cancel()
        pollingTask = nil

        mailDirWatcher?.cancel()
        mailDirWatcher = nil
    }

    func forceSync() async throws {
        AmbientLogger.monitors.info("Syncing Mail messages")

        guard let mail = SBApplication(bundleIdentifier: "com.apple.mail") as? MailApplication else {
            AmbientLogger.monitors.warning("Could not connect to Mail (may not be running)")
            return
        }

        // Trigger check for new mail
        mail.checkForNewMail?(nil)

        // Small delay for mail to load
        try? await Task.sleep(for: .seconds(1))

        // Get messages from inbox
        try await syncInbox(mail)

        logActivity(type: .syncCompleted, message: "Mail sync completed")
    }

    // MARK: - Polling

    private func pollForNewMail() async {
        while isMonitoring {
            do {
                try await forceSync()
                try await Task.sleep(for: .seconds(pollingInterval))
            } catch {
                if !Task.isCancelled {
                    AmbientLogger.monitors.error("Mail polling error: \(error.localizedDescription)")
                }
                break
            }
        }
    }

    // MARK: - Mail Directory Watching

    private func startMailDirectoryWatcher() {
        // Watch the Mail V9/V10 directory for changes
        let mailVersionPath = mailDataPath + "/V9"  // macOS Ventura+
        let watchPath = FileManager.default.fileExists(atPath: mailVersionPath) ? mailVersionPath : mailDataPath

        let fileDescriptor = open(watchPath, O_EVTONLY)
        guard fileDescriptor >= 0 else {
            AmbientLogger.monitors.warning("Could not watch Mail directory")
            return
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileDescriptor,
            eventMask: [.write, .extend],
            queue: DispatchQueue.global(qos: .utility)
        )

        source.setEventHandler { [weak self] in
            Task {
                try? await self?.forceSync()
            }
        }

        source.setCancelHandler {
            close(fileDescriptor)
        }

        source.resume()
        mailDirWatcher = source

        AmbientLogger.monitors.debug("Started Mail directory watcher")
    }

    // MARK: - Inbox Sync

    private func syncInbox(_ mail: MailApplication) async throws {
        // Get inbox messages
        guard let inbox = mail.inbox,
              let messages = inbox.messages else {
            AmbientLogger.monitors.debug("No inbox or messages found")
            return
        }

        // Calculate cutoff date
        let cutoffDate = Calendar.current.date(byAdding: .day, value: -lookbackDays, to: Date()) ?? Date()

        var newMessages = 0

        for message in messages {
            guard let mailMessage = message as? MailMessage else { continue }

            // Get message ID for deduplication
            let messageId = mailMessage.messageId ?? "msg:\(mailMessage.id ?? 0)"

            // Skip if already processed
            if processedMessageIDs.contains(messageId) {
                continue
            }

            // Skip if too old
            guard let dateReceived = mailMessage.dateReceived,
                  dateReceived >= cutoffDate else {
                continue
            }

            // Skip junk mail
            if mailMessage.junkMailStatus == true {
                continue
            }

            // Skip deleted
            if mailMessage.deletedStatus == true {
                continue
            }

            // Store the message
            storeMessage(mailMessage, messageId: messageId)
            processedMessageIDs.insert(messageId)
            newMessages += 1
        }

        if newMessages > 0 {
            try context.save()
            saveProcessedMessageIDs()
            AmbientLogger.monitors.info("Synced \(newMessages) new Mail message(s)")
        }
    }

    private func storeMessage(_ message: MailMessage, messageId: String) {
        let stableID = messageId
        let compositeKey = "\(SourceType.email.rawValue):\(stableID)"

        // Check if already exists in Raw Store
        let predicate = #Predicate<RawItem> { $0.compositeKey == compositeKey }
        var descriptor = FetchDescriptor<RawItem>(predicate: predicate)
        descriptor.fetchLimit = 1

        if let _ = try? context.fetch(descriptor).first {
            return
        }

        // Extract recipients
        var toRecipients: [[String: String]] = []
        if let recipients = message.toRecipients {
            for recipient in recipients {
                guard let mailRecipient = recipient as? MailRecipient else { continue }
                var recipientDict: [String: String] = [:]
                if let name = mailRecipient.name { recipientDict["name"] = name }
                if let address = mailRecipient.address { recipientDict["email"] = address }
                if !recipientDict.isEmpty { toRecipients.append(recipientDict) }
            }
        }

        var ccRecipients: [[String: String]] = []
        if let recipients = message.ccRecipients {
            for recipient in recipients {
                guard let mailRecipient = recipient as? MailRecipient else { continue }
                var recipientDict: [String: String] = [:]
                if let name = mailRecipient.name { recipientDict["name"] = name }
                if let address = mailRecipient.address { recipientDict["email"] = address }
                if !recipientDict.isEmpty { ccRecipients.append(recipientDict) }
            }
        }

        // Create content structure
        var content: [String: Any] = [
            "messageId": messageId,
            "subject": message.subject ?? "(No Subject)",
            "sender": message.sender ?? "",
            "body": message.content ?? "",
            "to": toRecipients,
            "cc": ccRecipients
        ]

        if let dateReceived = message.dateReceived {
            content["dateReceived"] = ISO8601DateFormatter().string(from: dateReceived)
        }

        if let dateSent = message.dateSent {
            content["dateSent"] = ISO8601DateFormatter().string(from: dateSent)
        }

        content["isRead"] = message.readStatus ?? false
        content["isFlagged"] = message.flaggedStatus ?? false
        content["wasRepliedTo"] = message.wasRepliedTo ?? false

        guard let contentData = try? JSONSerialization.data(withJSONObject: content) else {
            return
        }

        let rawItem = RawItem(
            sourceType: .email,
            stableID: stableID,
            contentData: contentData,
            contentType: .email
        )
        rawItem.subject = message.subject
        rawItem.fetchedAt = message.dateReceived ?? Date()

        // Store sender as participant
        if let sender = message.sender {
            rawItem.participants = [sender]
        }

        context.insert(rawItem)
    }

    // MARK: - Persistence for Processed IDs

    private func loadProcessedMessageIDs() {
        let url = getProcessedIDsFileURL()
        guard let data = try? Data(contentsOf: url),
              let ids = try? JSONDecoder().decode(Set<String>.self, from: data) else {
            return
        }
        processedMessageIDs = ids
    }

    private func saveProcessedMessageIDs() {
        let url = getProcessedIDsFileURL()
        guard let data = try? JSONEncoder().encode(processedMessageIDs) else { return }
        try? data.write(to: url)
    }

    private func getProcessedIDsFileURL() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("AmbientAgent", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("processed_mail_ids.json")
    }

    // MARK: - Helpers

    private func logActivity(type: ActivityType, message: String) {
        let log = ActivityLog(type: type, message: message, sourceType: .email)
        context.insert(log)
        try? context.save()
    }
}
