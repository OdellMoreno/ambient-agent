import SwiftUI

// MARK: - AI Insights View
// Shows AI-powered analysis using Gemini Flash

struct AIInsightsView: View {
    @ObservedObject private var gemini = GeminiService.shared
    @ObservedObject private var insights = InsightsService.shared
    @ObservedObject private var history = HistoryService.shared

    @State private var isAnalyzing = false
    @State private var selectedContact: InsightsService.Contact?

    var body: some View {
        ScrollView {
            if !gemini.hasAPIKey {
                APIKeyPrompt()
            } else {
                VStack(spacing: 20) {
                    // Weekly Trends
                    if let trends = history.weeklyTrends {
                        WeeklyTrendsCard(trends: trends)
                    }

                    // Reach Out Suggestions
                    if !gemini.reachOutSuggestions.isEmpty {
                        ReachOutCard(suggestions: gemini.reachOutSuggestions)
                    }

                    // Detected Life Events
                    if !gemini.detectedEvents.isEmpty {
                        LifeEventsCard(events: gemini.detectedEvents)
                    }

                    // Relationship Summaries
                    if !gemini.relationshipSummaries.isEmpty {
                        RelationshipSummariesCard(summaries: Array(gemini.relationshipSummaries.values))
                    }

                    // Analyze Button
                    AnalyzeSection(isAnalyzing: $isAnalyzing) {
                        await runAnalysis()
                    }
                }
                .padding()
            }
        }
        .navigationTitle("AI Insights")
        .task {
            // Generate reach out suggestions on load
            await gemini.generateReachOutSuggestions(contacts: insights.contacts)

            // Record daily snapshot
            history.recordDailySnapshot(from: insights)
        }
    }

    private func runAnalysis() async {
        isAnalyzing = true
        defer { isAnalyzing = false }

        // Analyze top contacts
        for contact in insights.contacts.prefix(5) {
            do {
                // Get messages for this contact (simplified - would need actual message fetch)
                let metadata = GeminiService.ContactMetadata(
                    messageCount: contact.messageCount,
                    heartReactions: contact.heartReactions,
                    daysKnown: Int(Date().timeIntervalSince(contact.firstMessageDate) / 86400)
                )

                _ = try await gemini.generateRelationshipSummary(
                    contactId: contact.id,
                    contactName: contact.displayName ?? contact.phoneOrEmail,
                    messages: [], // Would need to fetch actual messages
                    metadata: metadata
                )
            } catch {
                print("Analysis error: \(error)")
            }
        }
    }
}

// MARK: - API Key Prompt

struct APIKeyPrompt: View {
    @ObservedObject private var gemini = GeminiService.shared
    @State private var apiKey = ""

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "sparkles")
                .font(.system(size: 48))
                .foregroundStyle(.purple)

            Text("Enable AI Insights")
                .font(.title2)
                .fontWeight(.bold)

            Text("Add your Gemini API key to unlock AI-powered relationship analysis, life event detection, and personalized suggestions.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            VStack(alignment: .leading, spacing: 8) {
                SecureField("Gemini API Key", text: $apiKey)
                    .textFieldStyle(.roundedBorder)

                Button("Save API Key") {
                    gemini.apiKey = apiKey
                }
                .buttonStyle(.borderedProminent)
                .disabled(apiKey.isEmpty)
            }
            .frame(maxWidth: 300)

            Link("Get API Key from Google AI Studio",
                 destination: URL(string: "https://aistudio.google.com/app/apikey")!)
                .font(.caption)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

// MARK: - Weekly Trends Card

struct WeeklyTrendsCard: View {
    let trends: HistoryService.WeeklyTrend

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Weekly Trends")
                    .font(.headline)

                Spacer()

                HStack(spacing: 4) {
                    Image(systemName: trends.trend.icon)
                    Text(String(format: "%+.1f%%", trends.percentChange))
                }
                .font(.subheadline)
                .foregroundStyle(trends.trend.color)
            }

            HStack(spacing: 20) {
                TrendStat(
                    title: "This Week",
                    value: "\(trends.thisWeekMessages)",
                    subtitle: "messages",
                    color: .blue
                )

                TrendStat(
                    title: "Last Week",
                    value: "\(trends.lastWeekMessages)",
                    subtitle: "messages",
                    color: .gray
                )

                TrendStat(
                    title: "Daily Avg",
                    value: String(format: "%.0f", trends.averageDailyMessages),
                    subtitle: "messages",
                    color: .green
                )
            }

            HStack {
                Label("Busiest: \(trends.busiestDay)", systemImage: "flame.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)

                Spacer()

                Label("Quietest: \(trends.quietestDay)", systemImage: "moon.fill")
                    .font(.caption)
                    .foregroundStyle(.purple)
            }
        }
        .padding()
        .background(Color(.controlBackgroundColor))
        .cornerRadius(12)
    }
}

struct TrendStat: View {
    let title: String
    let value: String
    let subtitle: String
    let color: Color

    var body: some View {
        VStack(spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title2)
                .fontWeight(.bold)
                .foregroundStyle(color)
            Text(subtitle)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Reach Out Card

struct ReachOutCard: View {
    let suggestions: [GeminiService.ReachOutSuggestion]
    @ObservedObject private var service = InsightsService.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Reach Out", systemImage: "hand.wave.fill")
                    .font(.headline)

                Spacer()

                Text("\(suggestions.count) suggestions")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ForEach(suggestions.prefix(5)) { suggestion in
                HStack(spacing: 12) {
                    Circle()
                        .fill(priorityColor(suggestion.priority).gradient)
                        .frame(width: 8, height: 8)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(service.privacySafeName(suggestion.contactName))
                            .font(.subheadline)
                            .fontWeight(.medium)

                        Text(suggestion.reason)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Text("\(suggestion.daysSinceContact)d")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding()
        .background(Color(.controlBackgroundColor))
        .cornerRadius(12)
    }

    private func priorityColor(_ priority: GeminiService.ReachOutSuggestion.Priority) -> Color {
        switch priority {
        case .high: return .red
        case .medium: return .orange
        case .low: return .blue
        }
    }
}

// MARK: - Life Events Card

struct LifeEventsCard: View {
    let events: [GeminiService.DetectedEvent]
    @ObservedObject private var service = InsightsService.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Detected Life Events", systemImage: "sparkles")
                .font(.headline)

            ForEach(events.prefix(5)) { event in
                HStack(spacing: 12) {
                    Image(systemName: eventIcon(event.eventType))
                        .font(.title3)
                        .foregroundStyle(eventColor(event.eventType))
                        .frame(width: 32)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(service.privacySafeName(event.contactName))
                            .font(.subheadline)
                            .fontWeight(.medium)

                        Text(event.description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Text("\(Int(event.confidence * 100))%")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding()
        .background(Color(.controlBackgroundColor))
        .cornerRadius(12)
    }

    private func eventIcon(_ type: String) -> String {
        switch type {
        case "new_job": return "briefcase.fill"
        case "birthday": return "gift.fill"
        case "travel": return "airplane"
        case "health": return "heart.fill"
        case "relationship": return "heart.circle.fill"
        case "milestone": return "star.fill"
        default: return "calendar"
        }
    }

    private func eventColor(_ type: String) -> Color {
        switch type {
        case "new_job": return .blue
        case "birthday": return .pink
        case "travel": return .orange
        case "health": return .red
        case "relationship": return .purple
        case "milestone": return .yellow
        default: return .gray
        }
    }
}

// MARK: - Relationship Summaries Card

struct RelationshipSummariesCard: View {
    let summaries: [GeminiService.RelationshipSummary]
    @ObservedObject private var service = InsightsService.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Relationship Insights", systemImage: "person.2.fill")
                .font(.headline)

            ForEach(summaries.prefix(3)) { summary in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(service.privacySafeName(summary.contactId))
                            .font(.subheadline)
                            .fontWeight(.medium)

                        Spacer()

                        Text(summary.relationshipType.capitalized)
                            .font(.caption)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(Color.blue.opacity(0.1))
                            .foregroundStyle(.blue)
                            .cornerRadius(4)
                    }

                    Text(summary.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if !summary.sharedInterests.isEmpty {
                        HStack {
                            ForEach(summary.sharedInterests.prefix(3), id: \.self) { interest in
                                Text(interest)
                                    .font(.caption2)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.purple.opacity(0.1))
                                    .foregroundStyle(.purple)
                                    .cornerRadius(4)
                            }
                        }
                    }
                }
                .padding()
                .background(Color(.windowBackgroundColor))
                .cornerRadius(8)
            }
        }
        .padding()
        .background(Color(.controlBackgroundColor))
        .cornerRadius(12)
    }
}

// MARK: - Analyze Section

struct AnalyzeSection: View {
    @Binding var isAnalyzing: Bool
    let onAnalyze: () async -> Void

    var body: some View {
        VStack(spacing: 12) {
            if isAnalyzing {
                ProgressView("Analyzing your conversations...")
            } else {
                Button {
                    Task { await onAnalyze() }
                } label: {
                    Label("Run Deep Analysis", systemImage: "sparkles")
                }
                .buttonStyle(.borderedProminent)

                Text("Uses Gemini Flash to analyze your top conversations")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(Color(.controlBackgroundColor))
        .cornerRadius(12)
    }
}

#Preview {
    AIInsightsView()
}
