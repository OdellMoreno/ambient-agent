import SwiftUI
import SwiftData
import AmbientCore

/// Source implementation and permission status
enum SourceStatus {
    case implemented          // Ready to sync
    case needsPermission(String)  // Needs specific permission
    case notImplemented       // Not yet built

    var isActive: Bool {
        if case .implemented = self { return true }
        return false
    }
}

struct SourcesView: View {
    @Environment(AppState.self) private var appState

    @Query(sort: \SyncCursor.lastSyncAt, order: .reverse)
    private var cursors: [SyncCursor]

    @Query private var events: [AmbientEvent]
    @Query private var tasks: [AmbientTask]

    private let availableSources: [SourceType] = [
        .calendar, .messages, .safari, .email, .notes, .reminders, .gmail
    ]

    var body: some View {
        List {
            Section("Data Sources") {
                ForEach(availableSources, id: \.self) { source in
                    SourceRow(
                        sourceType: source,
                        cursor: cursors.first { $0.sourceType == source },
                        status: sourceStatus(source),
                        itemCount: itemCount(for: source),
                        syncError: appState.sourceErrors[source]
                    )
                }
            }

            Section("Sync Statistics") {
                HStack {
                    Label("Events", systemImage: "calendar")
                    Spacer()
                    Text("\(events.count)")
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Label("Tasks", systemImage: "checklist")
                    Spacer()
                    Text("\(tasks.count)")
                        .foregroundStyle(.secondary)
                }

                if let lastSync = appState.lastSyncDate {
                    HStack {
                        Label("Last Sync", systemImage: "clock")
                        Spacer()
                        Text(lastSync, style: .relative)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section {
                Button {
                    Task { await appState.syncAll() }
                } label: {
                    HStack {
                        Label("Sync All Sources", systemImage: "arrow.clockwise")
                        Spacer()
                        if appState.isRefreshing {
                            ProgressView()
                                .scaleEffect(0.7)
                        }
                    }
                }
                .disabled(appState.isRefreshing)

                Button {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
                } label: {
                    Label("Open Privacy Settings", systemImage: "lock.shield")
                }
            }
        }
        .navigationTitle("Sources")
    }

    private func sourceStatus(_ source: SourceType) -> SourceStatus {
        switch source {
        case .calendar, .reminders:
            return .implemented
        case .messages, .safari:
            // These need Full Disk Access
            if appState.sourceErrors[source]?.contains("Full Disk Access") == true {
                return .needsPermission("Full Disk Access")
            }
            return .implemented
        case .email:
            // Apple Mail via ScriptingBridge - needs Automation permission
            return .implemented
        case .notes:
            // Notes via AppleScript - needs Automation permission
            return .implemented
        case .gmail:
            return .notImplemented
        }
    }

    private func itemCount(for source: SourceType) -> Int {
        events.filter { $0.sourceType == source }.count +
        tasks.filter { $0.sourceType == source }.count
    }
}

struct SourceRow: View {
    let sourceType: SourceType
    let cursor: SyncCursor?
    let status: SourceStatus
    let itemCount: Int
    let syncError: String?

    var body: some View {
        HStack {
            Image(systemName: sourceType.iconName)
                .font(.title3)
                .foregroundStyle(status.isActive ? .primary : .secondary)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(sourceType.displayName)
                        .font(.body)

                    if itemCount > 0 {
                        Text("\(itemCount)")
                            .font(.caption)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.blue.opacity(0.2))
                            .foregroundStyle(.blue)
                            .clipShape(Capsule())
                    }
                }

                statusText
            }

            Spacer()

            statusIcon
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var statusText: some View {
        if let error = syncError {
            Text(error)
                .font(.caption)
                .foregroundStyle(.red)
                .lineLimit(1)
        } else if let cursor {
            Text("Synced \(cursor.lastSyncAt, style: .relative)")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            switch status {
            case .implemented:
                Text("Ready to sync")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .needsPermission(let permission):
                Text("Needs \(permission)")
                    .font(.caption)
                    .foregroundStyle(.orange)
            case .notImplemented:
                Text("Coming soon")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch status {
        case .implemented:
            if syncError != nil {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            } else if cursor != nil {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Image(systemName: "circle")
                    .foregroundStyle(.secondary)
            }
        case .needsPermission:
            Image(systemName: "lock.fill")
                .foregroundStyle(.orange)
        case .notImplemented:
            Image(systemName: "clock")
                .foregroundStyle(.secondary)
        }
    }
}
