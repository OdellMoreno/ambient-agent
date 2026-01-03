import Foundation
import SwiftData
import AmbientCore

/// Monitors Apple Notes using AppleScript
actor NotesMonitor: DataSourceMonitor {
    let sourceType: SourceType = .notes
    private(set) var isMonitoring = false

    private let context: ModelContext
    private var pollingTask: Task<Void, Never>?
    private var notesDirWatcher: DispatchSourceFileSystemObject?

    // Polling interval
    private let pollingInterval: TimeInterval = 60.0

    // Notes data path (for FSEvents)
    private let notesDataPath = NSHomeDirectory() + "/Library/Group Containers/group.com.apple.notes"

    // Track processed note IDs with their modification dates
    private var processedNotes: [String: Date] = [:]

    init(context: ModelContext) {
        self.context = context
    }

    // MARK: - DataSourceMonitor

    func startMonitoring() async throws {
        guard !isMonitoring else { return }

        AmbientLogger.monitors.info("Starting Notes monitor")
        isMonitoring = true

        // Load previously processed notes
        loadProcessedNotes()

        // Start polling
        pollingTask = Task { [weak self] in
            await self?.pollForChanges()
        }

        // Start watching notes directory for changes
        startNotesDirectoryWatcher()

        // Initial sync
        try await forceSync()
    }

    func stopMonitoring() async {
        AmbientLogger.monitors.info("Stopping Notes monitor")
        isMonitoring = false

        pollingTask?.cancel()
        pollingTask = nil

        notesDirWatcher?.cancel()
        notesDirWatcher = nil
    }

    func forceSync() async throws {
        AmbientLogger.monitors.info("Syncing Notes")

        let notes = try await fetchNotesViaAppleScript()

        var newOrUpdated = 0

        for note in notes {
            // Check if note is new or modified
            if let existingDate = processedNotes[note.id] {
                if note.modificationDate <= existingDate {
                    continue // No changes
                }
            }

            storeNote(note)
            processedNotes[note.id] = note.modificationDate
            newOrUpdated += 1
        }

        if newOrUpdated > 0 {
            try context.save()
            saveProcessedNotes()
            AmbientLogger.monitors.info("Synced \(newOrUpdated) new/updated note(s)")
        }

        logActivity(type: .syncCompleted, message: "Notes sync completed")
    }

    // MARK: - Polling

    private func pollForChanges() async {
        while isMonitoring {
            do {
                try await forceSync()
                try await Task.sleep(for: .seconds(pollingInterval))
            } catch {
                if !Task.isCancelled {
                    AmbientLogger.monitors.error("Notes polling error: \(error.localizedDescription)")
                }
                break
            }
        }
    }

    // MARK: - Directory Watching

    private func startNotesDirectoryWatcher() {
        guard FileManager.default.fileExists(atPath: notesDataPath) else {
            AmbientLogger.monitors.warning("Notes directory not found")
            return
        }

        let fileDescriptor = open(notesDataPath, O_EVTONLY)
        guard fileDescriptor >= 0 else {
            AmbientLogger.monitors.warning("Could not watch Notes directory")
            return
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileDescriptor,
            eventMask: [.write, .extend],
            queue: DispatchQueue.global(qos: .utility)
        )

        source.setEventHandler { [weak self] in
            Task {
                // Debounce - wait a bit for Notes to finish writing
                try? await Task.sleep(for: .seconds(2))
                try? await self?.forceSync()
            }
        }

        source.setCancelHandler {
            close(fileDescriptor)
        }

        source.resume()
        notesDirWatcher = source

        AmbientLogger.monitors.debug("Started Notes directory watcher")
    }

    // MARK: - AppleScript Integration

    private func fetchNotesViaAppleScript() async throws -> [NoteData] {
        let script = """
        tell application "Notes"
            set noteList to {}
            repeat with f in folders
                repeat with n in notes of f
                    try
                        set noteId to id of n
                        set noteName to name of n
                        set noteBody to body of n
                        set noteCreated to creation date of n
                        set noteModified to modification date of n
                        set folderName to name of f

                        set noteInfo to noteId & "|||" & noteName & "|||" & folderName & "|||" & noteCreated & "|||" & noteModified & "|||" & noteBody
                        set end of noteList to noteInfo
                    end try
                end repeat
            end repeat

            set AppleScript's text item delimiters to "\\n---NOTE_SEPARATOR---\\n"
            return noteList as text
        end tell
        """

        let result = try await runAppleScript(script)

        var notes: [NoteData] = []
        let noteStrings = result.components(separatedBy: "\n---NOTE_SEPARATOR---\n")

        for noteString in noteStrings {
            let parts = noteString.components(separatedBy: "|||")
            guard parts.count >= 6 else { continue }

            let noteId = parts[0]
            let name = parts[1]
            let folder = parts[2]
            let createdStr = parts[3]
            let modifiedStr = parts[4]
            let body = parts[5...].joined(separator: "|||") // Body might contain |||

            // Parse dates
            let dateFormatter = DateFormatter()
            dateFormatter.dateFormat = "EEEE, MMMM d, yyyy 'at' h:mm:ss a"
            dateFormatter.locale = Locale(identifier: "en_US")

            let creationDate = dateFormatter.date(from: createdStr) ?? Date()
            let modificationDate = dateFormatter.date(from: modifiedStr) ?? Date()

            notes.append(NoteData(
                id: noteId,
                name: name,
                body: body,
                folder: folder,
                creationDate: creationDate,
                modificationDate: modificationDate
            ))
        }

        AmbientLogger.monitors.debug("Fetched \(notes.count) notes via AppleScript")
        return notes
    }

    private func runAppleScript(_ script: String) async throws -> String {
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var error: NSDictionary?
                let appleScript = NSAppleScript(source: script)
                let result = appleScript?.executeAndReturnError(&error)

                if let error = error {
                    let errorMessage = error[NSAppleScript.errorMessage] as? String ?? "Unknown AppleScript error"
                    continuation.resume(throwing: NotesError.appleScriptError(errorMessage))
                    return
                }

                if let stringResult = result?.stringValue {
                    continuation.resume(returning: stringResult)
                } else {
                    continuation.resume(returning: "")
                }
            }
        }
    }

    // MARK: - Storage

    private func storeNote(_ note: NoteData) {
        let stableID = note.id
        let compositeKey = "\(SourceType.notes.rawValue):\(stableID)"

        // Check if already exists - if so, update it
        let predicate = #Predicate<RawItem> { $0.compositeKey == compositeKey }
        var descriptor = FetchDescriptor<RawItem>(predicate: predicate)
        descriptor.fetchLimit = 1

        // Create content structure
        let content: [String: Any] = [
            "noteId": note.id,
            "title": note.name,
            "body": cleanHTMLBody(note.body),
            "folder": note.folder,
            "creationDate": ISO8601DateFormatter().string(from: note.creationDate),
            "modificationDate": ISO8601DateFormatter().string(from: note.modificationDate)
        ]

        guard let contentData = try? JSONSerialization.data(withJSONObject: content) else {
            return
        }

        if let existing = try? context.fetch(descriptor).first {
            // Update existing
            existing.contentData = contentData
            existing.content = cleanHTMLBody(note.body)
            existing.fetchedAt = Date()
            existing.extractionVersion = nil // Mark for re-extraction
        } else {
            // Create new
            let rawItem = RawItem(
                sourceType: .notes,
                stableID: stableID,
                contentData: contentData,
                contentType: .note
            )
            rawItem.subject = note.name
            rawItem.content = cleanHTMLBody(note.body)
            rawItem.fetchedAt = Date()
            rawItem.metadata = ["folder": note.folder]

            context.insert(rawItem)
        }
    }

    private func cleanHTMLBody(_ body: String) -> String {
        var text = body

        // Remove HTML tags
        if let regex = try? NSRegularExpression(pattern: "<[^>]+>", options: .caseInsensitive) {
            text = regex.stringByReplacingMatches(
                in: text,
                range: NSRange(text.startIndex..., in: text),
                withTemplate: ""
            )
        }

        // Decode common HTML entities
        text = text.replacingOccurrences(of: "&nbsp;", with: " ")
        text = text.replacingOccurrences(of: "&amp;", with: "&")
        text = text.replacingOccurrences(of: "&lt;", with: "<")
        text = text.replacingOccurrences(of: "&gt;", with: ">")
        text = text.replacingOccurrences(of: "&quot;", with: "\"")
        text = text.replacingOccurrences(of: "&#39;", with: "'")

        // Clean up whitespace
        text = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)

        return text
    }

    // MARK: - Persistence

    private func loadProcessedNotes() {
        let url = getProcessedNotesFileURL()
        guard let data = try? Data(contentsOf: url),
              let notes = try? JSONDecoder().decode([String: Date].self, from: data) else {
            return
        }
        processedNotes = notes
    }

    private func saveProcessedNotes() {
        let url = getProcessedNotesFileURL()
        guard let data = try? JSONEncoder().encode(processedNotes) else { return }
        try? data.write(to: url)
    }

    private func getProcessedNotesFileURL() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("AmbientAgent", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("processed_notes.json")
    }

    // MARK: - Helpers

    private func logActivity(type: ActivityType, message: String) {
        let log = ActivityLog(type: type, message: message, sourceType: .notes)
        context.insert(log)
        try? context.save()
    }
}

// MARK: - Note Data Structure

private struct NoteData {
    let id: String
    let name: String
    let body: String
    let folder: String
    let creationDate: Date
    let modificationDate: Date
}

// MARK: - Errors

enum NotesError: Error {
    case appleScriptError(String)
    case notesNotAccessible
}
