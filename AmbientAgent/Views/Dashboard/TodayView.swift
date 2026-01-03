import SwiftUI
import SwiftData
import AmbientCore

struct TodayView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(AppState.self) private var appState

    @Query(sort: \AmbientEvent.startDate)
    private var allEvents: [AmbientEvent]

    @Query(sort: [
        SortDescriptor(\AmbientTask.priorityRaw, order: .reverse),
        SortDescriptor(\AmbientTask.dueDate)
    ])
    private var allTasks: [AmbientTask]

    private var pendingTasks: [AmbientTask] {
        allTasks.filter { $0.status == .pending || $0.status == .inProgress }
    }

    // Filter events for today (computed to handle date changes)
    private var todayEvents: [AmbientEvent] {
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: Date())
        let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay)!
        return allEvents.filter { $0.startDate >= startOfDay && $0.startDate < endOfDay }
    }

    private var urgentTasks: [AmbientTask] {
        pendingTasks.filter { $0.isDueToday || $0.isOverdue }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                // Header
                headerSection

                // Urgent Tasks (if any)
                if !urgentTasks.isEmpty {
                    urgentTasksSection
                }

                // Today's Events
                eventsSection

                // Other Pending Tasks
                tasksSection
            }
            .padding()
        }
        .navigationTitle("Today")
        .navigationSubtitle(Date().formatted(date: .complete, time: .omitted))
    }

    // MARK: - Sections

    private var headerSection: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Good \(greeting)")
                    .font(.largeTitle)
                    .fontWeight(.bold)

                Text("You have \(todayEvents.count) events and \(urgentTasks.count) tasks due today")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
    }

    private var urgentTasksSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Due Today", count: urgentTasks.count, color: .orange)

            ForEach(urgentTasks) { task in
                TaskRow(task: task)
                    .onTapGesture {
                        appState.selectedTask = task
                    }
            }
        }
    }

    private var eventsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Events", count: todayEvents.count)

            if todayEvents.isEmpty {
                ContentUnavailableView(
                    "No Events Today",
                    systemImage: "calendar",
                    description: Text("Your calendar is clear for today")
                )
                .frame(height: 150)
            } else {
                ForEach(todayEvents) { event in
                    EventCard(event: event)
                        .onTapGesture {
                            appState.selectedEvent = event
                        }
                }
            }
        }
    }

    private var tasksSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            let otherTasks = pendingTasks.filter { !$0.isDueToday && !$0.isOverdue }

            if !otherTasks.isEmpty {
                SectionHeader(title: "Other Tasks", count: otherTasks.count)

                ForEach(otherTasks.prefix(5)) { task in
                    TaskRow(task: task)
                        .onTapGesture {
                            appState.selectedTask = task
                        }
                }

                if otherTasks.count > 5 {
                    Button("View all \(otherTasks.count) tasks") {
                        appState.selectedTab = .tasks
                    }
                    .buttonStyle(.link)
                }
            }
        }
    }

    // MARK: - Helpers

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 0..<12: return "morning"
        case 12..<17: return "afternoon"
        default: return "evening"
        }
    }
}

// MARK: - Section Header

struct SectionHeader: View {
    let title: String
    let count: Int
    var color: Color = .accentColor

    var body: some View {
        HStack {
            Text(title)
                .font(.headline)

            Text("\(count)")
                .font(.caption)
                .fontWeight(.semibold)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(color.opacity(0.15))
                .foregroundStyle(color)
                .clipShape(Capsule())

            Spacer()
        }
    }
}

#Preview {
    TodayView()
        .environment(AppState())
        .modelContainer(for: [AmbientEvent.self, AmbientTask.self])
}
