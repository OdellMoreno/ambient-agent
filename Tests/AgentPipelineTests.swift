import XCTest
import Foundation
@testable import AmbientCore

/// Tests for the three-agent pipeline data structures and parsing logic
final class AgentPipelineTests: XCTestCase {

    // MARK: - DailyMessageBatch Tests

    func testDailyMessageBatchFormatting() {
        let messages = [
            MessageItem(content: "Hey, want to grab coffee tomorrow?", sender: "Sarah", timestamp: Date(), isFromMe: false),
            MessageItem(content: "Sure! How about 2pm at Blue Bottle?", sender: nil, timestamp: Date(), isFromMe: true),
            MessageItem(content: "Perfect, see you then!", sender: "Sarah", timestamp: Date(), isFromMe: false)
        ]

        let conversation = ConversationThread(
            threadID: "thread-123",
            participants: ["Sarah"],
            messages: messages
        )

        let batch = DailyMessageBatch(
            date: Date(),
            conversations: [conversation]
        )

        XCTAssertEqual(batch.totalMessageCount, 3)

        let formatted = batch.formattedForLLM
        XCTAssertTrue(formatted.contains("Conversation with Sarah"))
        XCTAssertTrue(formatted.contains("Hey, want to grab coffee tomorrow?"))
        XCTAssertTrue(formatted.contains("Perfect, see you then!"))
    }

    func testEmptyBatch() {
        let batch = DailyMessageBatch(date: Date(), conversations: [])
        XCTAssertEqual(batch.totalMessageCount, 0)
        XCTAssertTrue(batch.formattedForLLM.isEmpty)
    }

    func testMultipleConversations() {
        let conv1 = ConversationThread(
            threadID: "thread-1",
            participants: ["Alice"],
            messages: [MessageItem(content: "Hi", sender: "Alice", timestamp: Date(), isFromMe: false)]
        )
        let conv2 = ConversationThread(
            threadID: "thread-2",
            participants: ["Bob"],
            messages: [MessageItem(content: "Hello", sender: "Bob", timestamp: Date(), isFromMe: false)]
        )

        let batch = DailyMessageBatch(date: Date(), conversations: [conv1, conv2])
        XCTAssertEqual(batch.totalMessageCount, 2)

        let formatted = batch.formattedForLLM
        XCTAssertTrue(formatted.contains("Conversation with Alice"))
        XCTAssertTrue(formatted.contains("Conversation with Bob"))
    }

    // MARK: - ExtractedItem Tests

    func testExtractedItemTypes() {
        let event = ExtractedItem(
            title: "Coffee with Sarah",
            itemType: .event,
            roughDate: "tomorrow",
            roughTime: "2pm",
            people: ["Sarah"],
            location: "Blue Bottle",
            confidence: "high",
            context: "Explicit plan made in conversation"
        )

        XCTAssertEqual(event.itemType, .event)
        XCTAssertEqual(event.title, "Coffee with Sarah")
        XCTAssertEqual(event.roughDate, "tomorrow")
        XCTAssertEqual(event.people, ["Sarah"])

        let task = ExtractedItem(
            title: "Send report to John",
            itemType: .task,
            roughDate: "Friday",
            roughTime: nil,
            people: ["John"],
            location: nil,
            confidence: "medium",
            context: "Mentioned needing to send"
        )

        XCTAssertEqual(task.itemType, .task)
        XCTAssertNil(task.roughTime)
    }

    // MARK: - FormattedEvent Tests

    func testFormattedEventCreation() {
        let startDate = Date()
        let endDate = Calendar.current.date(byAdding: .hour, value: 1, to: startDate)!

        let event = FormattedEvent(
            title: "Team Meeting",
            startDate: startDate,
            endDate: endDate,
            isAllDay: false,
            location: "Conference Room A",
            attendees: ["Alice", "Bob", "Charlie"],
            notes: "Quarterly review",
            confidence: .high
        )

        XCTAssertEqual(event.title, "Team Meeting")
        XCTAssertFalse(event.isAllDay)
        XCTAssertEqual(event.attendees.count, 3)
        XCTAssertEqual(event.confidence, .high)
    }

    func testAllDayEvent() {
        let event = FormattedEvent(
            title: "Dad's Birthday",
            startDate: Date(),
            endDate: nil,
            isAllDay: true,
            location: nil,
            attendees: [],
            notes: nil,
            confidence: .medium
        )

        XCTAssertTrue(event.isAllDay)
        XCTAssertNil(event.endDate)
    }

    // MARK: - FormattedTask Tests

    func testFormattedTaskCreation() {
        let dueDate = Calendar.current.date(byAdding: .day, value: 3, to: Date())

        let task = FormattedTask(
            title: "Finish quarterly report",
            dueDate: dueDate,
            priority: .high,
            assignee: "Me",
            notes: "Due before the meeting",
            confidence: .high
        )

        XCTAssertEqual(task.title, "Finish quarterly report")
        XCTAssertEqual(task.priority, .high)
        XCTAssertNotNil(task.dueDate)
    }

    func testTaskWithoutDueDate() {
        let task = FormattedTask(
            title: "Look into new framework",
            dueDate: nil,
            priority: .low,
            assignee: nil,
            notes: nil,
            confidence: .low
        )

        XCTAssertNil(task.dueDate)
        XCTAssertNil(task.assignee)
        XCTAssertEqual(task.priority, .low)
    }

    // MARK: - DailyStory Tests

    func testDailyStoryCreation() {
        let story = DailyStory(
            date: Date(),
            narrative: "The user discussed meeting Sarah for coffee. They agreed on Tuesday at 2pm at Blue Bottle.",
            keyPeople: ["Sarah"],
            conversationCount: 1
        )

        XCTAssertEqual(story.conversationCount, 1)
        XCTAssertTrue(story.narrative.contains("coffee"))
        XCTAssertEqual(story.keyPeople, ["Sarah"])
    }

    // MARK: - JSON Parsing Tests

    func testExtractorJSONParsing() {
        let jsonString = """
        [
            {
                "title": "Coffee with Sarah",
                "type": "event",
                "rough_date": "tomorrow",
                "rough_time": "2pm",
                "people": ["Sarah"],
                "location": "Blue Bottle",
                "confidence": "high",
                "context": "Explicit plan"
            },
            {
                "title": "Send report",
                "type": "task",
                "rough_date": "Friday",
                "rough_time": null,
                "people": ["John"],
                "location": null,
                "confidence": "medium",
                "context": "Action item mentioned"
            }
        ]
        """

        let items = parseExtractedItemsJSON(jsonString)
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0].itemType, .event)
        XCTAssertEqual(items[1].itemType, .task)
        XCTAssertEqual(items[0].title, "Coffee with Sarah")
        XCTAssertEqual(items[1].roughDate, "Friday")
    }

    func testExtractorJSONWithMarkdownCodeBlock() {
        let jsonString = """
        ```json
        [
            {
                "title": "Meeting",
                "type": "event",
                "rough_date": "Monday",
                "rough_time": "10am",
                "people": [],
                "location": null,
                "confidence": "high",
                "context": null
            }
        ]
        ```
        """

        let items = parseExtractedItemsJSON(jsonString)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].title, "Meeting")
    }

    func testFormatterJSONParsing() {
        // Using ISO8601 format with timezone
        let jsonString = """
        {
            "events": [
                {
                    "title": "Coffee with Sarah",
                    "start_date": "2025-01-02T14:00:00Z",
                    "end_date": "2025-01-02T15:00:00Z",
                    "is_all_day": false,
                    "location": "Blue Bottle",
                    "attendees": ["Sarah"],
                    "notes": "Casual catch-up",
                    "confidence": "high"
                }
            ],
            "tasks": [
                {
                    "title": "Send report to John",
                    "due_date": "2025-01-03T17:00:00Z",
                    "priority": "high",
                    "assignee": "Me",
                    "notes": null,
                    "confidence": "medium"
                }
            ]
        }
        """

        let (events, tasks) = parseFormattedItemsJSON(jsonString)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(tasks.count, 1)
        XCTAssertEqual(events[0].title, "Coffee with Sarah")
        XCTAssertEqual(events[0].location, "Blue Bottle")
        XCTAssertEqual(tasks[0].title, "Send report to John")
        XCTAssertEqual(tasks[0].priority, .high)
    }

    func testEmptyFormatterJSON() {
        let jsonString = """
        {
            "events": [],
            "tasks": []
        }
        """

        let (events, tasks) = parseFormattedItemsJSON(jsonString)
        XCTAssertTrue(events.isEmpty)
        XCTAssertTrue(tasks.isEmpty)
    }

    // MARK: - Helper Functions for Testing

    private func parseExtractedItemsJSON(_ jsonString: String) -> [ExtractedItem] {
        var cleaned = jsonString.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasPrefix("```json") {
            cleaned = String(cleaned.dropFirst(7))
        }
        if cleaned.hasPrefix("```") {
            cleaned = String(cleaned.dropFirst(3))
        }
        if cleaned.hasSuffix("```") {
            cleaned = String(cleaned.dropLast(3))
        }
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)

        guard let data = cleaned.data(using: .utf8) else {
            return []
        }

        struct RawItem: Decodable {
            let title: String
            let type: String
            let rough_date: String?
            let rough_time: String?
            let people: [String]?
            let location: String?
            let confidence: String
            let context: String?
        }

        guard let items = try? JSONDecoder().decode([RawItem].self, from: data) else {
            return []
        }

        return items.map { raw in
            ExtractedItem(
                title: raw.title,
                itemType: raw.type == "task" ? .task : .event,
                roughDate: raw.rough_date,
                roughTime: raw.rough_time,
                people: raw.people ?? [],
                location: raw.location,
                confidence: raw.confidence,
                context: raw.context
            )
        }
    }

    private func parseFormattedItemsJSON(_ jsonString: String) -> (events: [FormattedEvent], tasks: [FormattedTask]) {
        var cleaned = jsonString.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasPrefix("```json") {
            cleaned = String(cleaned.dropFirst(7))
        }
        if cleaned.hasPrefix("```") {
            cleaned = String(cleaned.dropFirst(3))
        }
        if cleaned.hasSuffix("```") {
            cleaned = String(cleaned.dropLast(3))
        }
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)

        guard let data = cleaned.data(using: .utf8) else {
            return ([], [])
        }

        struct RawOutput: Decodable {
            struct RawEvent: Decodable {
                let title: String
                let start_date: String
                let end_date: String?
                let is_all_day: Bool?
                let location: String?
                let attendees: [String]?
                let notes: String?
                let confidence: String?
            }
            struct RawTask: Decodable {
                let title: String
                let due_date: String?
                let priority: String?
                let assignee: String?
                let notes: String?
                let confidence: String?
            }
            let events: [RawEvent]?
            let tasks: [RawTask]?
        }

        guard let output = try? JSONDecoder().decode(RawOutput.self, from: data) else {
            return ([], [])
        }

        let iso8601 = ISO8601DateFormatter()
        iso8601.formatOptions = [.withInternetDateTime]

        func parseDate(_ string: String) -> Date? {
            iso8601.date(from: string)
        }

        func parsePriority(_ str: String) -> TaskPriority {
            switch str.lowercased() {
            case "urgent": return .urgent
            case "high": return .high
            case "medium": return .medium
            case "low": return .low
            default: return .none
            }
        }

        let events = (output.events ?? []).compactMap { raw -> FormattedEvent? in
            guard let startDate = parseDate(raw.start_date) else { return nil }

            return FormattedEvent(
                title: raw.title,
                startDate: startDate,
                endDate: raw.end_date.flatMap { parseDate($0) },
                isAllDay: raw.is_all_day ?? false,
                location: raw.location,
                attendees: raw.attendees ?? [],
                notes: raw.notes,
                confidence: ExtractionConfidence(rawValue: raw.confidence ?? "medium") ?? .medium
            )
        }

        let tasks = (output.tasks ?? []).map { raw in
            FormattedTask(
                title: raw.title,
                dueDate: raw.due_date.flatMap { parseDate($0) },
                priority: parsePriority(raw.priority ?? "medium"),
                assignee: raw.assignee,
                notes: raw.notes,
                confidence: ExtractionConfidence(rawValue: raw.confidence ?? "medium") ?? .medium
            )
        }

        return (events, tasks)
    }
}

// MARK: - Date Context Tests

final class DateContextTests: XCTestCase {

    func testDateContextGeneration() {
        let calendar = Calendar.current
        let dateFormatter = DateFormatter()

        // Create a reference date (Monday)
        var components = DateComponents()
        components.year = 2025
        components.month = 1
        components.day = 6  // Monday Jan 6, 2025
        components.hour = 10

        guard let referenceDate = calendar.date(from: components) else {
            XCTFail("Could not create reference date")
            return
        }

        let context = buildDateContext(referenceDate: referenceDate)

        // Verify today is included
        XCTAssertTrue(context.contains("2025-01-06"))
        XCTAssertTrue(context.contains("Monday"))
        XCTAssertTrue(context.contains("today"))

        // Verify tomorrow is included
        XCTAssertTrue(context.contains("2025-01-07"))
        XCTAssertTrue(context.contains("tomorrow"))

        // Verify next week references
        XCTAssertTrue(context.contains("next Tuesday"))
        XCTAssertTrue(context.contains("next Wednesday"))
    }

    func testWeekendDateContext() {
        let calendar = Calendar.current

        // Create a Saturday
        var components = DateComponents()
        components.year = 2025
        components.month = 1
        components.day = 4  // Saturday Jan 4, 2025
        components.hour = 10

        guard let referenceDate = calendar.date(from: components) else {
            XCTFail("Could not create reference date")
            return
        }

        let context = buildDateContext(referenceDate: referenceDate)

        XCTAssertTrue(context.contains("Saturday"))
        XCTAssertTrue(context.contains("2025-01-04"))
    }

    // Helper function matching the one in FormatterAgent
    private func buildDateContext(referenceDate: Date) -> String {
        let calendar = Calendar.current
        let dateFormatter = DateFormatter()

        dateFormatter.dateFormat = "EEEE, MMMM d, yyyy"
        let todayString = dateFormatter.string(from: referenceDate)

        let weekday = calendar.component(.weekday, from: referenceDate)
        let weekdayName = dateFormatter.weekdaySymbols[weekday - 1]

        var dateInfo = """
        CURRENT DATE CONTEXT:
        - Today is: \(todayString)
        - Day of week: \(weekdayName)

        REFERENCE DATES:
        """

        for i in 0...14 {
            if let date = calendar.date(byAdding: .day, value: i, to: referenceDate) {
                dateFormatter.dateFormat = "yyyy-MM-dd"
                let isoDate = dateFormatter.string(from: date)
                dateFormatter.dateFormat = "EEEE"
                let dayName = dateFormatter.string(from: date)

                let label: String
                switch i {
                case 0: label = "today"
                case 1: label = "tomorrow"
                default: label = "in \(i) days"
                }

                dateInfo += "\n- \(dayName) (\(label)): \(isoDate)"
            }
        }

        dateInfo += "\n\nNEXT WEEK REFERENCES:"
        for targetWeekday in 1...7 {
            var daysToAdd = targetWeekday - weekday
            if daysToAdd <= 0 { daysToAdd += 7 }

            if let date = calendar.date(byAdding: .day, value: daysToAdd, to: referenceDate) {
                dateFormatter.dateFormat = "yyyy-MM-dd"
                let isoDate = dateFormatter.string(from: date)
                dateFormatter.dateFormat = "EEEE"
                let dayName = dateFormatter.string(from: date)

                dateInfo += "\n- next \(dayName): \(isoDate)"
            }
        }

        return dateInfo
    }
}

// MARK: - Pipeline Stats Tests

final class PipelineStatsTests: XCTestCase {

    func testPipelineResultCreation() {
        let result = PipelineResult(
            date: Date(),
            events: [
                FormattedEvent(
                    title: "Test Event",
                    startDate: Date(),
                    endDate: nil,
                    isAllDay: false,
                    location: nil,
                    attendees: [],
                    notes: nil,
                    confidence: .medium
                )
            ],
            tasks: [],
            story: "Test story narrative",
            rejectedItems: [],
            stats: .zero
        )

        XCTAssertEqual(result.events.count, 1)
        XCTAssertTrue(result.tasks.isEmpty)
        XCTAssertNotNil(result.story)
    }

    func testPipelineStatsCreation() {
        let stats = PipelineStats(
            isRunning: true,
            daysProcessed: 5,
            eventsCreated: 12,
            tasksCreated: 8
        )

        XCTAssertTrue(stats.isRunning)
        XCTAssertEqual(stats.daysProcessed, 5)
        XCTAssertEqual(stats.eventsCreated, 12)
        XCTAssertEqual(stats.tasksCreated, 8)
    }
}

// MARK: - Error Handling Tests

final class AgentErrorTests: XCTestCase {

    func testMissingAPIKeyError() {
        let error = AgentError.missingAPIKey("GEMINI_API_KEY")
        XCTAssertEqual(error.errorDescription, "GEMINI_API_KEY not set")
    }

    func testNoResponseError() {
        let error = AgentError.noResponse
        XCTAssertEqual(error.errorDescription, "No response from LLM")
    }

    func testParseError() {
        let error = AgentError.parseError("Invalid JSON structure")
        XCTAssertEqual(error.errorDescription, "Parse error: Invalid JSON structure")
    }

    func testDuplicateContentError() {
        let error = AgentError.duplicateContent
        XCTAssertEqual(error.errorDescription, "Duplicate content")
    }
}
