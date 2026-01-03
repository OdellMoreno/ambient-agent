import Foundation
import AmbientCore

// MARK: - Insights Engine
// Extracts patterns, anomalies, and life events from user data

actor InsightsEngine {

    // MARK: - Insight Types

    enum InsightType: String, Codable {
        case volumeSpike = "volume_spike"
        case sleepDisruption = "sleep_disruption"
        case newRelationship = "new_relationship"
        case relationshipChange = "relationship_change"
        case lifeMilestone = "life_milestone"
        case supportNetworkActive = "support_network_active"
        case stressIndicator = "stress_indicator"
        case routineChange = "routine_change"
        case interestCluster = "interest_cluster"
    }

    enum InsightPriority: Int, Codable, Comparable {
        case low = 1
        case medium = 2
        case high = 3
        case critical = 4

        static func < (lhs: InsightPriority, rhs: InsightPriority) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    struct Insight: Codable, Identifiable {
        let id: UUID
        let type: InsightType
        let title: String
        let description: String
        let priority: InsightPriority
        let detectedAt: Date
        let dataPoints: [String: String]
        let actionable: Bool
        let suggestedAction: String?
    }

    // MARK: - Analysis Results

    struct CommunicationPattern {
        let contact: String
        let messageCount: Int
        let firstMessage: Date
        let lastMessage: Date
        let avgResponseTime: TimeInterval?
        let peakHours: [Int]
        let sentiment: SentimentScore?
    }

    struct SentimentScore {
        let positive: Double
        let negative: Double
        let neutral: Double
        let dominantEmotion: String?
    }

    struct TimePattern {
        let hourlyDistribution: [Int: Int]  // hour -> count
        let dailyDistribution: [Date: Int]  // day -> count
        let weekdayDistribution: [Int: Int] // weekday -> count
    }

    struct VolumeAnomaly {
        let date: Date
        let count: Int
        let baseline: Double
        let deviationMultiple: Double
        let relatedContacts: [String]
    }

    // MARK: - Configuration

    private let volumeSpikeThreshold: Double = 2.5  // 2.5x baseline
    private let sleepHoursStart = 0  // midnight
    private let sleepHoursEnd = 5    // 5am
    private let sleepMessageThreshold = 10  // messages in sleep hours = disruption

    // MARK: - Analysis Methods

    func analyzeMessageVolume(dailyCounts: [Date: Int]) -> [VolumeAnomaly] {
        guard dailyCounts.count >= 7 else { return [] }

        let counts = Array(dailyCounts.values)
        let baseline = Double(counts.reduce(0, +)) / Double(counts.count)
        let stdDev = standardDeviation(counts.map { Double($0) })

        var anomalies: [VolumeAnomaly] = []

        for (date, count) in dailyCounts {
            let deviation = (Double(count) - baseline) / max(stdDev, 1)
            if deviation >= volumeSpikeThreshold {
                anomalies.append(VolumeAnomaly(
                    date: date,
                    count: count,
                    baseline: baseline,
                    deviationMultiple: Double(count) / baseline,
                    relatedContacts: []
                ))
            }
        }

        return anomalies.sorted { $0.deviationMultiple > $1.deviationMultiple }
    }

    func detectSleepDisruption(hourlyPattern: [Int: Int]) -> Insight? {
        let sleepHourMessages = (sleepHoursStart...sleepHoursEnd).reduce(0) {
            $0 + (hourlyPattern[$1] ?? 0)
        }

        guard sleepHourMessages >= sleepMessageThreshold else { return nil }

        let totalMessages = hourlyPattern.values.reduce(0, +)
        let sleepPercentage = Double(sleepHourMessages) / Double(max(totalMessages, 1)) * 100

        return Insight(
            id: UUID(),
            type: .sleepDisruption,
            title: "Sleep Pattern Disruption Detected",
            description: "Significant messaging activity during sleep hours (midnight-5am). \(sleepHourMessages) messages (\(String(format: "%.1f", sleepPercentage))% of total) sent during typical sleep time.",
            priority: sleepPercentage > 10 ? .high : .medium,
            detectedAt: Date(),
            dataPoints: [
                "sleep_hour_messages": "\(sleepHourMessages)",
                "sleep_percentage": String(format: "%.1f%%", sleepPercentage),
                "peak_sleep_hour": peakHour(in: hourlyPattern, range: sleepHoursStart...sleepHoursEnd)
            ],
            actionable: true,
            suggestedAction: "Consider setting a wind-down reminder or enabling Do Not Disturb during sleep hours."
        )
    }

    func identifySupportNetwork(patterns: [CommunicationPattern]) -> [String] {
        // Support network = high frequency + recent + consistent
        return patterns
            .filter { $0.messageCount > 50 }  // Significant volume
            .filter { $0.lastMessage.timeIntervalSinceNow > -86400 * 7 }  // Active last week
            .sorted { $0.messageCount > $1.messageCount }
            .prefix(5)
            .map { $0.contact }
    }

    func detectLifeEvent(
        volumeAnomalies: [VolumeAnomaly],
        keywords: [String: Int]
    ) -> Insight? {
        guard let biggestSpike = volumeAnomalies.first,
              biggestSpike.deviationMultiple >= 3.0 else { return nil }

        // Look for life event keywords
        let lifeEventKeywords = [
            "breakup": ["ex", "broke up", "over", "moving out", "blocked", "relationship"],
            "job": ["fired", "quit", "new job", "interview", "offer", "promotion"],
            "move": ["moving", "apartment", "lease", "new place", "packing"],
            "health": ["hospital", "doctor", "sick", "surgery", "diagnosed"],
            "family": ["pregnant", "baby", "married", "engaged", "funeral", "passed"]
        ]

        var detectedEvent: String?
        var maxMatches = 0

        for (event, terms) in lifeEventKeywords {
            let matches = terms.reduce(0) { $0 + (keywords[$1.lowercased()] ?? 0) }
            if matches > maxMatches {
                maxMatches = matches
                detectedEvent = event
            }
        }

        guard let event = detectedEvent, maxMatches >= 3 else { return nil }

        return Insight(
            id: UUID(),
            type: .lifeMilestone,
            title: "Significant Life Event Detected",
            description: "Communication patterns suggest a major \(event)-related event around \(formatDate(biggestSpike.date)). Message volume was \(String(format: "%.1f", biggestSpike.deviationMultiple))x normal.",
            priority: .high,
            detectedAt: Date(),
            dataPoints: [
                "event_type": event,
                "spike_date": formatDate(biggestSpike.date),
                "volume_multiple": String(format: "%.1fx", biggestSpike.deviationMultiple),
                "keyword_matches": "\(maxMatches)"
            ],
            actionable: false,
            suggestedAction: nil
        )
    }

    func analyzeInterests(browsingHistory: [(url: String, title: String, date: Date)]) -> [String: [String]] {
        var clusters: [String: [String]] = [:]

        let categories: [String: [String]] = [
            "AI/Tech": ["openai", "anthropic", "llm", "gpt", "claude", "nvidia", "github", "stackoverflow"],
            "Entertainment": ["netflix", "youtube", "spotify", "gaming", "movie", "tv show"],
            "Shopping": ["amazon", "ebay", "shop", "buy", "cart", "checkout"],
            "Social": ["twitter", "instagram", "facebook", "reddit", "linkedin"],
            "News": ["news", "cnn", "bbc", "nytimes", "wsj"],
            "Finance": ["bank", "invest", "stock", "crypto", "trading"],
            "Travel": ["flight", "hotel", "airbnb", "booking", "travel"],
            "Health": ["health", "fitness", "medical", "doctor", "pharmacy"]
        ]

        for (url, title, _) in browsingHistory {
            let combined = (url + " " + title).lowercased()
            for (category, keywords) in categories {
                if keywords.contains(where: { combined.contains($0) }) {
                    clusters[category, default: []].append(title)
                }
            }
        }

        return clusters
    }

    // MARK: - Relationship Analysis

    struct RelationshipDynamics {
        let contact: String
        let communicationStyle: CommunicationStyle
        let relationshipStrength: Double  // 0-1
        let recentTrend: Trend
        let notablePatterns: [String]
    }

    enum CommunicationStyle {
        case frequent      // Many short messages
        case substantive   // Fewer, longer messages
        case responsive    // Quick replies
        case async         // Delayed responses
    }

    enum Trend {
        case increasing, stable, decreasing
    }

    func analyzeRelationship(messages: [(content: String, isFromMe: Bool, timestamp: Date)]) -> RelationshipDynamics? {
        guard messages.count >= 10 else { return nil }

        let myMessages = messages.filter { $0.isFromMe }
        let theirMessages = messages.filter { !$0.isFromMe }

        // Calculate response patterns
        let avgMyLength = Double(myMessages.reduce(0) { $0 + $1.content.count }) / Double(max(myMessages.count, 1))
        let avgTheirLength = Double(theirMessages.reduce(0) { $0 + $1.content.count }) / Double(max(theirMessages.count, 1))

        // Determine communication style
        let style: CommunicationStyle
        if avgMyLength < 50 && avgTheirLength < 50 {
            style = .frequent
        } else if avgMyLength > 200 || avgTheirLength > 200 {
            style = .substantive
        } else {
            style = .responsive
        }

        // Calculate trend (compare first half vs second half)
        let midpoint = messages.count / 2
        let firstHalf = messages.prefix(midpoint).count
        let secondHalf = messages.suffix(midpoint).count

        let trend: Trend
        if secondHalf > firstHalf * 12 / 10 {
            trend = .increasing
        } else if secondHalf < firstHalf * 8 / 10 {
            trend = .decreasing
        } else {
            trend = .stable
        }

        return RelationshipDynamics(
            contact: "",
            communicationStyle: style,
            relationshipStrength: min(1.0, Double(messages.count) / 1000.0),
            recentTrend: trend,
            notablePatterns: []
        )
    }

    // MARK: - Helpers

    private func standardDeviation(_ values: [Double]) -> Double {
        let mean = values.reduce(0, +) / Double(values.count)
        let squaredDiffs = values.map { pow($0 - mean, 2) }
        return sqrt(squaredDiffs.reduce(0, +) / Double(values.count))
    }

    private func peakHour(in distribution: [Int: Int], range: ClosedRange<Int>) -> String {
        let peak = range.max { (distribution[$0] ?? 0) < (distribution[$1] ?? 0) }
        return peak.map { "\($0):00" } ?? "unknown"
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        return formatter.string(from: date)
    }
}

// MARK: - Wellbeing Score

struct WellbeingScore {
    let overall: Double  // 0-100
    let sleepQuality: Double
    let socialConnection: Double
    let stressLevel: Double
    let activityBalance: Double

    var summary: String {
        switch overall {
        case 80...100: return "Thriving"
        case 60..<80: return "Good"
        case 40..<60: return "Fair"
        case 20..<40: return "Struggling"
        default: return "Needs attention"
        }
    }

    static func calculate(
        sleepHourMessages: Int,
        supportNetworkSize: Int,
        messageVolumeDeviation: Double,
        recentActivityHours: [Int]
    ) -> WellbeingScore {
        // Sleep quality: fewer sleep-hour messages = better
        let sleepQuality = max(0, 100 - Double(sleepHourMessages) * 5)

        // Social connection: more support contacts = better
        let socialConnection = min(100, Double(supportNetworkSize) * 20)

        // Stress level: high deviation = high stress
        let stressLevel = min(100, messageVolumeDeviation * 20)

        // Activity balance: spread across hours = better
        let uniqueHours = Set(recentActivityHours).count
        let activityBalance = min(100, Double(uniqueHours) * 10)

        let overall = (sleepQuality + socialConnection + (100 - stressLevel) + activityBalance) / 4

        return WellbeingScore(
            overall: overall,
            sleepQuality: sleepQuality,
            socialConnection: socialConnection,
            stressLevel: stressLevel,
            activityBalance: activityBalance
        )
    }
}

// MARK: - Keyword Extractor

enum KeywordExtractor {
    static func extract(from texts: [String], topN: Int = 50) -> [String: Int] {
        let stopWords = Set(["the", "a", "an", "is", "are", "was", "were", "be", "been",
                            "being", "have", "has", "had", "do", "does", "did", "will",
                            "would", "could", "should", "may", "might", "must", "shall",
                            "can", "need", "to", "of", "in", "for", "on", "with", "at",
                            "by", "from", "as", "into", "through", "during", "before",
                            "after", "above", "below", "between", "under", "again",
                            "further", "then", "once", "here", "there", "when", "where",
                            "why", "how", "all", "each", "few", "more", "most", "other",
                            "some", "such", "no", "nor", "not", "only", "own", "same",
                            "so", "than", "too", "very", "just", "and", "but", "if",
                            "or", "because", "until", "while", "this", "that", "these",
                            "those", "i", "me", "my", "myself", "we", "our", "ours",
                            "you", "your", "yours", "he", "him", "his", "she", "her",
                            "hers", "it", "its", "they", "them", "their", "what",
                            "which", "who", "whom", "yeah", "yes", "no", "ok", "okay",
                            "like", "just", "really", "actually", "gonna", "going",
                            "lol", "lmao", "haha", "don't", "didn't", "can't", "won't",
                            "it's", "i'm", "i've", "you're", "that's", "what's"])

        var wordCounts: [String: Int] = [:]

        for text in texts {
            let words = text.lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { $0.count > 2 && !stopWords.contains($0) }

            for word in words {
                wordCounts[word, default: 0] += 1
            }
        }

        return Dictionary(
            wordCounts.sorted { $0.value > $1.value }.prefix(topN),
            uniquingKeysWith: { first, _ in first }
        )
    }

    static func extractActionItems(from text: String) -> [String] {
        let actionPatterns = [
            "need to", "have to", "should", "must", "don't forget",
            "remind me", "make sure", "remember to", "by friday",
            "by monday", "tomorrow", "deadline", "due", "asap"
        ]

        let sentences = text.components(separatedBy: CharacterSet(charactersIn: ".!?\n"))

        return sentences.filter { sentence in
            let lower = sentence.lowercased()
            return actionPatterns.contains { lower.contains($0) }
        }.map { $0.trimmingCharacters(in: .whitespaces) }
    }
}
