import Foundation
import SwiftUI

// MARK: - History Service
// Tracks metrics over time for trend analysis

@MainActor
class HistoryService: ObservableObject {
    static let shared = HistoryService()

    @Published var dailySnapshots: [DailySnapshot] = []
    @Published var weeklyTrends: WeeklyTrend?

    private let snapshotsKey = "dailySnapshots"
    private let maxSnapshots = 90 // Keep 90 days of history

    private init() {
        loadSnapshots()
    }

    // MARK: - Data Models

    struct DailySnapshot: Codable, Identifiable {
        var id: String { date }
        let date: String // yyyy-MM-dd
        let totalMessages: Int
        let sentMessages: Int
        let receivedMessages: Int
        let activeContacts: Int
        let avgResponseTime: Double? // minutes
        let topHour: Int
        let lateNightMessages: Int // midnight-5am
    }

    struct WeeklyTrend {
        let thisWeekMessages: Int
        let lastWeekMessages: Int
        let percentChange: Double

        let thisWeekActiveContacts: Int
        let lastWeekActiveContacts: Int

        let averageDailyMessages: Double
        let busiestDay: String
        let quietestDay: String

        var trend: Trend {
            if percentChange > 10 { return .up }
            if percentChange < -10 { return .down }
            return .stable
        }

        enum Trend {
            case up, down, stable

            var icon: String {
                switch self {
                case .up: return "arrow.up.right"
                case .down: return "arrow.down.right"
                case .stable: return "arrow.right"
                }
            }

            var color: Color {
                switch self {
                case .up: return .green
                case .down: return .orange
                case .stable: return .blue
                }
            }
        }
    }

    // MARK: - Snapshot Management

    func recordDailySnapshot(from insights: InsightsService) {
        let today = dateString(from: Date())

        // Don't record if we already have today's snapshot
        if dailySnapshots.contains(where: { $0.date == today }) {
            return
        }

        let totalMessages = insights.dailyVolume.values.reduce(0, +)
        let sentMessages = insights.contacts.reduce(0) { $0 + $1.sentCount }
        let receivedMessages = insights.contacts.reduce(0) { $0 + $1.receivedCount }
        let lateNight = (0...5).reduce(0) { $0 + (insights.hourlyPattern[$1] ?? 0) }
        let topHour = insights.hourlyPattern.max(by: { $0.value < $1.value })?.key ?? 0

        let snapshot = DailySnapshot(
            date: today,
            totalMessages: totalMessages,
            sentMessages: sentMessages,
            receivedMessages: receivedMessages,
            activeContacts: insights.contacts.count,
            avgResponseTime: nil,
            topHour: topHour,
            lateNightMessages: lateNight
        )

        dailySnapshots.append(snapshot)

        // Trim old snapshots
        if dailySnapshots.count > maxSnapshots {
            dailySnapshots = Array(dailySnapshots.suffix(maxSnapshots))
        }

        saveSnapshots()
        computeWeeklyTrends()
    }

    func computeWeeklyTrends() {
        let calendar = Calendar.current
        let today = Date()

        guard let weekAgo = calendar.date(byAdding: .day, value: -7, to: today),
              let twoWeeksAgo = calendar.date(byAdding: .day, value: -14, to: today) else {
            return
        }

        let thisWeekStart = dateString(from: weekAgo)
        let lastWeekStart = dateString(from: twoWeeksAgo)
        let todayStr = dateString(from: today)

        let thisWeekSnapshots = dailySnapshots.filter { $0.date >= thisWeekStart && $0.date <= todayStr }
        let lastWeekSnapshots = dailySnapshots.filter { $0.date >= lastWeekStart && $0.date < thisWeekStart }

        let thisWeekMessages = thisWeekSnapshots.reduce(0) { $0 + $1.totalMessages }
        let lastWeekMessages = lastWeekSnapshots.reduce(0) { $0 + $1.totalMessages }

        let percentChange: Double
        if lastWeekMessages > 0 {
            percentChange = Double(thisWeekMessages - lastWeekMessages) / Double(lastWeekMessages) * 100
        } else {
            percentChange = 0
        }

        // Find busiest and quietest days
        let dayTotals = Dictionary(grouping: thisWeekSnapshots, by: { dayOfWeek(from: $0.date) })
            .mapValues { $0.reduce(0) { $0 + $1.totalMessages } }

        let busiest = dayTotals.max(by: { $0.value < $1.value })?.key ?? "Unknown"
        let quietest = dayTotals.min(by: { $0.value < $1.value })?.key ?? "Unknown"

        weeklyTrends = WeeklyTrend(
            thisWeekMessages: thisWeekMessages,
            lastWeekMessages: lastWeekMessages,
            percentChange: percentChange,
            thisWeekActiveContacts: thisWeekSnapshots.map { $0.activeContacts }.max() ?? 0,
            lastWeekActiveContacts: lastWeekSnapshots.map { $0.activeContacts }.max() ?? 0,
            averageDailyMessages: thisWeekSnapshots.isEmpty ? 0 : Double(thisWeekMessages) / Double(thisWeekSnapshots.count),
            busiestDay: busiest,
            quietestDay: quietest
        )
    }

    // MARK: - Persistence

    private func loadSnapshots() {
        guard let data = UserDefaults.standard.data(forKey: snapshotsKey),
              let decoded = try? JSONDecoder().decode([DailySnapshot].self, from: data) else {
            return
        }
        dailySnapshots = decoded
        computeWeeklyTrends()
    }

    private func saveSnapshots() {
        guard let data = try? JSONEncoder().encode(dailySnapshots) else { return }
        UserDefaults.standard.set(data, forKey: snapshotsKey)
    }

    // MARK: - Helpers

    private func dateString(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private func dayOfWeek(from dateString: String) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        guard let date = formatter.date(from: dateString) else { return "Unknown" }

        let dayFormatter = DateFormatter()
        dayFormatter.dateFormat = "EEEE"
        return dayFormatter.string(from: date)
    }

    // MARK: - Chart Data

    func chartData(days: Int = 14) -> [(date: String, messages: Int)] {
        let recent = dailySnapshots.suffix(days)
        return recent.map { (date: $0.date, messages: $0.totalMessages) }
    }

    func contactTrend(days: Int = 14) -> [(date: String, count: Int)] {
        let recent = dailySnapshots.suffix(days)
        return recent.map { (date: $0.date, count: $0.activeContacts) }
    }
}
