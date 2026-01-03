import SwiftUI
import AmbientCore

struct TaskRow: View {
    let task: AmbientTask
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // Checkbox
            Button {
                toggleComplete()
            } label: {
                Image(systemName: task.isCompleted ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(task.isCompleted ? .green : .secondary)
            }
            .buttonStyle(.plain)

            // Content
            VStack(alignment: .leading, spacing: 4) {
                Text(task.title)
                    .font(.body)
                    .strikethrough(task.isCompleted)
                    .foregroundStyle(task.isCompleted ? .secondary : .primary)

                HStack(spacing: 8) {
                    // Priority
                    if task.priority != .none {
                        PriorityBadge(priority: task.priority)
                    }

                    // Source
                    SourceBadge(sourceType: task.sourceType)

                    // Due date
                    if let dueDate = task.dueDate {
                        Label {
                            Text(dueDate, style: .relative)
                        } icon: {
                            Image(systemName: "clock")
                        }
                        .font(.caption)
                        .foregroundStyle(task.isOverdue ? .red : .secondary)
                    }

                    Spacer()
                }
            }

            Spacer()

            // Confidence indicator
            if task.confidence != .high {
                Image(systemName: task.confidence == .medium ? "exclamationmark.circle" : "questionmark.circle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .help("Extraction confidence: \(task.confidence.rawValue)")
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .contentShape(RoundedRectangle(cornerRadius: 8))
    }

    private func toggleComplete() {
        if task.isCompleted {
            task.status = .pending
            task.completedAt = nil
        } else {
            task.markCompleted()
        }
        try? modelContext.save()
    }
}

// MARK: - Priority Badge

struct PriorityBadge: View {
    let priority: TaskPriority

    var body: some View {
        Text(priority.displayName)
            .font(.caption2)
            .fontWeight(.medium)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.15))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }

    private var color: Color {
        switch priority {
        case .urgent: return .red
        case .high: return .orange
        case .medium: return .yellow
        case .low: return .blue
        case .none: return .gray
        }
    }
}

#Preview {
    VStack {
        TaskRow(task: AmbientTask(
            title: "Review pull request for authentication feature",
            sourceType: .messages,
            sourceIdentifier: "test-1"
        ))
    }
    .padding()
    .frame(width: 400)
}
