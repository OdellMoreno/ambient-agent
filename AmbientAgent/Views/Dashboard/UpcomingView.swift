import SwiftUI
import SwiftData
import AmbientCore

struct UpcomingView: View {
    @Environment(AppState.self) private var appState

    @Query(sort: \AmbientEvent.startDate)
    private var allEvents: [AmbientEvent]

    private var upcomingEvents: [AmbientEvent] {
        let now = Date()
        let endDate = Calendar.current.date(byAdding: .day, value: 14, to: now)!
        return allEvents.filter { $0.startDate >= now && $0.startDate <= endDate }
    }

    private var groupedEvents: [(Date, [AmbientEvent])] {
        let grouped = Dictionary(grouping: upcomingEvents) { event in
            Calendar.current.startOfDay(for: event.startDate)
        }
        return grouped.sorted { $0.key < $1.key }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                ForEach(groupedEvents, id: \.0) { date, events in
                    VStack(alignment: .leading, spacing: 12) {
                        // Date header
                        HStack {
                            Text(date, format: .dateTime.weekday(.wide).month().day())
                                .font(.headline)

                            if Calendar.current.isDateInToday(date) {
                                Text("Today")
                                    .font(.caption)
                                    .fontWeight(.semibold)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 2)
                                    .background(.blue.opacity(0.15))
                                    .foregroundStyle(.blue)
                                    .clipShape(Capsule())
                            }

                            Spacer()

                            Text("\(events.count) events")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        // Events for this date
                        ForEach(events) { event in
                            EventCard(event: event)
                                .onTapGesture {
                                    appState.selectedEvent = event
                                }
                        }
                    }
                }

                if upcomingEvents.isEmpty {
                    ContentUnavailableView(
                        "No Upcoming Events",
                        systemImage: "calendar",
                        description: Text("No events scheduled for the next 14 days")
                    )
                }
            }
            .padding()
        }
        .navigationTitle("Upcoming")
    }
}
