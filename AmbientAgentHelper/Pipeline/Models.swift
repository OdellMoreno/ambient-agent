import Foundation
import AmbientCore

// MARK: - Pipeline Models
// All data types for the agent pipeline

// MARK: - Input Types

struct DailyMessageBatch {
    let date: Date
    let conversations: [ConversationThread]

    var totalMessageCount: Int {
        conversations.reduce(0) { $0 + $1.messages.count }
    }

    var isEmpty: Bool { conversations.isEmpty }

    var formattedForLLM: String {
        var output = ""
        for convo in conversations {
            output += "## Conversation with \(convo.participants.joined(separator: ", "))\n\n"
            for msg in convo.messages {
                let sender = msg.isFromMe ? "Me" : (msg.sender ?? "Unknown")
                let time = msg.timestamp.formatted(date: .omitted, time: .shortened)
                output += "[\(time)] \(sender): \(msg.content)\n"
            }
            output += "\n"
        }
        return output
    }
}

struct ConversationThread {
    let threadID: String
    let participants: [String]
    let messages: [MessageItem]
}

struct MessageItem {
    let content: String
    let sender: String?
    let timestamp: Date
    let isFromMe: Bool
}

// MARK: - Story Agent Output

struct DailyStory {
    let date: Date
    let narrative: String
    let keyPeople: [String]
    let conversationCount: Int
}

// MARK: - Extractor Agent Output

struct ExtractedItem: Codable {
    let title: String
    let itemType: ItemType
    let roughDate: String?
    let roughTime: String?
    let people: [String]
    let location: String?
    let confidence: String
    let context: String?

    enum ItemType: String, Codable {
        case event, task
    }

    enum CodingKeys: String, CodingKey {
        case title, people, location, confidence, context
        case itemType = "type"
        case roughDate = "rough_date"
        case roughTime = "rough_time"
    }
}

// MARK: - Formatter Agent Output

struct FormattedEvent {
    let title: String
    let startDate: Date
    let endDate: Date?
    let isAllDay: Bool
    let location: String?
    let attendees: [String]
    let notes: String?
    let confidence: ExtractionConfidence
}

struct FormattedTask {
    let title: String
    let dueDate: Date?
    let priority: TaskPriority
    let assignee: String?
    let notes: String?
    let confidence: ExtractionConfidence
}

// MARK: - Pipeline Result

struct PipelineResult {
    let date: Date
    let events: [FormattedEvent]
    let tasks: [FormattedTask]
    let story: String?
    let rejectedItems: [(title: String, reason: String)]
    let stats: Stats

    struct Stats {
        let storyMs: Int64
        let extractMs: Int64
        let formatMs: Int64
        let validateMs: Int64
        let totalMs: Int64

        static let zero = Stats(storyMs: 0, extractMs: 0, formatMs: 0, validateMs: 0, totalMs: 0)
    }

    static func empty(for date: Date) -> PipelineResult {
        PipelineResult(date: date, events: [], tasks: [], story: nil, rejectedItems: [], stats: .zero)
    }
}

struct PipelineStats {
    let isRunning: Bool
    let daysProcessed: Int
    let eventsCreated: Int
    let tasksCreated: Int
}

// MARK: - JSON Schemas for Structured Output
// Using propertyOrdering for Gemini 2.5+ to ensure consistent output order

enum JSONSchemas {
    // Extractor schema with property ordering for better accuracy
    static let extractor: [String: Any] = [
        "type": "array",
        "items": [
            "type": "object",
            "properties": [
                "title": ["type": "string", "description": "Clear, concise title for the event or task"],
                "type": ["type": "string", "enum": ["event", "task"], "description": "Whether this is a calendar event or a task"],
                "confidence": ["type": "string", "enum": ["high", "medium", "low"], "description": "Confidence level based on specificity"],
                "rough_date": ["type": "string", "description": "Date mentioned (e.g., 'tomorrow', 'Oct 15', 'next Tuesday')"],
                "rough_time": ["type": "string", "description": "Time mentioned (e.g., '3pm', 'afternoon', '10:30')"],
                "people": ["type": "array", "items": ["type": "string"], "description": "People involved"],
                "location": ["type": "string", "description": "Location if mentioned"],
                "context": ["type": "string", "description": "Brief context from conversation"]
            ],
            "required": ["title", "type", "confidence"],
            "propertyOrdering": ["title", "type", "confidence", "rough_date", "rough_time", "people", "location", "context"]
        ]
    ]

    // Formatter schema - events first, then tasks
    static let formatter: [String: Any] = [
        "type": "object",
        "properties": [
            "events": [
                "type": "array",
                "items": [
                    "type": "object",
                    "properties": [
                        "title": ["type": "string"],
                        "start_date": ["type": "string", "description": "ISO 8601 format: yyyy-MM-ddTHH:mm:ss"],
                        "end_date": ["type": "string", "description": "ISO 8601 format, null if unknown"],
                        "is_all_day": ["type": "boolean"],
                        "location": ["type": "string"],
                        "attendees": ["type": "array", "items": ["type": "string"]],
                        "notes": ["type": "string"],
                        "confidence": ["type": "string", "enum": ["high", "medium", "low"]]
                    ],
                    "required": ["title", "start_date", "confidence"],
                    "propertyOrdering": ["title", "start_date", "end_date", "is_all_day", "location", "attendees", "confidence", "notes"]
                ]
            ],
            "tasks": [
                "type": "array",
                "items": [
                    "type": "object",
                    "properties": [
                        "title": ["type": "string"],
                        "due_date": ["type": "string", "description": "ISO 8601 format, null if no deadline"],
                        "priority": ["type": "string", "enum": ["urgent", "high", "medium", "low"]],
                        "assignee": ["type": "string"],
                        "notes": ["type": "string"],
                        "confidence": ["type": "string", "enum": ["high", "medium", "low"]]
                    ],
                    "required": ["title", "confidence"],
                    "propertyOrdering": ["title", "due_date", "priority", "assignee", "confidence", "notes"]
                ]
            ]
        ],
        "required": ["events", "tasks"],
        "propertyOrdering": ["events", "tasks"]
    ]

    // Validator schema
    static let validator: [String: Any] = [
        "type": "object",
        "properties": [
            "valid_events": [
                "type": "array",
                "items": [
                    "type": "object",
                    "properties": [
                        "title": ["type": "string"],
                        "start_date": ["type": "string"],
                        "end_date": ["type": "string"],
                        "is_all_day": ["type": "boolean"],
                        "location": ["type": "string"],
                        "attendees": ["type": "array", "items": ["type": "string"]],
                        "confidence": ["type": "string", "enum": ["high", "medium", "low"]]
                    ],
                    "required": ["title", "start_date", "confidence"],
                    "propertyOrdering": ["title", "start_date", "end_date", "is_all_day", "location", "attendees", "confidence"]
                ]
            ],
            "valid_tasks": [
                "type": "array",
                "items": [
                    "type": "object",
                    "properties": [
                        "title": ["type": "string"],
                        "due_date": ["type": "string"],
                        "priority": ["type": "string", "enum": ["urgent", "high", "medium", "low"]],
                        "assignee": ["type": "string"],
                        "confidence": ["type": "string", "enum": ["high", "medium", "low"]]
                    ],
                    "required": ["title", "confidence"],
                    "propertyOrdering": ["title", "due_date", "priority", "assignee", "confidence"]
                ]
            ],
            "rejected_items": [
                "type": "array",
                "items": [
                    "type": "object",
                    "properties": [
                        "title": ["type": "string"],
                        "reason": ["type": "string", "description": "Why this item was rejected"]
                    ],
                    "required": ["title", "reason"],
                    "propertyOrdering": ["title", "reason"]
                ]
            ]
        ],
        "required": ["valid_events", "valid_tasks", "rejected_items"],
        "propertyOrdering": ["valid_events", "valid_tasks", "rejected_items"]
    ]

    // Reflection/Critic schema for self-correction
    static let critic: [String: Any] = [
        "type": "object",
        "properties": [
            "quality_score": ["type": "number", "minimum": 0, "maximum": 10, "description": "Overall extraction quality 0-10"],
            "issues": [
                "type": "array",
                "items": [
                    "type": "object",
                    "properties": [
                        "item_title": ["type": "string"],
                        "issue_type": ["type": "string", "enum": ["missing_info", "wrong_date", "wrong_type", "duplicate", "vague", "hallucination"]],
                        "description": ["type": "string"],
                        "suggested_fix": ["type": "string"]
                    ],
                    "required": ["item_title", "issue_type", "description"],
                    "propertyOrdering": ["item_title", "issue_type", "description", "suggested_fix"]
                ]
            ],
            "missing_items": [
                "type": "array",
                "items": ["type": "string"],
                "description": "Events/tasks mentioned in story but not extracted"
            ],
            "should_retry": ["type": "boolean", "description": "Whether extraction should be retried with feedback"]
        ],
        "required": ["quality_score", "issues", "missing_items", "should_retry"],
        "propertyOrdering": ["quality_score", "issues", "missing_items", "should_retry"]
    ]
}

// MARK: - Parsing Helpers

enum ParseHelpers {
    static func cleanJSON(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("```json") { s = String(s.dropFirst(7)) }
        if s.hasPrefix("```") { s = String(s.dropFirst(3)) }
        if s.hasSuffix("```") { s = String(s.dropLast(3)) }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func parseDate(_ string: String) -> Date? {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let isoBasic = ISO8601DateFormatter()
        isoBasic.formatOptions = [.withInternetDateTime]

        let simple = DateFormatter()
        simple.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"

        return iso.date(from: string) ?? isoBasic.date(from: string) ?? simple.date(from: string)
    }

    static func parsePriority(_ str: String) -> TaskPriority {
        switch str.lowercased() {
        case "urgent": return .urgent
        case "high": return .high
        case "medium": return .medium
        case "low": return .low
        default: return .none
        }
    }
}

// MARK: - Agent Errors

enum AgentError: Error, LocalizedError {
    case missingAPIKey(String)
    case noResponse
    case parseError(String)
    case duplicateContent

    var errorDescription: String? {
        switch self {
        case .missingAPIKey(let key): return "\(key) not set"
        case .noResponse: return "No response from LLM"
        case .parseError(let msg): return "Parse error: \(msg)"
        case .duplicateContent: return "Duplicate content"
        }
    }
}

// MARK: - Extraction Config

enum ExtractionConfig {
    static let currentVersion = "1.0"
}

// MARK: - Filter Decision

enum FilterDecision {
    case process(priority: ProcessingPriority)
    case skip(reason: SkipReason)

    enum ProcessingPriority {
        case realtime, high, normal, low
    }

    enum SkipReason {
        case tooShort, duplicate, alreadyProcessed, automated, promotional, noActionableContent
    }
}
