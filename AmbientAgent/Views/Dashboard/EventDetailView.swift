import SwiftUI
import AmbientCore

struct EventDetailView: View {
    let event: AmbientEvent

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Header
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        SourceBadge(sourceType: event.sourceType)
                        Spacer()
                        if event.confidence != .high {
                            Label("Confidence: \(event.confidence.rawValue)", systemImage: "exclamationmark.circle")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }

                    Text(event.title)
                        .font(.title)
                        .fontWeight(.bold)
                }

                Divider()

                // Time
                VStack(alignment: .leading, spacing: 8) {
                    Label("Time", systemImage: "clock")
                        .font(.headline)

                    if event.isAllDay {
                        Text("All Day - \(event.startDate, format: .dateTime.weekday(.wide).month().day())")
                    } else {
                        Text(event.startDate, format: .dateTime.weekday(.wide).month().day().hour().minute())

                        if let endDate = event.endDate {
                            Text("to \(endDate, format: .dateTime.hour().minute())")
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                // Location
                if let location = event.location {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Location", systemImage: "location")
                            .font(.headline)

                        Text(location)

                        if let address = event.locationAddress {
                            Text(address)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                // Virtual Meeting
                if let meetingURL = event.virtualMeetingURL {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Virtual Meeting", systemImage: "video")
                            .font(.headline)

                        Link(destination: URL(string: meetingURL)!) {
                            Label("Join \(event.virtualMeetingType ?? "Meeting")", systemImage: "arrow.up.right.square")
                        }
                    }
                }

                // Attendees
                if !event.attendees.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Attendees (\(event.attendees.count))", systemImage: "person.2")
                            .font(.headline)

                        ForEach(Array(event.attendees.enumerated()), id: \.offset) { _, attendee in
                            HStack {
                                Circle()
                                    .fill(Color.blue.opacity(0.2))
                                    .frame(width: 32, height: 32)
                                    .overlay {
                                        Text(attendee.name?.prefix(1).uppercased() ?? "?")
                                            .font(.caption)
                                            .fontWeight(.semibold)
                                    }

                                VStack(alignment: .leading) {
                                    Text(attendee.name ?? "Unknown")
                                        .font(.subheadline)
                                    if let email = attendee.email {
                                        Text(email)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }

                                if attendee.isOrganizer {
                                    Text("Organizer")
                                        .font(.caption2)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(.blue.opacity(0.15))
                                        .foregroundStyle(.blue)
                                        .clipShape(Capsule())
                                }
                            }
                        }
                    }
                }

                // Description
                if let description = event.eventDescription, !description.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Description", systemImage: "doc.text")
                            .font(.headline)

                        Text(description)
                            .font(.body)
                    }
                }

                // Metadata
                VStack(alignment: .leading, spacing: 4) {
                    Label("Metadata", systemImage: "info.circle")
                        .font(.headline)

                    Group {
                        Text("Source ID: \(event.sourceIdentifier)")
                        Text("Extracted: \(event.extractedAt, style: .relative)")
                        Text("Created: \(event.createdAt, style: .relative)")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            .padding()
        }
        .navigationTitle("Event Details")
    }
}
