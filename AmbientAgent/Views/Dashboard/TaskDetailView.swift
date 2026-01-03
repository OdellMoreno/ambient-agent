import SwiftUI
import AmbientCore

struct TaskDetailView: View {
    let task: AmbientTask
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Header
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        SourceBadge(sourceType: task.sourceType)
                        PriorityBadge(priority: task.priority)
                        Spacer()
                        StatusBadge(status: task.status)
                    }

                    Text(task.title)
                        .font(.title)
                        .fontWeight(.bold)
                }

                Divider()

                // Due Date
                if let dueDate = task.dueDate {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Due Date", systemImage: "clock")
                            .font(.headline)

                        HStack {
                            Text(dueDate, format: .dateTime.weekday(.wide).month().day().hour().minute())

                            if task.isOverdue {
                                Text("Overdue")
                                    .font(.caption)
                                    .fontWeight(.semibold)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 2)
                                    .background(.red.opacity(0.15))
                                    .foregroundStyle(.red)
                                    .clipShape(Capsule())
                            }
                        }
                    }
                }

                // Assignee
                if let assignee = task.assigneeName {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Assigned To", systemImage: "person")
                            .font(.headline)

                        HStack {
                            Circle()
                                .fill(Color.blue.opacity(0.2))
                                .frame(width: 32, height: 32)
                                .overlay {
                                    Text(assignee.prefix(1).uppercased())
                                        .font(.caption)
                                        .fontWeight(.semibold)
                                }

                            VStack(alignment: .leading) {
                                Text(assignee)
                                if let email = task.assigneeEmail {
                                    Text(email)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }

                // Context
                if let context = task.context, !context.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Context", systemImage: "text.quote")
                            .font(.headline)

                        Text(context)
                            .font(.body)
                    }
                }

                // Description
                if let description = task.taskDescription, !description.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Description", systemImage: "doc.text")
                            .font(.headline)

                        Text(description)
                            .font(.body)
                    }
                }

                Divider()

                // Actions
                HStack(spacing: 12) {
                    Button {
                        task.markCompleted()
                        try? modelContext.save()
                    } label: {
                        Label("Mark Complete", systemImage: "checkmark.circle")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(task.isCompleted)

                    if task.status == .pending {
                        Button {
                            task.markInProgress()
                            try? modelContext.save()
                        } label: {
                            Label("Start", systemImage: "play.fill")
                        }
                        .buttonStyle(.bordered)
                    }
                }

                // Metadata
                VStack(alignment: .leading, spacing: 4) {
                    Label("Metadata", systemImage: "info.circle")
                        .font(.headline)

                    Group {
                        Text("Confidence: \(task.confidence.rawValue)")
                        Text("Source ID: \(task.sourceIdentifier)")
                        Text("Extracted: \(task.extractedAt, style: .relative)")
                        if let completed = task.completedAt {
                            Text("Completed: \(completed, style: .relative)")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            .padding()
        }
        .navigationTitle("Task Details")
    }
}

struct StatusBadge: View {
    let status: TaskStatus

    var body: some View {
        Text(status.displayName)
            .font(.caption)
            .fontWeight(.semibold)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.15))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }

    private var color: Color {
        switch status {
        case .pending: return .gray
        case .inProgress: return .blue
        case .completed: return .green
        case .cancelled: return .red
        case .deferred: return .orange
        }
    }
}
