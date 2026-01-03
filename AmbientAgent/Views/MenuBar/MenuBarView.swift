import SwiftUI
import SwiftData
import AmbientCore

struct MenuBarView: View {
    @Environment(AppState.self) private var appState

    @Query(sort: \AmbientEvent.startDate)
    private var allEvents: [AmbientEvent]

    @Query(sort: \AmbientTask.dueDate)
    private var allTasks: [AmbientTask]

    private var upcomingEvents: [AmbientEvent] {
        let now = Date()
        return allEvents.filter { $0.startDate >= now }
    }

    private var pendingTasks: [AmbientTask] {
        allTasks.filter { $0.status == .pending || $0.status == .inProgress }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack {
                Text("Ambient Agent")
                    .font(.headline)

                Spacer()

                Circle()
                    .fill(appState.isMonitoringActive ? .green : .gray)
                    .frame(width: 8, height: 8)
            }

            Divider()

            // Quick Stats
            HStack(spacing: 16) {
                StatBadge(
                    icon: "calendar",
                    value: "\(upcomingEvents.prefix(10).count)",
                    label: "Events"
                )

                StatBadge(
                    icon: "checklist",
                    value: "\(pendingTasks.count)",
                    label: "Tasks"
                )
            }

            Divider()

            // Upcoming Events (max 3)
            if !upcomingEvents.isEmpty {
                Text("Coming Up")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                ForEach(upcomingEvents.prefix(3)) { event in
                    CompactEventRow(event: event)
                }
            } else {
                Text("No upcoming events")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            // Actions
            Button {
                NSApplication.shared.activate(ignoringOtherApps: true)
                // Open main window
                if let window = NSApplication.shared.windows.first(where: { $0.title == "Ambient" }) {
                    window.makeKeyAndOrderFront(nil)
                }
            } label: {
                Label("Open Dashboard", systemImage: "macwindow")
            }
            .buttonStyle(.plain)

            Button {
                Task { await appState.syncAll() }
            } label: {
                Label("Sync Now", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.plain)

            Divider()

            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Label("Quit", systemImage: "power")
            }
            .buttonStyle(.plain)
        }
        .padding()
        .frame(width: 280)
    }
}

// MARK: - Components

struct StatBadge: View {
    let icon: String
    let value: String
    let label: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 0) {
                Text(value)
                    .font(.headline)
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct CompactEventRow: View {
    let event: AmbientEvent

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(event.title)
                    .font(.subheadline)
                    .lineLimit(1)

                Text(event.startDate, style: .relative)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if event.hasVirtualMeeting {
                Image(systemName: "video.fill")
                    .font(.caption)
                    .foregroundStyle(.blue)
            }
        }
        .padding(.vertical, 4)
    }
}
