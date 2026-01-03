import SwiftUI

// MARK: - Activity View
// Shows messaging activity timeline using real data from InsightsService

struct ActivityView: View {
    @ObservedObject private var service = InsightsService.shared

    var body: some View {
        let _ = NSLog("[ActivityView] body - isLoading: %d, dailyVolume count: %d, hourlyPattern count: %d",
                      service.isLoading ? 1 : 0, service.dailyVolume.count, service.hourlyPattern.count)
        ScrollView {
            if service.isLoading {
                ProgressView("Loading activity...")
                    .frame(maxWidth: .infinity, minHeight: 300)
            } else if service.dailyVolume.isEmpty {
                ContentUnavailableView(
                    "No Activity",
                    systemImage: "waveform.path.ecg",
                    description: Text("Message activity will appear here")
                )
            } else {
                VStack(spacing: 20) {
                    // Activity Summary
                    ActivitySummaryCard(
                        hourlyPattern: service.hourlyPattern,
                        dayOfWeekPattern: service.dayOfWeekPattern,
                        dailyVolume: service.dailyVolume
                    )

                    // Recent Activity Timeline
                    RecentActivityCard(dailyVolume: service.dailyVolume)

                    // Peak Hours
                    PeakHoursCard(hourlyPattern: service.hourlyPattern)
                }
                .padding()
            }
        }
        .navigationTitle("Activity")
        .task {
            if service.hourlyPattern.isEmpty {
                await service.loadAllInsights()
            }
        }
        .refreshable {
            await service.loadAllInsights()
        }
    }
}

// MARK: - Activity Summary Card

struct ActivitySummaryCard: View {
    let hourlyPattern: [Int: Int]
    let dayOfWeekPattern: [Int: Int]
    let dailyVolume: [String: Int]

    private var totalMessages: Int {
        dailyVolume.values.reduce(0, +)
    }

    private var avgPerDay: Int {
        guard !dailyVolume.isEmpty else { return 0 }
        return totalMessages / dailyVolume.count
    }

    private var peakHour: Int {
        hourlyPattern.max(by: { $0.value < $1.value })?.key ?? 0
    }

    private var peakDay: String {
        let dayNames = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        let peak = dayOfWeekPattern.max(by: { $0.value < $1.value })?.key ?? 0
        return dayNames[peak]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Activity Summary")
                .font(.headline)

            HStack(spacing: 20) {
                StatBox(title: "Total (14d)", value: "\(totalMessages)", icon: "message.fill", color: .blue)
                StatBox(title: "Avg/Day", value: "\(avgPerDay)", icon: "chart.bar.fill", color: .green)
                StatBox(title: "Peak Hour", value: formatHour(peakHour), icon: "clock.fill", color: .orange)
                StatBox(title: "Peak Day", value: peakDay, icon: "calendar", color: .purple)
            }
        }
        .padding()
        .background(Color(.controlBackgroundColor))
        .cornerRadius(12)
    }

    private func formatHour(_ hour: Int) -> String {
        if hour == 0 { return "12am" }
        if hour < 12 { return "\(hour)am" }
        if hour == 12 { return "12pm" }
        return "\(hour - 12)pm"
    }
}

struct StatBox: View {
    let title: String
    let value: String
    let icon: String
    let color: Color

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(color)

            Text(value)
                .font(.title2)
                .fontWeight(.bold)

            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Recent Activity Card

struct RecentActivityCard: View {
    let dailyVolume: [String: Int]

    private var sortedDays: [(date: String, count: Int)] {
        dailyVolume.sorted { $0.key > $1.key }.map { (date: $0.key, count: $0.value) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Recent Activity")
                .font(.headline)

            ForEach(sortedDays.prefix(7), id: \.date) { day in
                HStack {
                    Text(formatDate(day.date))
                        .font(.subheadline)
                        .frame(width: 100, alignment: .leading)

                    GeometryReader { geo in
                        let maxCount = dailyVolume.values.max() ?? 1
                        let width = CGFloat(day.count) / CGFloat(maxCount) * geo.size.width

                        RoundedRectangle(cornerRadius: 4)
                            .fill(barColor(day.count, max: maxCount))
                            .frame(width: max(width, 4))
                    }
                    .frame(height: 20)

                    Text("\(day.count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 50, alignment: .trailing)
                }
            }
        }
        .padding()
        .background(Color(.controlBackgroundColor))
        .cornerRadius(12)
    }

    private func formatDate(_ dateString: String) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        guard let date = formatter.date(from: dateString) else { return dateString }

        let displayFormatter = DateFormatter()
        displayFormatter.dateFormat = "MMM d"
        return displayFormatter.string(from: date)
    }

    private func barColor(_ count: Int, max: Int) -> Color {
        let ratio = Double(count) / Double(max)
        if ratio > 0.8 { return .red.opacity(0.8) }
        if ratio > 0.5 { return .orange.opacity(0.8) }
        return .blue.opacity(0.8)
    }
}

// MARK: - Peak Hours Card

struct PeakHoursCard: View {
    let hourlyPattern: [Int: Int]

    private var topHours: [(hour: Int, count: Int)] {
        hourlyPattern.sorted { $0.value > $1.value }.prefix(5).map { (hour: $0.key, count: $0.value) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Most Active Hours")
                .font(.headline)

            ForEach(topHours, id: \.hour) { item in
                HStack {
                    Text(formatHour(item.hour))
                        .font(.subheadline)
                        .frame(width: 60, alignment: .leading)

                    ProgressView(value: Double(item.count), total: Double(hourlyPattern.values.max() ?? 1))
                        .tint(hourColor(item.hour))

                    Text("\(item.count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 50, alignment: .trailing)
                }
            }
        }
        .padding()
        .background(Color(.controlBackgroundColor))
        .cornerRadius(12)
    }

    private func formatHour(_ hour: Int) -> String {
        if hour == 0 { return "12:00am" }
        if hour < 12 { return "\(hour):00am" }
        if hour == 12 { return "12:00pm" }
        return "\(hour - 12):00pm"
    }

    private func hourColor(_ hour: Int) -> Color {
        switch hour {
        case 0...5: return .purple
        case 6...11: return .orange
        case 12...17: return .blue
        default: return .green
        }
    }
}

#Preview {
    ActivityView()
}
