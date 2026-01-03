import SwiftUI
import SwiftData
import AmbientCore

struct TaskListView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var modelContext

    @Query(sort: [
        SortDescriptor(\AmbientTask.priorityRaw, order: .reverse),
        SortDescriptor(\AmbientTask.dueDate)
    ])
    private var allTasks: [AmbientTask]

    @State private var filter: TaskFilter = .pending
    @State private var sortOrder: TaskSortOrder = .priority

    private var filteredTasks: [AmbientTask] {
        switch filter {
        case .all:
            return allTasks
        case .pending:
            return allTasks.filter { $0.status == .pending || $0.status == .inProgress }
        case .completed:
            return allTasks.filter { $0.status == .completed }
        case .overdue:
            return allTasks.filter { $0.isOverdue }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Filter bar
            HStack {
                Picker("Filter", selection: $filter) {
                    ForEach(TaskFilter.allCases) { filter in
                        Text(filter.rawValue).tag(filter)
                    }
                }
                .pickerStyle(.segmented)

                Spacer()

                Menu {
                    Picker("Sort", selection: $sortOrder) {
                        ForEach(TaskSortOrder.allCases) { order in
                            Text(order.rawValue).tag(order)
                        }
                    }
                } label: {
                    Label("Sort", systemImage: "arrow.up.arrow.down")
                }
            }
            .padding()

            Divider()

            // Task list
            if filteredTasks.isEmpty {
                ContentUnavailableView(
                    "No Tasks",
                    systemImage: "checklist",
                    description: Text(emptyStateMessage)
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(filteredTasks) { task in
                            TaskRow(task: task)
                                .onTapGesture {
                                    appState.selectedTask = task
                                }
                        }
                    }
                    .padding()
                }
            }
        }
        .navigationTitle("Tasks")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Text("\(filteredTasks.count) tasks")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var emptyStateMessage: String {
        switch filter {
        case .all: return "No tasks have been extracted yet"
        case .pending: return "All tasks are completed!"
        case .completed: return "No completed tasks"
        case .overdue: return "No overdue tasks"
        }
    }
}

// MARK: - Filter & Sort

enum TaskFilter: String, CaseIterable, Identifiable {
    case pending = "Pending"
    case completed = "Completed"
    case overdue = "Overdue"
    case all = "All"

    var id: String { rawValue }
}

enum TaskSortOrder: String, CaseIterable, Identifiable {
    case priority = "Priority"
    case dueDate = "Due Date"
    case created = "Created"

    var id: String { rawValue }
}
