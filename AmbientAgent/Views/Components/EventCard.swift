import SwiftUI
import AmbientCore

struct EventCard: View {
    let event: AmbientEvent

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header
            HStack {
                SourceBadge(sourceType: event.sourceType)

                Spacer()

                if event.isAllDay {
                    Text("All Day")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text(event.startDate, style: .time)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if let endDate = event.endDate {
                        Text("-")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(endDate, style: .time)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            // Title
            Text(event.title)
                .font(.headline)
                .lineLimit(2)

            // Description
            if let description = event.eventDescription, !description.isEmpty {
                Text(description)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            // Footer
            HStack(spacing: 12) {
                if let location = event.location {
                    Label(location, systemImage: "location.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                if event.hasVirtualMeeting {
                    Label(event.virtualMeetingType ?? "Virtual", systemImage: "video.fill")
                        .font(.caption)
                        .foregroundStyle(.blue)
                }

                Spacer()

                if !event.attendees.isEmpty {
                    HStack(spacing: -8) {
                        ForEach(Array(event.attendees.prefix(3).enumerated()), id: \.offset) { _, attendee in
                            Circle()
                                .fill(Color.gray.opacity(0.3))
                                .frame(width: 24, height: 24)
                                .overlay {
                                    Text(attendee.name?.prefix(1).uppercased() ?? "?")
                                        .font(.caption2)
                                        .fontWeight(.medium)
                                }
                        }

                        if event.attendees.count > 3 {
                            Circle()
                                .fill(Color.gray.opacity(0.3))
                                .frame(width: 24, height: 24)
                                .overlay {
                                    Text("+\(event.attendees.count - 3)")
                                        .font(.caption2)
                                }
                        }
                    }
                }
            }
        }
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .contentShape(RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - Source Badge

struct SourceBadge: View {
    let sourceType: SourceType

    var body: some View {
        Label {
            Text(sourceType.displayName)
        } icon: {
            Image(systemName: sourceType.iconName)
        }
        .font(.caption2)
        .fontWeight(.medium)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(color.opacity(0.15))
        .foregroundStyle(color)
        .clipShape(Capsule())
    }

    private var color: Color {
        switch sourceType {
        case .calendar: return .blue
        case .reminders: return .orange
        case .messages: return .green
        case .email, .gmail: return .red
        case .safari: return .purple
        case .notes: return .yellow
        }
    }
}

#Preview {
    VStack {
        EventCard(event: AmbientEvent(
            title: "Team Standup Meeting",
            startDate: Date(),
            sourceType: .calendar,
            sourceIdentifier: "test-1"
        ))
    }
    .padding()
    .frame(width: 400)
}
