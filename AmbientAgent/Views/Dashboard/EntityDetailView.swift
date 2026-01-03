import SwiftUI
import SwiftData
import AmbientCore

struct EntityDetailView: View {
    let entity: Entity

    @Query
    private var allEdges: [AmbientCore.Edge]

    private var relatedEdges: [AmbientCore.Edge] {
        allEdges.filter { edge in
            edge.fromEntity?.id == entity.id || edge.toEntity?.id == entity.id
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Header
                HStack(spacing: 16) {
                    Circle()
                        .fill(Color.blue.opacity(0.2))
                        .frame(width: 64, height: 64)
                        .overlay {
                            Text(entity.name.prefix(1).uppercased())
                                .font(.title)
                                .fontWeight(.semibold)
                                .foregroundStyle(.blue)
                        }

                    VStack(alignment: .leading, spacing: 4) {
                        Text(entity.name)
                            .font(.title)
                            .fontWeight(.bold)

                        Text(entity.entityType.rawValue.capitalized)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }

                Divider()

                // Contact Info (for people)
                if entity.entityType == .person {
                    VStack(alignment: .leading, spacing: 8) {
                        if let email = entity.email {
                            Label(email, systemImage: "envelope")
                        }
                        if let phone = entity.phone {
                            Label(phone, systemImage: "phone")
                        }
                    }
                }

                // Relationships
                if !relatedEdges.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Label("Relationships (\(relatedEdges.count))", systemImage: "point.3.connected.trianglepath.dotted")
                            .font(.headline)

                        ForEach(relatedEdges) { edge in
                            EdgeRow(edge: edge, currentEntity: entity)
                        }
                    }
                }

                // Timestamps
                VStack(alignment: .leading, spacing: 4) {
                    Label("Activity", systemImage: "clock")
                        .font(.headline)

                    if let firstSeen = entity.firstSeenAt {
                        Text("First seen: \(firstSeen, style: .relative)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if let lastSeen = entity.lastSeenAt {
                        Text("Last seen: \(lastSeen, style: .relative)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding()
        }
        .navigationTitle("Entity Details")
    }
}

struct EdgeRow: View {
    let edge: AmbientCore.Edge
    let currentEntity: Entity

    var body: some View {
        HStack {
            Image(systemName: "arrow.right")
                .font(.caption)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text(edge.edgeType.rawValue.replacingOccurrences(of: "_", with: " ").capitalized)
                    .font(.subheadline)

                if let other = otherEntity {
                    Text(other.name)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Text("\(Int(edge.confidence * 100))%")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    private var otherEntity: Entity? {
        if edge.fromEntity?.id == currentEntity.id {
            return edge.toEntity
        } else {
            return edge.fromEntity
        }
    }
}
