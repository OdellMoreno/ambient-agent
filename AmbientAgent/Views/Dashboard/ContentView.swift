import SwiftUI
import SwiftData
import AmbientCore

struct ContentView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var state = appState

        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 180, ideal: 200)
        } content: {
            ContentListView()
                .navigationSplitViewColumnWidth(min: 300, ideal: 400)
        } detail: {
            DetailView()
        }
        .searchable(text: $state.searchText, prompt: "Search events, tasks, people...")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if appState.isRefreshing {
                    ProgressView()
                        .scaleEffect(0.7)
                } else {
                    Button {
                        Task { await appState.syncAll() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .help("Sync Now")
                }

                Button {
                    appState.showingSettings = true
                } label: {
                    Image(systemName: "gear")
                }
                .help("Settings")
            }

            ToolbarItem(placement: .status) {
                HStack(spacing: 4) {
                    Circle()
                        .fill(appState.isMonitoringActive ? .green : .gray)
                        .frame(width: 8, height: 8)
                    Text(appState.isMonitoringActive ? "Monitoring" : "Paused")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

// MARK: - Sidebar

struct SidebarView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var state = appState

        List(selection: $state.selectedTab) {
            Section("Overview") {
                ForEach([DashboardTab.today, .upcoming, .tasks]) { tab in
                    Label(tab.rawValue, systemImage: tab.icon)
                        .tag(tab)
                }
            }

            Section("Insights") {
                Label(DashboardTab.insights.rawValue, systemImage: DashboardTab.insights.icon)
                    .tag(DashboardTab.insights)
                Label(DashboardTab.people.rawValue, systemImage: DashboardTab.people.icon)
                    .tag(DashboardTab.people)
                Label(DashboardTab.activity.rawValue, systemImage: DashboardTab.activity.icon)
                    .tag(DashboardTab.activity)
                Label(DashboardTab.graph.rawValue, systemImage: DashboardTab.graph.icon)
                    .tag(DashboardTab.graph)
                Label(DashboardTab.ai.rawValue, systemImage: DashboardTab.ai.icon)
                    .tag(DashboardTab.ai)
            }

            Section("System") {
                Label(DashboardTab.sources.rawValue, systemImage: DashboardTab.sources.icon)
                    .tag(DashboardTab.sources)
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Ambient")
    }
}

// MARK: - Content List

struct ContentListView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        let _ = NSLog("[ContentListView] selectedTab: %@", appState.selectedTab.rawValue)
        switch appState.selectedTab {
        case .today:
            TodayView()
        case .upcoming:
            UpcomingView()
        case .tasks:
            TaskListView()
        case .insights:
            InsightsView()
        case .people:
            PeopleView()
        case .activity:
            ActivityView()
        case .graph:
            GraphView()
        case .ai:
            AIInsightsView()
        case .sources:
            SourcesView()
        }
    }
}

// MARK: - Detail View Router

struct DetailView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        if let event = appState.selectedEvent {
            EventDetailView(event: event)
        } else if let task = appState.selectedTask {
            TaskDetailView(task: task)
        } else if let entity = appState.selectedEntity {
            EntityDetailView(entity: entity)
        } else {
            ContentUnavailableView(
                "Select an Item",
                systemImage: "sidebar.right",
                description: Text("Choose an event, task, or person to view details")
            )
        }
    }
}

#Preview {
    ContentView()
        .environment(AppState())
        .modelContainer(for: [AmbientEvent.self, AmbientTask.self])
}
