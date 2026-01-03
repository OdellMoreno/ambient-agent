import Foundation
import AmbientCore

/// Pre-LLM filtering to avoid unnecessary API calls
actor SmartFilter {

    // MARK: - Spam/Promotional Patterns

    private let spamSenderPatterns: Set<String> = [
        "noreply@", "no-reply@", "mailer-daemon@", "notifications@",
        "newsletter@", "marketing@", "promo@", "deals@", "offers@",
        "unsubscribe@", "bounce@", "postmaster@"
    ]

    private let promotionalKeywords: Set<String> = [
        "unsubscribe", "% off", "sale ends", "limited time", "act now",
        "click here", "buy now", "free trial", "special offer", "exclusive deal",
        "weekly digest", "newsletter", "promotional", "advertisement"
    ]

    private let automatedPatterns: [String] = [
        "this is an automated message",
        "do not reply to this email",
        "this email was sent automatically",
        "auto-generated",
        "delivery status notification",
        "out of office",
        "automatic reply"
    ]

    // MARK: - Actionable Content Patterns

    private let actionableKeywords: Set<String> = [
        "meeting", "call", "appointment", "schedule", "tomorrow", "today",
        "deadline", "due", "remind", "rsvp", "confirm", "attend", "join",
        "invite", "calendar", "event", "task", "todo", "action", "urgent",
        "asap", "please", "need", "eod", "eow", "by friday", "by monday",
        "next week", "this week", "lunch", "dinner", "coffee", "sync",
        "standup", "review", "demo", "presentation", "interview"
    ]

    private let timePatterns: [String] = [
        #"\d{1,2}:\d{2}"#,                    // 10:30
        #"\d{1,2}(am|pm|AM|PM)"#,             // 3pm
        #"\d{1,2}\s*(am|pm|AM|PM)"#,          // 3 pm
        #"(monday|tuesday|wednesday|thursday|friday|saturday|sunday)"#,
        #"(mon|tue|wed|thu|fri|sat|sun)\b"#,
        #"(january|february|march|april|may|june|july|august|september|october|november|december)"#,
        #"(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)\b"#,
        #"\d{1,2}/\d{1,2}"#,                  // 12/25
        #"\d{1,2}-\d{1,2}"#,                  // 12-25
        #"tomorrow|today|tonight|next week|this week"#
    ]

    // MARK: - Content Hash Cache (for deduplication)

    private var recentContentHashes: [String: Date] = [:]
    private let hashExpirationInterval: TimeInterval = 3600 // 1 hour

    // MARK: - Public API

    func evaluate(_ item: RawItem) -> FilterDecision {
        let content = item.content?.lowercased() ?? ""

        // 1. Too short
        if content.count < 20 {
            return .skip(reason: .tooShort)
        }

        // 2. Check for duplicates
        let contentHash = generateContentHash(content)
        if isDuplicate(hash: contentHash) {
            return .skip(reason: .duplicate)
        }

        // 3. Already processed with current version
        if item.extractionVersion == ExtractionConfig.currentVersion {
            return .skip(reason: .alreadyProcessed)
        }

        // 4. Source-specific filtering
        switch item.sourceType {
        case .email, .gmail:
            return evaluateEmail(item, content: content, hash: contentHash)
        case .messages:
            return evaluateMessage(item, content: content, hash: contentHash)
        case .calendar:
            // Calendar items always get processed
            markProcessed(hash: contentHash)
            return .process(priority: .realtime)
        case .safari:
            return evaluateWebContent(item, content: content, hash: contentHash)
        case .notes:
            return evaluateNotes(item, content: content, hash: contentHash)
        default:
            return evaluateGeneric(content: content, hash: contentHash)
        }
    }

    // MARK: - Source-Specific Evaluation

    private func evaluateEmail(_ item: RawItem, content: String, hash: String) -> FilterDecision {
        // Check sender
        if let sender = item.participants.first?.lowercased() {
            for pattern in spamSenderPatterns {
                if sender.contains(pattern) {
                    return .skip(reason: .automated)
                }
            }
        }

        // Check subject for promotional content
        if let subject = item.subject?.lowercased() {
            for keyword in promotionalKeywords {
                if subject.contains(keyword) {
                    return .skip(reason: .promotional)
                }
            }
        }

        // Check for automated messages
        for pattern in automatedPatterns {
            if content.contains(pattern) {
                return .skip(reason: .automated)
            }
        }

        // Check actionable score
        let score = calculateActionableScore(content)
        if score < 0.2 {
            return .skip(reason: .noActionableContent)
        }

        markProcessed(hash: hash)
        return .process(priority: score > 0.6 ? .high : .normal)
    }

    private func evaluateMessage(_ item: RawItem, content: String, hash: String) -> FilterDecision {
        // Messages are usually personal, so lower threshold
        let score = calculateActionableScore(content)

        // Questions often indicate requests
        let hasQuestion = content.contains("?")

        if score < 0.15 && !hasQuestion {
            return .skip(reason: .noActionableContent)
        }

        markProcessed(hash: hash)

        // Higher priority if it has time references
        let hasTimeRef = hasTimeReferences(content)
        return .process(priority: hasTimeRef ? .high : .normal)
    }

    private func evaluateWebContent(_ item: RawItem, content: String, hash: String) -> FilterDecision {
        // Look for booking/ticket keywords
        let bookingKeywords = ["ticket", "confirmation", "booking", "reservation", "itinerary", "receipt", "order"]
        let hasBookingContent = bookingKeywords.contains { content.contains($0) }

        if !hasBookingContent {
            let score = calculateActionableScore(content)
            if score < 0.3 {
                return .skip(reason: .noActionableContent)
            }
        }

        markProcessed(hash: hash)
        return .process(priority: .low)
    }

    private func evaluateNotes(_ item: RawItem, content: String, hash: String) -> FilterDecision {
        let score = calculateActionableScore(content)

        // Notes with todo-like content
        let hasTodoMarkers = content.contains("[ ]") || content.contains("- [ ]") ||
                            content.contains("todo") || content.contains("task")

        if score < 0.2 && !hasTodoMarkers {
            return .skip(reason: .noActionableContent)
        }

        markProcessed(hash: hash)
        return .process(priority: .normal)
    }

    private func evaluateGeneric(content: String, hash: String) -> FilterDecision {
        let score = calculateActionableScore(content)

        if score < 0.25 {
            return .skip(reason: .noActionableContent)
        }

        markProcessed(hash: hash)
        return .process(priority: .normal)
    }

    // MARK: - Scoring

    private func calculateActionableScore(_ content: String) -> Float {
        var score: Float = 0.0
        let words = Set(content.lowercased().split(separator: " ").map { String($0) })

        // Keyword matching
        let matchedKeywords = words.intersection(actionableKeywords)
        score += Float(matchedKeywords.count) * 0.1

        // Time pattern matching
        if hasTimeReferences(content) {
            score += 0.3
        }

        // Question marks (often indicate requests)
        let questionCount = content.filter { $0 == "?" }.count
        score += min(Float(questionCount) * 0.05, 0.15)

        // Imperative verbs at start of sentences
        let imperativeVerbs = ["please", "can you", "could you", "would you", "let's", "we should", "need to", "have to"]
        for verb in imperativeVerbs {
            if content.contains(verb) {
                score += 0.1
                break
            }
        }

        return min(score, 1.0)
    }

    private func hasTimeReferences(_ content: String) -> Bool {
        for pattern in timePatterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                let range = NSRange(content.startIndex..., in: content)
                if regex.firstMatch(in: content, range: range) != nil {
                    return true
                }
            }
        }
        return false
    }

    // MARK: - Deduplication

    private func generateContentHash(_ content: String) -> String {
        // Normalize content
        var normalized = content.lowercased()
        normalized = normalized.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        normalized = normalized.trimmingCharacters(in: .whitespacesAndNewlines)

        // Truncate for hashing
        if normalized.count > 500 {
            normalized = String(normalized.prefix(500))
        }

        // Simple hash (in production, use SHA256)
        return String(normalized.hashValue)
    }

    private func isDuplicate(hash: String) -> Bool {
        cleanExpiredHashes()

        if let existingTime = recentContentHashes[hash] {
            return Date().timeIntervalSince(existingTime) < hashExpirationInterval
        }
        return false
    }

    private func markProcessed(hash: String) {
        recentContentHashes[hash] = Date()
    }

    private func cleanExpiredHashes() {
        let now = Date()
        recentContentHashes = recentContentHashes.filter { _, time in
            now.timeIntervalSince(time) < hashExpirationInterval
        }
    }
}
