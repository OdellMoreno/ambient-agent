import Foundation

// MARK: - Gemini Service
// Uses Gemini Flash for fast, cheap AI analysis

@MainActor
class GeminiService: ObservableObject {
    static let shared = GeminiService()

    @Published var isAnalyzing = false
    @Published var lastAnalysis: ConversationAnalysis?
    @Published var relationshipSummaries: [String: RelationshipSummary] = [:]
    @Published var detectedEvents: [DetectedEvent] = []
    @Published var reachOutSuggestions: [ReachOutSuggestion] = []

    private let apiKeyKey = "gemini_api_key"

    var apiKey: String? {
        get { UserDefaults.standard.string(forKey: apiKeyKey) }
        set { UserDefaults.standard.set(newValue, forKey: apiKeyKey) }
    }

    var hasAPIKey: Bool {
        guard let key = apiKey else { return false }
        return !key.isEmpty
    }

    private init() {}

    // MARK: - Data Models

    struct ConversationAnalysis: Codable {
        let sentiment: String // positive, neutral, negative
        let topics: [String]
        let emotionalTone: String
        let keyInsights: [String]
    }

    struct RelationshipSummary: Codable, Identifiable {
        var id: String { contactId }
        let contactId: String
        let summary: String
        let relationshipType: String // friend, family, colleague, acquaintance
        let communicationStyle: String
        let sharedInterests: [String]
        let recentHighlights: [String]
    }

    struct DetectedEvent: Identifiable, Codable {
        let id: UUID
        let contactId: String
        let contactName: String
        let eventType: String // new_job, birthday, travel, milestone, health, relationship
        let description: String
        let confidence: Double
        let detectedDate: Date
    }

    struct ReachOutSuggestion: Identifiable {
        let id = UUID()
        let contactId: String
        let contactName: String
        let reason: String
        let daysSinceContact: Int
        let suggestedMessage: String?
        let priority: Priority

        enum Priority: Int, Comparable {
            case low = 1, medium = 2, high = 3
            static func < (lhs: Priority, rhs: Priority) -> Bool {
                lhs.rawValue < rhs.rawValue
            }
        }
    }

    // MARK: - API Calls

    func analyzeConversation(messages: [String]) async throws -> ConversationAnalysis {
        guard let key = apiKey, !key.isEmpty else {
            throw GeminiError.noAPIKey
        }

        isAnalyzing = true
        defer { isAnalyzing = false }

        let prompt = """
        Analyze these messages and return JSON with:
        - sentiment: "positive", "neutral", or "negative"
        - topics: array of main topics discussed
        - emotionalTone: brief description of emotional tone
        - keyInsights: array of 2-3 key insights about this conversation

        Messages:
        \(messages.prefix(50).joined(separator: "\n"))

        Return only valid JSON, no markdown.
        """

        let response = try await callGemini(prompt: prompt)
        let analysis = try JSONDecoder().decode(ConversationAnalysis.self, from: Data(response.utf8))
        lastAnalysis = analysis
        return analysis
    }

    func generateRelationshipSummary(contactId: String, contactName: String, messages: [String], metadata: ContactMetadata) async throws -> RelationshipSummary {
        guard let key = apiKey, !key.isEmpty else {
            throw GeminiError.noAPIKey
        }

        isAnalyzing = true
        defer { isAnalyzing = false }

        let prompt = """
        Based on these messages and metadata, generate a relationship summary. Return JSON with:
        - contactId: "\(contactId)"
        - summary: 2-3 sentence summary of this relationship
        - relationshipType: "friend", "family", "colleague", or "acquaintance"
        - communicationStyle: brief description of how they communicate
        - sharedInterests: array of shared interests/topics
        - recentHighlights: array of recent notable things from conversations

        Contact: \(contactName)
        Message count: \(metadata.messageCount)
        Reactions received: \(metadata.heartReactions) hearts
        Days known: \(metadata.daysKnown)

        Recent messages (sample):
        \(messages.prefix(30).joined(separator: "\n"))

        Return only valid JSON, no markdown.
        """

        let response = try await callGemini(prompt: prompt)
        let summary = try JSONDecoder().decode(RelationshipSummary.self, from: Data(response.utf8))
        relationshipSummaries[contactId] = summary
        return summary
    }

    func detectLifeEvents(contactId: String, contactName: String, messages: [String]) async throws -> [DetectedEvent] {
        guard let key = apiKey, !key.isEmpty else {
            throw GeminiError.noAPIKey
        }

        isAnalyzing = true
        defer { isAnalyzing = false }

        let prompt = """
        Analyze these messages for life events. Look for mentions of:
        - New job, promotion, career changes
        - Moving, travel plans
        - Birthdays, anniversaries
        - Health updates
        - Relationship changes
        - Major purchases or milestones

        Return a JSON array of detected events:
        [{"eventType": "new_job", "description": "Started new role at X", "confidence": 0.8}]

        If no events detected, return empty array: []

        Contact: \(contactName)
        Messages:
        \(messages.prefix(50).joined(separator: "\n"))

        Return only valid JSON array, no markdown.
        """

        let response = try await callGemini(prompt: prompt)

        struct EventResponse: Codable {
            let eventType: String
            let description: String
            let confidence: Double
        }

        let events = try JSONDecoder().decode([EventResponse].self, from: Data(response.utf8))
        let detectedEvents = events.map { event in
            DetectedEvent(
                id: UUID(),
                contactId: contactId,
                contactName: contactName,
                eventType: event.eventType,
                description: event.description,
                confidence: event.confidence,
                detectedDate: Date()
            )
        }

        self.detectedEvents.append(contentsOf: detectedEvents)
        return detectedEvents
    }

    func generateReachOutSuggestions(contacts: [InsightsService.Contact]) async {
        var suggestions: [ReachOutSuggestion] = []

        for contact in contacts {
            let daysSince = contact.daysSinceContact

            // Suggest reaching out to close contacts we haven't talked to recently
            if contact.relationshipStrength >= 0.6 && daysSince >= 14 {
                suggestions.append(ReachOutSuggestion(
                    contactId: contact.id,
                    contactName: contact.displayName ?? contact.phoneOrEmail,
                    reason: "You usually talk more often - it's been \(daysSince) days",
                    daysSinceContact: daysSince,
                    suggestedMessage: nil,
                    priority: daysSince > 30 ? .high : .medium
                ))
            }
            // Contacts with high engagement who've gone quiet
            else if contact.heartReactions > 10 && daysSince >= 21 {
                suggestions.append(ReachOutSuggestion(
                    contactId: contact.id,
                    contactName: contact.displayName ?? contact.phoneOrEmail,
                    reason: "Close connection - haven't heard from them in \(daysSince) days",
                    daysSinceContact: daysSince,
                    suggestedMessage: nil,
                    priority: .high
                ))
            }
            // Regular contacts going stale
            else if contact.messageCount >= 30 && daysSince >= 30 {
                suggestions.append(ReachOutSuggestion(
                    contactId: contact.id,
                    contactName: contact.displayName ?? contact.phoneOrEmail,
                    reason: "It's been a month since you last talked",
                    daysSinceContact: daysSince,
                    suggestedMessage: nil,
                    priority: .low
                ))
            }
        }

        reachOutSuggestions = suggestions.sorted { $0.priority > $1.priority }
    }

    // MARK: - Gemini API

    private func callGemini(prompt: String) async throws -> String {
        guard let key = apiKey else {
            throw GeminiError.noAPIKey
        }

        let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.0-flash-exp:generateContent?key=\(key)")!

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "contents": [
                ["parts": [["text": prompt]]]
            ],
            "generationConfig": [
                "temperature": 0.3,
                "maxOutputTokens": 1024
            ]
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw GeminiError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            let errorText = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw GeminiError.apiError(statusCode: httpResponse.statusCode, message: errorText)
        }

        struct GeminiResponse: Codable {
            struct Candidate: Codable {
                struct Content: Codable {
                    struct Part: Codable {
                        let text: String?
                    }
                    let parts: [Part]
                }
                let content: Content
            }
            let candidates: [Candidate]?
        }

        let geminiResponse = try JSONDecoder().decode(GeminiResponse.self, from: data)
        guard let text = geminiResponse.candidates?.first?.content.parts.first?.text else {
            throw GeminiError.noContent
        }

        // Clean up response - remove markdown code blocks if present
        var cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasPrefix("```json") {
            cleaned = String(cleaned.dropFirst(7))
        }
        if cleaned.hasPrefix("```") {
            cleaned = String(cleaned.dropFirst(3))
        }
        if cleaned.hasSuffix("```") {
            cleaned = String(cleaned.dropLast(3))
        }

        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Helpers

    struct ContactMetadata {
        let messageCount: Int
        let heartReactions: Int
        let daysKnown: Int
    }

    enum GeminiError: LocalizedError {
        case noAPIKey
        case invalidResponse
        case apiError(statusCode: Int, message: String)
        case noContent

        var errorDescription: String? {
            switch self {
            case .noAPIKey:
                return "No Gemini API key configured"
            case .invalidResponse:
                return "Invalid response from Gemini"
            case .apiError(let code, let message):
                return "Gemini API error (\(code)): \(message)"
            case .noContent:
                return "No content in Gemini response"
            }
        }
    }
}
