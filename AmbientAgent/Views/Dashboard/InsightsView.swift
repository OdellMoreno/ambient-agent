import SwiftUI

// MARK: - Insights Dashboard View

struct InsightsView: View {
    @ObservedObject private var service = InsightsService.shared

    var body: some View {
        let _ = NSLog("[InsightsView] body evaluated, isLoading: %d, contacts: %d, wellbeingScore: %@",
                      service.isLoading ? 1 : 0,
                      service.contacts.count,
                      service.wellbeingScore.map { "sleepMsgs=\($0.sleepHourMessages), support=\($0.supportNetworkSize)" } ?? "nil")
        ScrollView {
            if service.isLoading {
                ProgressView("Analyzing your data...")
                    .frame(maxWidth: .infinity, minHeight: 300)
            } else {
                VStack(spacing: 20) {
                    // Wellbeing Score
                    if let score = service.wellbeingScore {
                        WellbeingCard(score: score)
                    }

                    // Recent Insights
                    if !service.recentInsights.isEmpty {
                        InsightCardsSection(insights: service.recentInsights)
                    }

                    // Time Pattern
                    if !service.hourlyPattern.isEmpty {
                        TimePatternCard(hourlyData: service.hourlyPattern)
                    }

                    // Daily Volume Chart
                    if !service.dailyVolume.isEmpty {
                        DailyVolumeCard(dailyData: service.dailyVolume)
                    }

                    // Day of Week Pattern
                    if !service.dayOfWeekPattern.isEmpty {
                        DayOfWeekCard(data: service.dayOfWeekPattern)
                    }

                    // Group Chats
                    if !service.groupChats.isEmpty {
                        GroupChatsCard(groupChats: service.groupChats)
                    }

                    // Unread Messages
                    if !service.unreadMessages.isEmpty {
                        UnreadMessagesCard(unreads: service.unreadMessages)
                    }

                    // Top Contacts Preview
                    if !service.contacts.isEmpty {
                        TopContactsCard(contacts: Array(service.contacts.prefix(5)))
                    }
                }
                .padding()
            }
        }
        .navigationTitle("Insights")
        .task {
            // Only load if data is empty (syncAll already loaded at startup)
            if service.contacts.isEmpty {
                NSLog("[InsightsView] No data, loading insights...")
                await service.loadAllInsights()
                NSLog("[InsightsView] Task completed. Contacts: %d", service.contacts.count)
            } else {
                NSLog("[InsightsView] Data already loaded, skipping. Contacts: %d", service.contacts.count)
            }
        }
        .refreshable {
            await service.loadAllInsights()
        }
    }
}

// MARK: - Wellbeing Score Card

struct WellbeingCard: View {
    let score: InsightsService.WellbeingData

    var body: some View {
        let _ = NSLog("[WellbeingCard] Rendering with sleepHourMessages: %d, supportNetworkSize: %d", score.sleepHourMessages, score.supportNetworkSize)
        VStack(spacing: 16) {
            HStack {
                Text("Wellbeing Score")
                    .font(.headline)
                Spacer()
                Text(summary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            // Main Score Circle
            HStack(spacing: 30) {
                ZStack {
                    Circle()
                        .stroke(Color.gray.opacity(0.2), lineWidth: 12)

                    Circle()
                        .trim(from: 0, to: score.overall / 100)
                        .stroke(scoreColor(score.overall), style: StrokeStyle(lineWidth: 12, lineCap: .round))
                        .rotationEffect(.degrees(-90))

                    VStack {
                        Text("\(Int(score.overall))")
                            .font(.system(size: 36, weight: .bold))
                        Text("/ 100")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 120, height: 120)

                // Sub-scores
                VStack(alignment: .leading, spacing: 12) {
                    SubScoreRow(title: "Sleep Quality", value: score.sleepQuality, icon: "moon.fill", detail: "\(score.sleepHourMessages) late-night msgs")
                    SubScoreRow(title: "Social Connection", value: score.socialConnection, icon: "person.2.fill", detail: "\(score.supportNetworkSize) close contacts")
                    SubScoreRow(title: "Stress Level", value: 100 - score.stressLevel, icon: "heart.fill", detail: score.stressLevel > 50 ? "Elevated" : "Normal")
                }
            }
        }
        .padding()
        .background(Color(.controlBackgroundColor))
        .cornerRadius(12)
    }

    private var summary: String {
        switch score.overall {
        case 80...100: return "Thriving"
        case 60..<80: return "Good"
        case 40..<60: return "Fair"
        case 20..<40: return "Struggling"
        default: return "Needs Attention"
        }
    }

    private func scoreColor(_ value: Double) -> Color {
        switch value {
        case 80...100: return .green
        case 60..<80: return .blue
        case 40..<60: return .yellow
        case 20..<40: return .orange
        default: return .red
        }
    }
}

struct SubScoreRow: View {
    let title: String
    let value: Double
    let icon: String
    let detail: String

    var body: some View {
        HStack {
            Image(systemName: icon)
                .foregroundStyle(value >= 60 ? .green : value >= 40 ? .yellow : .red)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline)
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text("\(Int(value))")
                .font(.headline)
                .foregroundColor(value >= 60 ? .primary : .orange)
        }
    }
}

// MARK: - Insight Cards

struct InsightCardsSection: View {
    let insights: [InsightsService.Insight]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Recent Insights")
                .font(.headline)

            ForEach(insights) { insight in
                InsightCard(insight: insight)
            }
        }
    }
}

struct InsightCard: View {
    let insight: InsightsService.Insight

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: iconForType(insight.type))
                .font(.title2)
                .foregroundStyle(colorForPriority(insight.priority))
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 4) {
                Text(insight.title)
                    .font(.subheadline)
                    .fontWeight(.medium)

                Text(insight.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }

            Spacer()
        }
        .padding()
        .background(Color(.controlBackgroundColor))
        .cornerRadius(8)
    }

    private func iconForType(_ type: InsightsService.Insight.InsightType) -> String {
        switch type {
        case .volumeSpike: return "chart.line.uptrend.xyaxis"
        case .sleepDisruption: return "moon.zzz.fill"
        case .supportNetwork: return "heart.circle.fill"
        case .lifeMilestone: return "star.fill"
        }
    }

    private func colorForPriority(_ priority: InsightsService.Insight.Priority) -> Color {
        switch priority {
        case .low: return .gray
        case .medium: return .blue
        case .high: return .orange
        case .critical: return .red
        }
    }
}

// MARK: - Time Pattern Card

struct TimePatternCard: View {
    let hourlyData: [Int: Int]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Activity by Hour")
                .font(.headline)

            HStack(alignment: .bottom, spacing: 2) {
                ForEach(0..<24, id: \.self) { hour in
                    let count = hourlyData[hour] ?? 0
                    let maxCount = hourlyData.values.max() ?? 1
                    let height = maxCount > 0 ? CGFloat(count) / CGFloat(maxCount) * 80 : 0

                    VStack(spacing: 2) {
                        Rectangle()
                            .fill(barColor(for: hour))
                            .frame(width: 12, height: max(height, 2))

                        if hour % 6 == 0 {
                            Text("\(hour)")
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                        } else {
                            Text("")
                                .font(.system(size: 9))
                        }
                    }
                }
            }
            .frame(height: 100)

            // Legend
            HStack(spacing: 16) {
                LegendItem(color: .purple.opacity(0.7), label: "Night (12-5am)")
                LegendItem(color: .orange.opacity(0.7), label: "Morning (6-11am)")
                LegendItem(color: .blue.opacity(0.7), label: "Afternoon (12-5pm)")
                LegendItem(color: .green.opacity(0.7), label: "Evening (6-11pm)")
            }
            .font(.caption2)
        }
        .padding()
        .background(Color(.controlBackgroundColor))
        .cornerRadius(12)
    }

    private func barColor(for hour: Int) -> Color {
        switch hour {
        case 0...5: return .purple.opacity(0.7)
        case 6...11: return .orange.opacity(0.7)
        case 12...17: return .blue.opacity(0.7)
        default: return .green.opacity(0.7)
        }
    }
}

struct LegendItem: View {
    let color: Color
    let label: String

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(label)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Daily Volume Card

struct DailyVolumeCard: View {
    let dailyData: [String: Int]

    private var sortedDays: [(String, Int)] {
        dailyData.sorted { $0.key < $1.key }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Message Volume (14 days)")
                .font(.headline)

            HStack(alignment: .bottom, spacing: 4) {
                ForEach(sortedDays, id: \.0) { day, count in
                    let maxCount = dailyData.values.max() ?? 1
                    let height = CGFloat(count) / CGFloat(maxCount) * 100

                    VStack(spacing: 4) {
                        Text("\(count)")
                            .font(.system(size: 8))
                            .foregroundStyle(.secondary)

                        Rectangle()
                            .fill(volumeColor(count: count, max: maxCount))
                            .frame(height: max(height, 4))
                            .cornerRadius(2)

                        Text(dayLabel(day))
                            .font(.system(size: 8))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 140)
        }
        .padding()
        .background(Color(.controlBackgroundColor))
        .cornerRadius(12)
    }

    private func volumeColor(count: Int, max: Int) -> Color {
        let ratio = Double(count) / Double(max)
        if ratio > 0.8 { return .red.opacity(0.8) }
        if ratio > 0.5 { return .orange.opacity(0.8) }
        return .blue.opacity(0.8)
    }

    private func dayLabel(_ dateString: String) -> String {
        let parts = dateString.split(separator: "-")
        if parts.count >= 3 {
            return String(parts[2])
        }
        return dateString
    }
}

// MARK: - Top Contacts Card

struct TopContactsCard: View {
    let contacts: [InsightsService.Contact]
    @ObservedObject private var service = InsightsService.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Top Contacts")
                    .font(.headline)
                Spacer()
                NavigationLink {
                    PeopleView()
                } label: {
                    Text("See All")
                        .font(.caption)
                }
            }

            ForEach(contacts) { contact in
                HStack {
                    Circle()
                        .fill(Color.blue.gradient)
                        .frame(width: 32, height: 32)
                        .overlay {
                            Text(String((contact.displayName ?? contact.phoneOrEmail).prefix(1)))
                                .font(.caption)
                                .foregroundStyle(.white)
                        }

                    VStack(alignment: .leading) {
                        Text(service.privacySafeName(contact.displayName ?? contact.phoneOrEmail))
                            .font(.subheadline)
                        Text("\(contact.messageCount) messages")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    // Relationship strength bar
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Color.gray.opacity(0.2))
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Color.green)
                                .frame(width: geo.size.width * contact.relationshipStrength)
                        }
                    }
                    .frame(width: 60, height: 6)
                }
            }
        }
        .padding()
        .background(Color(.controlBackgroundColor))
        .cornerRadius(12)
    }
}

// MARK: - Day of Week Card

struct DayOfWeekCard: View {
    let data: [Int: Int]

    private let dayNames = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Activity by Day")
                .font(.headline)

            HStack(alignment: .bottom, spacing: 8) {
                ForEach(0..<7, id: \.self) { day in
                    let count = data[day] ?? 0
                    let maxCount = data.values.max() ?? 1
                    let height = maxCount > 0 ? CGFloat(count) / CGFloat(maxCount) * 80 : 0

                    VStack(spacing: 4) {
                        Text("\(count)")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)

                        RoundedRectangle(cornerRadius: 4)
                            .fill(dayColor(for: day))
                            .frame(height: max(height, 4))

                        Text(dayNames[day])
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 120)
        }
        .padding()
        .background(Color(.controlBackgroundColor))
        .cornerRadius(12)
    }

    private func dayColor(for day: Int) -> Color {
        // Weekend vs weekday coloring
        if day == 0 || day == 6 {
            return .purple.opacity(0.8)
        }
        return .blue.opacity(0.8)
    }
}

// MARK: - Group Chats Card

struct GroupChatsCard: View {
    let groupChats: [InsightsService.GroupChat]
    @ObservedObject private var service = InsightsService.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Group Chats")
                .font(.headline)

            ForEach(groupChats.prefix(5)) { chat in
                HStack {
                    Circle()
                        .fill(Color.purple.gradient)
                        .frame(width: 32, height: 32)
                        .overlay {
                            Image(systemName: "person.3.fill")
                                .font(.system(size: 12))
                                .foregroundStyle(.white)
                        }

                    VStack(alignment: .leading) {
                        Text(service.privacySafeName(chat.name))
                            .font(.subheadline)
                        HStack(spacing: 8) {
                            Label("\(chat.messageCount)", systemImage: "message.fill")
                            Label("\(chat.participantCount)", systemImage: "person.2")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }

                    Spacer()
                }
            }
        }
        .padding()
        .background(Color(.controlBackgroundColor))
        .cornerRadius(12)
    }
}

// MARK: - Unread Messages Card

struct UnreadMessagesCard: View {
    let unreads: [(contact: String, count: Int, oldestDate: Date)]
    @ObservedObject private var service = InsightsService.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Unread Messages")
                    .font(.headline)
                Spacer()
                Text("\(unreads.reduce(0) { $0 + $1.count }) total")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ForEach(Array(unreads.prefix(5).enumerated()), id: \.offset) { _, unread in
                HStack {
                    Circle()
                        .fill(Color.orange)
                        .frame(width: 8, height: 8)

                    Text(service.privacySafeName(formatContact(unread.contact)))
                        .font(.subheadline)

                    Spacer()

                    Text("\(unread.count) unread")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
        .padding()
        .background(Color.orange.opacity(0.1))
        .cornerRadius(12)
    }

    private func formatContact(_ contact: String) -> String {
        if contact.hasPrefix("+1") && contact.count == 12 {
            let clean = contact.dropFirst(2)
            return "(\(clean.prefix(3))) \(clean.dropFirst(3).prefix(3))-\(clean.suffix(4))"
        }
        return contact
    }
}

// MARK: - AI Insights View

struct AIInsightsView: View {
    @ObservedObject private var service = InsightsService.shared
    @State private var geminiKey = ""

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                // API Key Section (if not set)
                if !service.hasGeminiKey {
                    APIKeyCard(geminiKey: $geminiKey)
                } else {
                    // Weekly Trends
                    if let trend = service.weeklyTrend {
                        WeeklyTrendCard(trend: trend)
                    }

                    // Reach Out Suggestions
                    if !service.reachOutSuggestions.isEmpty {
                        ReachOutSuggestionsCard(suggestions: service.reachOutSuggestions)
                    }

                    // Coming Soon
                    ComingSoonCard()
                }
            }
            .padding()
        }
        .navigationTitle("AI Insights")
        .task {
            // Load data if not already loaded (syncAll handles this at startup)
            if service.contacts.isEmpty {
                await service.loadAllInsights()
            }
            // Generate suggestions (quick local computation)
            if service.reachOutSuggestions.isEmpty {
                service.generateReachOutSuggestions()
            }
            if service.weeklyTrend == nil {
                service.computeWeeklyTrend()
            }
        }
    }
}

// MARK: - API Key Card

struct APIKeyCard: View {
    @Binding var geminiKey: String
    @ObservedObject private var service = InsightsService.shared

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "sparkles")
                .font(.system(size: 48))
                .foregroundStyle(.purple)

            Text("Enable AI Insights")
                .font(.title2)
                .fontWeight(.bold)

            Text("Add your Gemini API key to unlock AI-powered suggestions and analysis.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            VStack(spacing: 12) {
                SecureField("Gemini API Key", text: $geminiKey)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 300)

                Button("Save API Key") {
                    service.geminiAPIKey = geminiKey
                }
                .buttonStyle(.borderedProminent)
                .disabled(geminiKey.isEmpty)

                Link("Get free API key from Google AI Studio",
                     destination: URL(string: "https://aistudio.google.com/app/apikey")!)
                    .font(.caption)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity)
        .background(Color(.controlBackgroundColor))
        .cornerRadius(12)
    }
}

// MARK: - Weekly Trend Card

struct WeeklyTrendCard: View {
    let trend: InsightsService.WeeklyTrend

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Weekly Trend")
                    .font(.headline)

                Spacer()

                HStack(spacing: 4) {
                    Image(systemName: trend.percentChange > 0 ? "arrow.up.right" : trend.percentChange < 0 ? "arrow.down.right" : "arrow.right")
                    Text(String(format: "%+.1f%%", trend.percentChange))
                }
                .font(.subheadline)
                .foregroundStyle(trend.percentChange > 10 ? .green : trend.percentChange < -10 ? .orange : .blue)
            }

            HStack(spacing: 20) {
                VStack(spacing: 4) {
                    Text("This Week")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("\(trend.thisWeekMessages)")
                        .font(.title2)
                        .fontWeight(.bold)
                        .foregroundStyle(.blue)
                }
                .frame(maxWidth: .infinity)

                VStack(spacing: 4) {
                    Text("Last Week")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("\(trend.lastWeekMessages)")
                        .font(.title2)
                        .fontWeight(.bold)
                        .foregroundStyle(.gray)
                }
                .frame(maxWidth: .infinity)

                VStack(spacing: 4) {
                    Text("Avg/Day")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(String(format: "%.0f", trend.avgPerDay))
                        .font(.title2)
                        .fontWeight(.bold)
                        .foregroundStyle(.green)
                }
                .frame(maxWidth: .infinity)
            }

            HStack {
                Label("Busiest: \(trend.busiestDay)", systemImage: "flame.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                Spacer()
            }
        }
        .padding()
        .background(Color(.controlBackgroundColor))
        .cornerRadius(12)
    }
}

// MARK: - Reach Out Suggestions Card

struct ReachOutSuggestionsCard: View {
    let suggestions: [InsightsService.ReachOutSuggestion]
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

    private func priorityColor(_ priority: Int) -> Color {
        switch priority {
        case 3: return .red
        case 2: return .orange
        default: return .blue
        }
    }
}

// MARK: - Coming Soon Card

struct ComingSoonCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Coming Soon", systemImage: "sparkles")
                .font(.headline)

            VStack(alignment: .leading, spacing: 8) {
                AIFeatureRow(icon: "brain.head.profile", title: "Relationship Summaries", description: "AI-generated insights about your connections")
                AIFeatureRow(icon: "calendar.badge.clock", title: "Life Event Detection", description: "Automatically detect birthdays, new jobs, etc.")
                AIFeatureRow(icon: "chart.line.uptrend.xyaxis", title: "Sentiment Analysis", description: "Track emotional tone of conversations")
            }
        }
        .padding()
        .background(Color(.controlBackgroundColor))
        .cornerRadius(12)
    }
}

struct AIFeatureRow: View {
    let icon: String
    let title: String
    let description: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(.purple)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.medium)
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

#Preview {
    InsightsView()
}
