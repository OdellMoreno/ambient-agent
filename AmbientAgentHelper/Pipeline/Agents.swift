import Foundation
import AmbientCore

// MARK: - Pipeline Agents
// Five-stage extraction: Story → Extract → Format → Validate → Reflect
// With context optimization, confidence-based retry, and multi-agent verification

// MARK: - Story Agent

actor StoryAgent {
    private let client: LLMClient
    private let deduplicator: EmbeddingDeduplicator

    init(client: LLMClient, deduplicator: EmbeddingDeduplicator) {
        self.client = client
        self.deduplicator = deduplicator
    }

    func summarize(_ batch: DailyMessageBatch) async throws -> DailyStory {
        let content = batch.formattedForLLM

        // Get embedding for semantic deduplication
        let embedding = try? await client.getEmbedding(for: content)

        if await deduplicator.isDuplicate(content, embedding: embedding) {
            throw AgentError.duplicateContent
        }

        let dateString = batch.date.formatted(date: .complete, time: .omitted)

        // Context-optimized prompt: Important info FIRST (avoids "lost in middle")
        let systemPrompt = """
        CRITICAL: Focus on extracting ACTIONABLE information.

        You summarize message conversations into clear narratives.
        Focus on: plans, events, commitments, tasks, and action items.
        Write in third person, past tense. Be concise but capture important details.

        PRIORITIZE:
        1. Scheduled events with specific times/dates
        2. Explicit commitments and tasks
        3. People mentioned by name
        4. Locations and meeting places
        """

        // Use prompt compression for long content
        let userPrompt = PromptCompressor.optimizeContextPosition(
            systemPrompt,
            content,
            dateContext: "Reference date: \(dateString)"
        )

        let response = try await client.call(
            systemPrompt: systemPrompt,
            userPrompt: userPrompt,
            temperature: 0.3,
            useCompression: batch.totalMessageCount > 50
        )

        // Mark as processed with embedding
        if let emb = embedding {
            await deduplicator.markProcessed(content, embedding: emb)
        }

        return DailyStory(
            date: batch.date,
            narrative: response,
            keyPeople: Array(Set(batch.conversations.flatMap { $0.participants })),
            conversationCount: batch.conversations.count
        )
    }
}

// MARK: - Extractor Agent

actor ExtractorAgent {
    private let client: LLMClient
    private let maxRetries = 2

    init(client: LLMClient) {
        self.client = client
    }

    func extract(from story: DailyStory, withFeedback feedback: String? = nil) async throws -> [ExtractedItem] {
        let dateString = story.date.formatted(date: .complete, time: .omitted)

        // Context-optimized: Reference date at the TOP
        let systemPrompt = """
        REFERENCE DATE: \(dateString) - Use this for all relative date calculations.

        Extract events and tasks from narrative text.

        EVENTS: Meetings, appointments, calls, dinners with specific time indication
        TASKS: Action items, things to do, explicit commitments

        RULES:
        - Do NOT extract vague possibilities ("might", "maybe", "possibly")
        - Do NOT extract past events (already happened)
        - HIGH confidence: Specific date AND time mentioned
        - MEDIUM confidence: Date mentioned but time is vague
        - LOW confidence: Only rough timeframe mentioned

        For each item: title, type (event/task), rough_date, rough_time, people, location, confidence, context
        """

        var userPrompt = """
        NARRATIVE TO ANALYZE:
        \(story.narrative)

        Extract all actionable events and tasks.
        """

        // If we have feedback from a previous attempt, include it
        if let feedback = feedback {
            userPrompt += "\n\nPREVIOUS EXTRACTION FEEDBACK:\n\(feedback)\nPlease address these issues."
        }

        let response = try await client.call(
            systemPrompt: systemPrompt,
            userPrompt: userPrompt,
            schema: JSONSchemas.extractor,
            temperature: 0.1
        )

        return try parseItems(response)
    }

    private func parseItems(_ json: String) throws -> [ExtractedItem] {
        let cleaned = ParseHelpers.cleanJSON(json)
        guard let data = cleaned.data(using: .utf8) else {
            throw AgentError.parseError("Invalid JSON")
        }

        struct Raw: Decodable {
            let title: String
            let type: String
            let rough_date: String?
            let rough_time: String?
            let people: [String]?
            let location: String?
            let confidence: String
            let context: String?
        }

        let items = try JSONDecoder().decode([Raw].self, from: data)
        return items.map {
            ExtractedItem(
                title: $0.title,
                itemType: $0.type == "task" ? .task : .event,
                roughDate: $0.rough_date,
                roughTime: $0.rough_time,
                people: $0.people ?? [],
                location: $0.location,
                confidence: $0.confidence,
                context: $0.context
            )
        }
    }
}

// MARK: - Formatter Agent

actor FormatterAgent {
    private let client: LLMClient

    init(client: LLMClient) {
        self.client = client
    }

    func format(items: [ExtractedItem], referenceDate: Date) async throws -> ([FormattedEvent], [FormattedTask]) {
        guard !items.isEmpty else { return ([], []) }

        let dateContext = buildDateContext(referenceDate)

        // Context-optimized: Date context at TOP of system prompt
        let systemPrompt = """
        CRITICAL DATE CONTEXT - USE THIS FOR ALL CONVERSIONS:
        \(dateContext)

        Convert informal dates to exact ISO 8601 format (yyyy-MM-ddTHH:mm:ss).

        CONVERSION RULES:
        - "tomorrow" = day after reference date
        - "next Tuesday" = next occurrence of Tuesday after today
        - "this Friday" = coming Friday (same week if today is before Friday)
        - "afternoon" → 14:00, "morning" → 09:00, "evening" → 18:00, "noon" → 12:00
        - Meetings without end time: assume 1 hour duration
        - Date only (no time mentioned): mark as all-day event
        - Tasks without due date: set due_date to null
        """

        let itemsData = items.map { [
            "title": $0.title, "type": $0.itemType.rawValue,
            "rough_date": $0.roughDate ?? "", "rough_time": $0.roughTime ?? "",
            "people": $0.people.joined(separator: ", "), "location": $0.location ?? "",
            "confidence": $0.confidence
        ]}
        let itemsJSON = (try? String(data: JSONEncoder().encode(itemsData), encoding: .utf8)) ?? "[]"

        let userPrompt = """
        ITEMS TO CONVERT:
        \(itemsJSON)

        Convert each item to exact calendar format.
        """

        let response = try await client.call(
            systemPrompt: systemPrompt,
            userPrompt: userPrompt,
            schema: JSONSchemas.formatter,
            temperature: 0.0
        )

        return try parseFormatted(response)
    }

    private func buildDateContext(_ ref: Date) -> String {
        let cal = Calendar.current
        let df = DateFormatter()
        df.dateFormat = "EEEE, MMMM d, yyyy"
        let today = df.string(from: ref)

        // Put current date prominently at top
        var ctx = "═══════════════════════════════════════\n"
        ctx += "TODAY IS: \(today)\n"
        ctx += "═══════════════════════════════════════\n\n"
        ctx += "DATE LOOKUP TABLE:\n"

        for i in 0...14 {
            guard let d = cal.date(byAdding: .day, value: i, to: ref) else { continue }
            df.dateFormat = "yyyy-MM-dd"
            let iso = df.string(from: d)
            df.dateFormat = "EEEE"
            let day = df.string(from: d)
            let label = i == 0 ? "TODAY" : i == 1 ? "tomorrow" : "in \(i) days"
            ctx += "  \(iso) | \(day) | \(label)\n"
        }

        ctx += "\nTIME LOOKUP:\n"
        ctx += "  morning → 09:00 | noon → 12:00 | afternoon → 14:00 | evening → 18:00 | night → 20:00"
        return ctx
    }

    private func parseFormatted(_ json: String) throws -> ([FormattedEvent], [FormattedTask]) {
        let cleaned = ParseHelpers.cleanJSON(json)
        guard let data = cleaned.data(using: .utf8) else {
            throw AgentError.parseError("Invalid JSON")
        }

        struct Raw: Decodable {
            struct Event: Decodable {
                let title: String
                let start_date: String
                let end_date: String?
                let is_all_day: Bool?
                let location: String?
                let attendees: [String]?
                let notes: String?
                let confidence: String?
            }
            struct Task: Decodable {
                let title: String
                let due_date: String?
                let priority: String?
                let assignee: String?
                let notes: String?
                let confidence: String?
            }
            let events: [Event]?
            let tasks: [Task]?
        }

        let raw = try JSONDecoder().decode(Raw.self, from: data)

        let events = (raw.events ?? []).compactMap { e -> FormattedEvent? in
            guard let start = ParseHelpers.parseDate(e.start_date) else { return nil }
            return FormattedEvent(
                title: e.title, startDate: start,
                endDate: e.end_date.flatMap { ParseHelpers.parseDate($0) },
                isAllDay: e.is_all_day ?? false,
                location: e.location, attendees: e.attendees ?? [],
                notes: e.notes,
                confidence: ExtractionConfidence(rawValue: e.confidence ?? "medium") ?? .medium
            )
        }

        let tasks = (raw.tasks ?? []).map { t in
            FormattedTask(
                title: t.title,
                dueDate: t.due_date.flatMap { ParseHelpers.parseDate($0) },
                priority: ParseHelpers.parsePriority(t.priority ?? "medium"),
                assignee: t.assignee, notes: t.notes,
                confidence: ExtractionConfidence(rawValue: t.confidence ?? "medium") ?? .medium
            )
        }

        return (events, tasks)
    }
}

// MARK: - Validator Agent

actor ValidatorAgent {
    private let client: LLMClient

    init(client: LLMClient) {
        self.client = client
    }

    struct Result {
        let events: [FormattedEvent]
        let tasks: [FormattedTask]
        let rejected: [(title: String, reason: String)]
    }

    func validate(events: [FormattedEvent], tasks: [FormattedTask], referenceDate: Date) async throws -> Result {
        guard !events.isEmpty || !tasks.isEmpty else {
            return Result(events: [], tasks: [], rejected: [])
        }

        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"

        let eventsJSON = events.map { [
            "title": $0.title, "start_date": df.string(from: $0.startDate),
            "end_date": $0.endDate.map { df.string(from: $0) } ?? "",
            "is_all_day": $0.isAllDay ? "true" : "false",
            "location": $0.location ?? "", "confidence": $0.confidence.rawValue
        ]}

        let tasksJSON = tasks.map { [
            "title": $0.title, "due_date": $0.dueDate.map { df.string(from: $0) } ?? "",
            "priority": "\($0.priority)", "confidence": $0.confidence.rawValue
        ]}

        df.dateFormat = "EEEE, MMMM d, yyyy"

        // Context-optimized: Reference date prominently displayed
        let systemPrompt = """
        ═══════════════════════════════════════
        VALIDATION REFERENCE DATE: \(df.string(from: referenceDate))
        ═══════════════════════════════════════

        Validate extracted events and tasks.

        REJECTION CRITERIA:
        - Dates more than 7 days in the past
        - Impossible times (e.g., 25:00, negative durations)
        - Obvious duplicates (same title, same time)
        - Vague non-events without actionable content

        CONFIDENCE ADJUSTMENTS:
        - Lower to MEDIUM: events >30 days in future
        - Lower to LOW: no specific time, only date
        - Keep HIGH: specific date AND time within 14 days
        """

        let userPrompt = """
        EVENTS TO VALIDATE:
        \((try? String(data: JSONEncoder().encode(eventsJSON), encoding: .utf8)) ?? "[]")

        TASKS TO VALIDATE:
        \((try? String(data: JSONEncoder().encode(tasksJSON), encoding: .utf8)) ?? "[]")
        """

        let response = try await client.call(
            systemPrompt: systemPrompt,
            userPrompt: userPrompt,
            schema: JSONSchemas.validator,
            temperature: 0.0
        )

        return try parseValidation(response)
    }

    private func parseValidation(_ json: String) throws -> Result {
        let cleaned = ParseHelpers.cleanJSON(json)
        guard let data = cleaned.data(using: .utf8) else {
            throw AgentError.parseError("Invalid JSON")
        }

        struct Raw: Decodable {
            struct Event: Decodable {
                let title: String
                let start_date: String
                let end_date: String?
                let is_all_day: Bool?
                let location: String?
                let attendees: [String]?
                let confidence: String?
            }
            struct Task: Decodable {
                let title: String
                let due_date: String?
                let priority: String?
                let assignee: String?
                let confidence: String?
            }
            struct Rejected: Decodable {
                let title: String
                let reason: String
            }
            let valid_events: [Event]?
            let valid_tasks: [Task]?
            let rejected_items: [Rejected]?
        }

        let raw = try JSONDecoder().decode(Raw.self, from: data)

        let events = (raw.valid_events ?? []).compactMap { e -> FormattedEvent? in
            guard let start = ParseHelpers.parseDate(e.start_date) else { return nil }
            return FormattedEvent(
                title: e.title, startDate: start,
                endDate: e.end_date.flatMap { ParseHelpers.parseDate($0) },
                isAllDay: e.is_all_day ?? false,
                location: e.location, attendees: e.attendees ?? [],
                notes: nil,
                confidence: ExtractionConfidence(rawValue: e.confidence ?? "medium") ?? .medium
            )
        }

        let tasks = (raw.valid_tasks ?? []).map { t in
            FormattedTask(
                title: t.title,
                dueDate: t.due_date.flatMap { ParseHelpers.parseDate($0) },
                priority: ParseHelpers.parsePriority(t.priority ?? "medium"),
                assignee: t.assignee, notes: nil,
                confidence: ExtractionConfidence(rawValue: t.confidence ?? "medium") ?? .medium
            )
        }

        let rejected = (raw.rejected_items ?? []).map { ($0.title, $0.reason) }

        return Result(events: events, tasks: tasks, rejected: rejected)
    }
}

// MARK: - Critic Agent (Self-Reflection)

actor CriticAgent {
    private let client: LLMClient

    init(client: LLMClient) {
        self.client = client
    }

    struct CriticResult {
        let qualityScore: Double  // 0-10
        let issues: [Issue]
        let missingItems: [String]
        let shouldRetry: Bool

        struct Issue {
            let itemTitle: String
            let issueType: IssueType
            let description: String
            let suggestedFix: String?
        }

        enum IssueType: String {
            case missingInfo = "missing_info"
            case wrongDate = "wrong_date"
            case wrongType = "wrong_type"
            case duplicate = "duplicate"
            case vague = "vague"
            case hallucination = "hallucination"
        }
    }

    /// Review extraction quality and provide feedback for improvement
    func review(
        story: DailyStory,
        extractedItems: [ExtractedItem],
        formattedEvents: [FormattedEvent],
        formattedTasks: [FormattedTask]
    ) async throws -> CriticResult {

        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"

        let eventsDesc = formattedEvents.map {
            "- \($0.title) @ \(df.string(from: $0.startDate)) [\($0.confidence.rawValue)]"
        }.joined(separator: "\n")

        let tasksDesc = formattedTasks.map {
            "- \($0.title) (due: \($0.dueDate.map { df.string(from: $0) } ?? "none")) [\($0.confidence.rawValue)]"
        }.joined(separator: "\n")

        let systemPrompt = """
        You are a quality reviewer for an event/task extraction system.

        Your job is to:
        1. Compare the original narrative to the extracted items
        2. Identify any issues (wrong dates, missing info, hallucinations)
        3. Find items mentioned in the story that weren't extracted
        4. Score overall quality (0-10)
        5. Decide if extraction should be retried with feedback

        ISSUE TYPES:
        - missing_info: Important details not captured
        - wrong_date: Date/time seems incorrect
        - wrong_type: Should be event not task (or vice versa)
        - duplicate: Same item extracted multiple times
        - vague: Too vague to be actionable
        - hallucination: Item not mentioned in original text
        """

        let userPrompt = """
        ORIGINAL NARRATIVE:
        \(story.narrative)

        EXTRACTED EVENTS:
        \(eventsDesc.isEmpty ? "(none)" : eventsDesc)

        EXTRACTED TASKS:
        \(tasksDesc.isEmpty ? "(none)" : tasksDesc)

        Review the extraction quality.
        """

        let response = try await client.call(
            systemPrompt: systemPrompt,
            userPrompt: userPrompt,
            schema: JSONSchemas.critic,
            temperature: 0.1
        )

        return try parseCriticResult(response)
    }

    private func parseCriticResult(_ json: String) throws -> CriticResult {
        let cleaned = ParseHelpers.cleanJSON(json)
        guard let data = cleaned.data(using: .utf8) else {
            throw AgentError.parseError("Invalid JSON")
        }

        struct Raw: Decodable {
            struct Issue: Decodable {
                let item_title: String
                let issue_type: String
                let description: String
                let suggested_fix: String?
            }
            let quality_score: Double
            let issues: [Issue]?
            let missing_items: [String]?
            let should_retry: Bool
        }

        let raw = try JSONDecoder().decode(Raw.self, from: data)

        let issues = (raw.issues ?? []).map {
            CriticResult.Issue(
                itemTitle: $0.item_title,
                issueType: CriticResult.IssueType(rawValue: $0.issue_type) ?? .vague,
                description: $0.description,
                suggestedFix: $0.suggested_fix
            )
        }

        return CriticResult(
            qualityScore: raw.quality_score,
            issues: issues,
            missingItems: raw.missing_items ?? [],
            shouldRetry: raw.should_retry
        )
    }

    /// Generate feedback string for retry
    func generateFeedback(from result: CriticResult) -> String {
        var feedback = "Quality score: \(result.qualityScore)/10\n\n"

        if !result.issues.isEmpty {
            feedback += "ISSUES TO FIX:\n"
            for issue in result.issues {
                feedback += "- [\(issue.issueType.rawValue)] \(issue.itemTitle): \(issue.description)"
                if let fix = issue.suggestedFix {
                    feedback += " → \(fix)"
                }
                feedback += "\n"
            }
        }

        if !result.missingItems.isEmpty {
            feedback += "\nMISSING ITEMS (please extract these):\n"
            for item in result.missingItems {
                feedback += "- \(item)\n"
            }
        }

        return feedback
    }
}

// MARK: - Multi-Agent Verifier

actor MultiAgentVerifier {
    private let client: LLMClient

    init(client: LLMClient) {
        self.client = client
    }

    struct VerificationResult {
        let agreedEvents: [FormattedEvent]
        let agreedTasks: [FormattedTask]
        let disputedItems: [(item: String, reason: String)]
        let consensusScore: Double  // 0-1
    }

    /// Cross-verify items using a second "perspective"
    /// This simulates multi-agent debate without actually running multiple models
    func crossVerify(
        events: [FormattedEvent],
        tasks: [FormattedTask],
        originalStory: String,
        referenceDate: Date
    ) async throws -> VerificationResult {

        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"

        let eventsJSON = events.map { [
            "title": $0.title,
            "start_date": df.string(from: $0.startDate),
            "confidence": $0.confidence.rawValue
        ]}

        let tasksJSON = tasks.map { [
            "title": $0.title,
            "due_date": $0.dueDate.map { df.string(from: $0) } ?? "none",
            "confidence": $0.confidence.rawValue
        ]}

        // Use a "skeptical reviewer" persona to challenge the extraction
        let systemPrompt = """
        You are a SKEPTICAL REVIEWER. Your job is to challenge extracted events and tasks.

        For each item, ask:
        1. Is this item EXPLICITLY mentioned in the original text?
        2. Is the date/time interpretation correct?
        3. Is this actually actionable (not just a mention)?

        Vote AGREE only if you're confident the extraction is correct.
        Vote DISPUTE if there's any reasonable doubt.

        Be conservative - it's better to dispute a correct item than agree with a wrong one.
        """

        let userPrompt = """
        ORIGINAL TEXT:
        \(originalStory)

        REFERENCE DATE: \(referenceDate.formatted(date: .complete, time: .omitted))

        EXTRACTED EVENTS:
        \((try? String(data: JSONEncoder().encode(eventsJSON), encoding: .utf8)) ?? "[]")

        EXTRACTED TASKS:
        \((try? String(data: JSONEncoder().encode(tasksJSON), encoding: .utf8)) ?? "[]")

        For each item, vote AGREE or DISPUTE with a brief reason.
        Return JSON: {"agreed_events": [...], "agreed_tasks": [...], "disputed": [{"item": "...", "reason": "..."}], "consensus_score": 0.0-1.0}
        """

        let response = try await client.call(
            systemPrompt: systemPrompt,
            userPrompt: userPrompt,
            temperature: 0.2
        )

        return try parseVerification(response, events: events, tasks: tasks)
    }

    private func parseVerification(
        _ json: String,
        events: [FormattedEvent],
        tasks: [FormattedTask]
    ) throws -> VerificationResult {
        let cleaned = ParseHelpers.cleanJSON(json)
        guard let data = cleaned.data(using: .utf8) else {
            // If parsing fails, return all items as agreed (fail-safe)
            return VerificationResult(
                agreedEvents: events,
                agreedTasks: tasks,
                disputedItems: [],
                consensusScore: 1.0
            )
        }

        struct Raw: Decodable {
            let agreed_events: [String]?
            let agreed_tasks: [String]?
            let disputed: [Disputed]?
            let consensus_score: Double?

            struct Disputed: Decodable {
                let item: String
                let reason: String
            }
        }

        let raw = try JSONDecoder().decode(Raw.self, from: data)

        let agreedEventTitles = Set(raw.agreed_events ?? [])
        let agreedTaskTitles = Set(raw.agreed_tasks ?? [])

        let agreedEvents = events.filter { agreedEventTitles.contains($0.title) }
        let agreedTasks = tasks.filter { agreedTaskTitles.contains($0.title) }

        let disputed = (raw.disputed ?? []).map { ($0.item, $0.reason) }

        return VerificationResult(
            agreedEvents: agreedEvents.isEmpty ? events : agreedEvents,  // Fail-safe: keep all if empty
            agreedTasks: agreedTasks.isEmpty ? tasks : agreedTasks,
            disputedItems: disputed,
            consensusScore: raw.consensus_score ?? 0.8
        )
    }
}
