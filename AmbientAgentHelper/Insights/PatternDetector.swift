import Foundation
import AmbientCore

// MARK: - Pattern Detector
// Real-time pattern detection for incoming data

actor PatternDetector {

    // MARK: - Streak Detection

    struct Streak {
        let contact: String
        let startDate: Date
        let dayCount: Int
        let messageCount: Int
        let isActive: Bool
    }

    func detectConversationStreaks(
        messages: [(contact: String, date: Date)]
    ) -> [Streak] {
        var contactDays: [String: Set<String>] = [:]
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"

        for (contact, date) in messages {
            let dayKey = formatter.string(from: date)
            contactDays[contact, default: []].insert(dayKey)
        }

        var streaks: [Streak] = []

        for (contact, days) in contactDays {
            let sortedDays = days.sorted()
            guard let firstDay = sortedDays.first,
                  let startDate = formatter.date(from: firstDay) else { continue }

            // Check for consecutive days
            var consecutiveDays = 1
            var currentDate = startDate

            for i in 1..<sortedDays.count {
                guard let nextDate = formatter.date(from: sortedDays[i]) else { continue }
                let dayDiff = Calendar.current.dateComponents([.day], from: currentDate, to: nextDate).day ?? 0

                if dayDiff == 1 {
                    consecutiveDays += 1
                } else if dayDiff > 1 {
                    if consecutiveDays >= 3 {
                        streaks.append(Streak(
                            contact: contact,
                            startDate: startDate,
                            dayCount: consecutiveDays,
                            messageCount: days.count,
                            isActive: false
                        ))
                    }
                    consecutiveDays = 1
                }
                currentDate = nextDate
            }

            // Check if current streak is active (includes today or yesterday)
            let today = formatter.string(from: Date())
            let yesterday = formatter.string(from: Date().addingTimeInterval(-86400))
            let isActive = days.contains(today) || days.contains(yesterday)

            if consecutiveDays >= 3 {
                streaks.append(Streak(
                    contact: contact,
                    startDate: startDate,
                    dayCount: consecutiveDays,
                    messageCount: messages.filter { $0.contact == contact }.count,
                    isActive: isActive
                ))
            }
        }

        return streaks.sorted { $0.dayCount > $1.dayCount }
    }

    // MARK: - Response Time Analysis

    struct ResponsePattern {
        let contact: String
        let avgResponseTimeMinutes: Double
        let fastestResponseMinutes: Double
        let slowestResponseMinutes: Double
        let responseRate: Double  // What % of messages get replies
    }

    func analyzeResponseTimes(
        messages: [(contact: String, isFromMe: Bool, timestamp: Date)]
    ) -> [ResponsePattern] {
        var contactMessages: [String: [(isFromMe: Bool, timestamp: Date)]] = [:]

        for msg in messages {
            contactMessages[msg.contact, default: []].append((msg.isFromMe, msg.timestamp))
        }

        var patterns: [ResponsePattern] = []

        for (contact, msgs) in contactMessages {
            let sorted = msgs.sorted { $0.timestamp < $1.timestamp }
            var responseTimes: [TimeInterval] = []

            for i in 1..<sorted.count {
                let prev = sorted[i-1]
                let curr = sorted[i]

                // If I sent a message and they replied (or vice versa)
                if prev.isFromMe != curr.isFromMe {
                    let responseTime = curr.timestamp.timeIntervalSince(prev.timestamp)
                    // Only count responses within 24 hours
                    if responseTime > 0 && responseTime < 86400 {
                        responseTimes.append(responseTime)
                    }
                }
            }

            guard !responseTimes.isEmpty else { continue }

            let avgMinutes = responseTimes.reduce(0, +) / Double(responseTimes.count) / 60
            let fastestMinutes = (responseTimes.min() ?? 0) / 60
            let slowestMinutes = (responseTimes.max() ?? 0) / 60

            let myMessages = sorted.filter { $0.isFromMe }.count
            let theirMessages = sorted.filter { !$0.isFromMe }.count
            let responseRate = myMessages > 0 ? Double(theirMessages) / Double(myMessages) : 0

            patterns.append(ResponsePattern(
                contact: contact,
                avgResponseTimeMinutes: avgMinutes,
                fastestResponseMinutes: fastestMinutes,
                slowestResponseMinutes: slowestMinutes,
                responseRate: min(responseRate, 2.0)
            ))
        }

        return patterns.sorted { $0.avgResponseTimeMinutes < $1.avgResponseTimeMinutes }
    }

    // MARK: - Topic Detection

    struct TopicCluster {
        let topic: String
        let keywords: [String]
        let messageCount: Int
        let contacts: [String]
        let timeRange: (start: Date, end: Date)
        let sentiment: Double  // -1 to 1
    }

    func detectTopics(
        messages: [(content: String, contact: String, timestamp: Date)]
    ) -> [TopicCluster] {
        let topicKeywords: [String: [String]] = [
            "Work": ["meeting", "deadline", "project", "boss", "office", "work", "job", "client", "email"],
            "Travel": ["flight", "hotel", "trip", "vacation", "airport", "travel", "booking"],
            "Health": ["doctor", "sick", "hospital", "medicine", "appointment", "health", "feeling"],
            "Social": ["party", "dinner", "drinks", "hangout", "meet up", "plans", "weekend"],
            "Family": ["mom", "dad", "brother", "sister", "family", "parents", "kids"],
            "Finance": ["money", "pay", "rent", "bill", "bank", "loan", "budget"],
            "Relationship": ["love", "miss", "together", "dating", "relationship", "breakup", "ex"],
            "Moving": ["apartment", "lease", "move", "packing", "furniture", "landlord"],
            "Tech": ["app", "code", "bug", "deploy", "api", "server", "database"]
        ]

        var clusters: [String: (messages: [String], contacts: Set<String>, dates: [Date])] = [:]

        for (content, contact, timestamp) in messages {
            let lower = content.lowercased()

            for (topic, keywords) in topicKeywords {
                if keywords.contains(where: { lower.contains($0) }) {
                    var cluster = clusters[topic] ?? ([], [], [])
                    cluster.messages.append(content)
                    cluster.contacts.insert(contact)
                    cluster.dates.append(timestamp)
                    clusters[topic] = cluster
                }
            }
        }

        return clusters.compactMap { topic, data -> TopicCluster? in
            guard data.messages.count >= 5 else { return nil }

            let sortedDates = data.dates.sorted()

            return TopicCluster(
                topic: topic,
                keywords: topicKeywords[topic] ?? [],
                messageCount: data.messages.count,
                contacts: Array(data.contacts),
                timeRange: (sortedDates.first!, sortedDates.last!),
                sentiment: estimateSentiment(data.messages)
            )
        }.sorted { $0.messageCount > $1.messageCount }
    }

    // MARK: - Sentiment Estimation

    private func estimateSentiment(_ texts: [String]) -> Double {
        let positiveWords = Set(["happy", "great", "love", "awesome", "excited", "good",
                                  "amazing", "wonderful", "best", "glad", "thanks", "appreciate",
                                  "perfect", "beautiful", "fun", "enjoy", "excellent"])

        let negativeWords = Set(["sad", "angry", "hate", "terrible", "awful", "bad",
                                  "worst", "upset", "frustrated", "annoyed", "disappointed",
                                  "hurt", "pain", "sorry", "unfortunately", "problem", "issue",
                                  "wrong", "fail", "stupid", "crazy", "stressed"])

        var positiveCount = 0
        var negativeCount = 0

        for text in texts {
            let words = text.lowercased().components(separatedBy: .alphanumerics.inverted)
            positiveCount += words.filter { positiveWords.contains($0) }.count
            negativeCount += words.filter { negativeWords.contains($0) }.count
        }

        let total = positiveCount + negativeCount
        guard total > 0 else { return 0 }

        return Double(positiveCount - negativeCount) / Double(total)
    }

    // MARK: - Anomaly Detection

    struct TimeAnomaly {
        let date: Date
        let hour: Int
        let unusualActivity: String
        let severity: Double  // 0-1
    }

    func detectTimeAnomalies(
        recentPattern: [Int: Int],  // hour -> count for recent period
        baselinePattern: [Int: Int] // hour -> count for baseline
    ) -> [TimeAnomaly] {
        var anomalies: [TimeAnomaly] = []

        for hour in 0..<24 {
            let recent = recentPattern[hour] ?? 0
            let baseline = baselinePattern[hour] ?? 1

            let ratio = Double(recent) / Double(max(baseline, 1))

            if ratio > 3.0 {
                anomalies.append(TimeAnomaly(
                    date: Date(),
                    hour: hour,
                    unusualActivity: "Activity at \(hour):00 is \(String(format: "%.1f", ratio))x higher than usual",
                    severity: min(1.0, (ratio - 1) / 5)
                ))
            }
        }

        return anomalies.sorted { $0.severity > $1.severity }
    }
}

// MARK: - Contact Insights

struct ContactInsight: Identifiable {
    let id = UUID()
    let contact: String
    let displayName: String?
    let messageCount: Int
    let relationshipStrength: Double
    let lastContact: Date
    let topTopics: [String]
    let communicationTrend: PatternDetector.Streak?
    let responsePattern: PatternDetector.ResponsePattern?

    var strengthDescription: String {
        switch relationshipStrength {
        case 0.8...1.0: return "Very Close"
        case 0.6..<0.8: return "Close"
        case 0.4..<0.6: return "Regular"
        case 0.2..<0.4: return "Occasional"
        default: return "Infrequent"
        }
    }

    var daysSinceContact: Int {
        Calendar.current.dateComponents([.day], from: lastContact, to: Date()).day ?? 0
    }
}

// MARK: - Daily Digest

struct DailyDigest {
    let date: Date
    let messagesSent: Int
    let messagesReceived: Int
    let uniqueContacts: Int
    let topContact: String?
    let dominantTopic: String?
    let moodIndicator: Double  // -1 to 1
    let unusualPatterns: [String]
    let actionItems: [String]

    var summary: String {
        var parts: [String] = []

        parts.append("\(messagesSent + messagesReceived) messages with \(uniqueContacts) contacts")

        if let top = topContact {
            parts.append("Most active: \(top)")
        }

        if let topic = dominantTopic {
            parts.append("Main topic: \(topic)")
        }

        if moodIndicator < -0.3 {
            parts.append("Challenging day detected")
        } else if moodIndicator > 0.3 {
            parts.append("Positive vibes!")
        }

        return parts.joined(separator: " • ")
    }
}
