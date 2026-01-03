import Foundation
import SwiftData
import AmbientCore

// MARK: - Pipeline Coordinator
// Orchestrates the enhanced pipeline with self-reflection and multi-agent verification

actor PipelineCoordinator {
    private let modelContainer: ModelContainer

    // Shared infrastructure
    private let client: LLMClient
    private let deduplicator: EmbeddingDeduplicator

    // Agents (6 total now)
    private let storyAgent: StoryAgent
    private let extractorAgent: ExtractorAgent
    private let formatterAgent: FormatterAgent
    private let validatorAgent: ValidatorAgent
    private let criticAgent: CriticAgent
    private let verifier: MultiAgentVerifier

    // Configuration
    private let enableSelfReflection: Bool
    private let enableMultiAgentVerification: Bool
    private let minQualityScore: Double = 7.0  // Retry if below this
    private let maxReflectionRetries: Int = 1

    // State
    private var isRunning = false
    private var task: Task<Void, Never>?
    private var processedDays: Set<String> = []

    // Stats
    private var daysProcessed = 0
    private var eventsCreated = 0
    private var tasksCreated = 0
    private var reflectionRetries = 0
    private var itemsDisputed = 0

    init(
        modelContainer: ModelContainer,
        enableSelfReflection: Bool = true,
        enableMultiAgentVerification: Bool = true
    ) {
        self.modelContainer = modelContainer
        self.enableSelfReflection = enableSelfReflection
        self.enableMultiAgentVerification = enableMultiAgentVerification

        self.client = LLMClient()
        self.deduplicator = EmbeddingDeduplicator()

        self.storyAgent = StoryAgent(client: client, deduplicator: deduplicator)
        self.extractorAgent = ExtractorAgent(client: client)
        self.formatterAgent = FormatterAgent(client: client)
        self.validatorAgent = ValidatorAgent(client: client)
        self.criticAgent = CriticAgent(client: client)
        self.verifier = MultiAgentVerifier(client: client)
    }

    // MARK: - Public API

    func start() {
        guard !isRunning else { return }
        isRunning = true
        AmbientLogger.extraction.info("Starting enhanced pipeline coordinator")

        task = Task { await runLoop() }
    }

    func stop() {
        isRunning = false
        task?.cancel()
        task = nil
        AmbientLogger.extraction.info("Stopped pipeline coordinator")
    }

    func processDay(_ date: Date) async throws -> PipelineResult {
        let batch = try await buildBatch(for: date)
        guard !batch.isEmpty else { return .empty(for: date) }
        return try await processBatch(batch)
    }

    func getStats() -> PipelineStats {
        PipelineStats(
            isRunning: isRunning,
            daysProcessed: daysProcessed,
            eventsCreated: eventsCreated,
            tasksCreated: tasksCreated
        )
    }

    func getDetailedStats() async -> DetailedPipelineStats {
        let cacheStats = await client.getStats()
        return DetailedPipelineStats(
            isRunning: isRunning,
            daysProcessed: daysProcessed,
            eventsCreated: eventsCreated,
            tasksCreated: tasksCreated,
            reflectionRetries: reflectionRetries,
            itemsDisputed: itemsDisputed,
            cacheHitRate: cacheStats.hitRate,
            totalAPICalls: cacheStats.total,
            cacheHits: cacheStats.cacheHits + cacheStats.semanticHits
        )
    }

    // MARK: - Background Loop

    private func runLoop() async {
        while isRunning {
            do {
                try await processRecentDays()
                try await Task.sleep(for: .seconds(300))  // Check every 5 minutes
            } catch {
                if !Task.isCancelled {
                    AmbientLogger.extraction.error("Pipeline error: \(error.localizedDescription)")
                }
            }
        }
    }

    private func processRecentDays() async throws {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())

        for daysAgo in 0..<7 {
            guard isRunning else { break }
            guard let date = cal.date(byAdding: .day, value: -daysAgo, to: today) else { continue }

            let key = dayKey(date)
            if daysAgo > 0 && processedDays.contains(key) { continue }

            do {
                let result = try await processDay(date)
                if !result.events.isEmpty || !result.tasks.isEmpty {
                    let ec = result.events.count
                    let tc = result.tasks.count
                    let rc = result.rejectedItems.count
                    AmbientLogger.extraction.info("Day \(key): \(ec) events, \(tc) tasks, \(rc) rejected")
                }
                processedDays.insert(key)
                daysProcessed += 1
            } catch AgentError.duplicateContent {
                continue
            } catch {
                AmbientLogger.extraction.error("Failed \(key): \(error.localizedDescription)")
            }

            try await Task.sleep(for: .seconds(2))
        }
    }

    // MARK: - Batch Building

    private func buildBatch(for date: Date) async throws -> DailyMessageBatch {
        let context = ModelContext(modelContainer)
        let cal = Calendar.current

        let start = cal.startOfDay(for: date)
        guard let end = cal.date(byAdding: .day, value: 1, to: start) else {
            return DailyMessageBatch(date: date, conversations: [])
        }

        var descriptor = FetchDescriptor<RawItem>(sortBy: [SortDescriptor(\.fetchedAt)])
        descriptor.fetchLimit = 1000

        let all = try context.fetch(descriptor)
        let items = all.filter { $0.sourceType == .messages && $0.fetchedAt >= start && $0.fetchedAt < end }

        var threads: [String: [RawItem]] = [:]
        for item in items {
            threads[item.threadID ?? "unknown", default: []].append(item)
        }

        let conversations = threads.map { (id, items) in
            ConversationThread(
                threadID: id,
                participants: Array(Set(items.flatMap { $0.participants })),
                messages: items.map {
                    MessageItem(
                        content: $0.content ?? "",
                        sender: $0.participants.first,
                        timestamp: $0.fetchedAt,
                        isFromMe: $0.metadata["is_from_me"] == "true"
                    )
                }
            )
        }

        return DailyMessageBatch(date: date, conversations: conversations)
    }

    // MARK: - Processing with Self-Reflection

    private func processBatch(_ batch: DailyMessageBatch) async throws -> PipelineResult {
        let totalStart = DispatchTime.now()
        var storyMs: Int64 = 0, extractMs: Int64 = 0, formatMs: Int64 = 0, validateMs: Int64 = 0, reflectMs: Int64 = 0

        // 1. Story
        var t = DispatchTime.now()
        let story = try await storyAgent.summarize(batch)
        storyMs = ms(from: t)

        // 2. Extract (with possible retry based on reflection)
        t = DispatchTime.now()
        var items = try await extractorAgent.extract(from: story)
        var extractionFeedback: String? = nil
        extractMs = ms(from: t)

        guard !items.isEmpty else {
            return PipelineResult(
                date: batch.date, events: [], tasks: [], story: story.narrative,
                rejectedItems: [],
                stats: .init(storyMs: storyMs, extractMs: extractMs, formatMs: 0, validateMs: 0, totalMs: ms(from: totalStart))
            )
        }

        // 3. Format
        t = DispatchTime.now()
        var (events, tasks) = try await formatterAgent.format(items: items, referenceDate: batch.date)
        formatMs = ms(from: t)

        // 4. Self-Reflection Loop (if enabled)
        if enableSelfReflection && (!events.isEmpty || !tasks.isEmpty) {
            t = DispatchTime.now()

            let criticResult = try await criticAgent.review(
                story: story,
                extractedItems: items,
                formattedEvents: events,
                formattedTasks: tasks
            )

            AmbientLogger.extraction.info("Critic score: \(criticResult.qualityScore)/10, issues: \(criticResult.issues.count)")

            // Retry if quality is low and critic recommends it
            if criticResult.shouldRetry && criticResult.qualityScore < minQualityScore {
                reflectionRetries += 1
                extractionFeedback = await criticAgent.generateFeedback(from: criticResult)

                // Re-extract with feedback
                items = try await extractorAgent.extract(from: story, withFeedback: extractionFeedback)
                (events, tasks) = try await formatterAgent.format(items: items, referenceDate: batch.date)

                AmbientLogger.extraction.info("Re-extracted after feedback: \(events.count) events, \(tasks.count) tasks")
            }

            reflectMs = ms(from: t)
        }

        // 5. Multi-Agent Verification (if enabled)
        if enableMultiAgentVerification && (!events.isEmpty || !tasks.isEmpty) {
            let verifyResult = try await verifier.crossVerify(
                events: events,
                tasks: tasks,
                originalStory: story.narrative,
                referenceDate: batch.date
            )

            // Use verified items if consensus is high enough
            if verifyResult.consensusScore >= 0.6 {
                let disputedCount = verifyResult.disputedItems.count
                if disputedCount > 0 {
                    itemsDisputed += disputedCount
                    AmbientLogger.extraction.info("Multi-agent verification disputed \(disputedCount) items")
                }
                events = verifyResult.agreedEvents
                tasks = verifyResult.agreedTasks
            }
        }

        // 6. Validate
        t = DispatchTime.now()
        let validated = try await validatorAgent.validate(events: events, tasks: tasks, referenceDate: batch.date)
        validateMs = ms(from: t)

        // 7. Confidence-Based Filtering
        let (finalEvents, finalTasks, lowConfidenceRejected) = filterByConfidence(
            events: validated.events,
            tasks: validated.tasks
        )

        // Combine rejected items
        var allRejected = validated.rejected
        allRejected.append(contentsOf: lowConfidenceRejected)

        // 8. Save
        try await save(events: finalEvents, tasks: finalTasks, date: batch.date)

        eventsCreated += finalEvents.count
        tasksCreated += finalTasks.count

        return PipelineResult(
            date: batch.date,
            events: finalEvents,
            tasks: finalTasks,
            story: story.narrative,
            rejectedItems: allRejected,
            stats: .init(
                storyMs: storyMs,
                extractMs: extractMs + reflectMs,
                formatMs: formatMs,
                validateMs: validateMs,
                totalMs: ms(from: totalStart)
            )
        )
    }

    // MARK: - Confidence Filtering

    private func filterByConfidence(
        events: [FormattedEvent],
        tasks: [FormattedTask]
    ) -> ([FormattedEvent], [FormattedTask], [(title: String, reason: String)]) {
        var rejected: [(String, String)] = []

        // Keep all events, but track low confidence ones
        let filteredEvents = events.filter { event in
            if event.confidence == .low {
                // Keep low confidence events but log them
                AmbientLogger.extraction.debug("Low confidence event: \(event.title)")
            }
            return true  // Keep all for now, could filter if needed
        }

        // For tasks, be more conservative - reject very low confidence without due dates
        let filteredTasks = tasks.filter { task in
            if task.confidence == .low && task.dueDate == nil {
                rejected.append((task.title, "Low confidence task without due date"))
                return false
            }
            return true
        }

        return (filteredEvents, filteredTasks, rejected)
    }

    // MARK: - Persistence

    private func save(events: [FormattedEvent], tasks: [FormattedTask], date: Date) async throws {
        let context = ModelContext(modelContainer)

        for event in events {
            let title = event.title
            let startDate = event.startDate
            let srcRaw = SourceType.messages.rawValue

            let pred = #Predicate<AmbientEvent> { $0.title == title && $0.sourceTypeRaw == srcRaw }
            if let existing = try? context.fetch(FetchDescriptor(predicate: pred)),
               existing.contains(where: { abs($0.startDate.timeIntervalSince(startDate)) < 3600 }) {
                continue
            }

            let e = AmbientEvent(
                title: event.title, startDate: event.startDate,
                sourceType: .messages, sourceIdentifier: "pipeline-\(UUID().uuidString)",
                confidence: event.confidence
            )
            e.endDate = event.endDate
            e.location = event.location
            e.isAllDay = event.isAllDay
            e.eventDescription = event.notes
            e.attendees = event.attendees.map { .init(name: $0, email: nil, phone: nil, isOrganizer: false) }
            context.insert(e)
        }

        for task in tasks {
            let title = task.title
            let srcRaw = SourceType.messages.rawValue

            let pred = #Predicate<AmbientTask> { $0.title == title && $0.sourceTypeRaw == srcRaw }
            if (try? context.fetch(FetchDescriptor(predicate: pred)))?.first != nil {
                continue
            }

            let t = AmbientTask(
                title: task.title, sourceType: .messages,
                sourceIdentifier: "pipeline-\(UUID().uuidString)",
                confidence: task.confidence
            )
            t.dueDate = task.dueDate
            t.priority = task.priority
            t.assigneeName = task.assignee
            t.context = task.notes
            context.insert(t)
        }

        try context.save()

        let eventCount = events.count
        let taskCount = tasks.count
        let log = ActivityLog(type: .eventExtracted, message: "Pipeline: \(eventCount) events, \(taskCount) tasks from \(dayKey(date))")
        context.insert(log)
        try? context.save()
    }

    // MARK: - Helpers

    private func dayKey(_ date: Date) -> String {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        return df.string(from: date)
    }

    private func ms(from start: DispatchTime) -> Int64 {
        Int64((DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000)
    }
}

// MARK: - Detailed Stats

struct DetailedPipelineStats {
    let isRunning: Bool
    let daysProcessed: Int
    let eventsCreated: Int
    let tasksCreated: Int
    let reflectionRetries: Int
    let itemsDisputed: Int
    let cacheHitRate: Double
    let totalAPICalls: Int
    let cacheHits: Int

    var description: String {
        """
        Pipeline Stats:
        - Running: \(isRunning)
        - Days processed: \(daysProcessed)
        - Events created: \(eventsCreated)
        - Tasks created: \(tasksCreated)
        - Reflection retries: \(reflectionRetries)
        - Items disputed: \(itemsDisputed)
        - Cache hit rate: \(String(format: "%.1f%%", cacheHitRate * 100))
        - API calls: \(totalAPICalls) (cached: \(cacheHits))
        """
    }
}
