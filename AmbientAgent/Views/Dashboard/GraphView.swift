import SwiftUI

// MARK: - Graph View
// Shows relationship network from InsightsService contacts

struct GraphView: View {
    @ObservedObject private var service = InsightsService.shared

    var body: some View {
        let _ = NSLog("[GraphView] body - isLoading: %d, contacts count: %d, groupChats count: %d",
                      service.isLoading ? 1 : 0, service.contacts.count, service.groupChats.count)
        ScrollView {
            if service.isLoading {
                ProgressView("Loading network...")
                    .frame(maxWidth: .infinity, minHeight: 300)
            } else if service.contacts.isEmpty {
                ContentUnavailableView(
                    "No Connections",
                    systemImage: "point.3.connected.trianglepath.dotted",
                    description: Text("Your contact network will appear here")
                )
            } else {
                VStack(spacing: 20) {
                    // Network Overview
                    NetworkOverviewCard(contacts: service.contacts, groupChats: service.groupChats)

                    // Top Connections
                    TopConnectionsCard(contacts: service.contacts)

                    // Relationship Tiers
                    RelationshipTiersCard(contacts: service.contacts)

                    // Group Chats Network
                    if !service.groupChats.isEmpty {
                        GroupNetworkCard(groupChats: service.groupChats)
                    }
                }
                .padding()
            }
        }
        .navigationTitle("Network")
        .task {
            if service.contacts.isEmpty {
                await service.loadAllInsights()
            }
        }
        .refreshable {
            await service.loadAllInsights()
        }
    }
}

// MARK: - Network Overview Card

struct NetworkOverviewCard: View {
    let contacts: [InsightsService.Contact]
    let groupChats: [InsightsService.GroupChat]

    private var totalMessages: Int {
        contacts.reduce(0) { $0 + $1.messageCount }
    }

    private var avgPerContact: Int {
        guard !contacts.isEmpty else { return 0 }
        return totalMessages / contacts.count
    }

    private var closeContacts: Int {
        contacts.filter { $0.messageCount >= 100 }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Network Overview")
                .font(.headline)

            HStack(spacing: 20) {
                NetworkStat(title: "Contacts", value: "\(contacts.count)", icon: "person.2.fill", color: .blue)
                NetworkStat(title: "Close", value: "\(closeContacts)", icon: "heart.fill", color: .pink)
                NetworkStat(title: "Groups", value: "\(groupChats.count)", icon: "person.3.fill", color: .purple)
                NetworkStat(title: "Avg Msgs", value: "\(avgPerContact)", icon: "message.fill", color: .green)
            }
        }
        .padding()
        .background(Color(.controlBackgroundColor))
        .cornerRadius(12)
    }
}

struct NetworkStat: View {
    let title: String
    let value: String
    let icon: String
    let color: Color

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(color)

            Text(value)
                .font(.title2)
                .fontWeight(.bold)

            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Top Connections Card

struct TopConnectionsCard: View {
    let contacts: [InsightsService.Contact]
    @ObservedObject private var service = InsightsService.shared

    private var topContacts: [InsightsService.Contact] {
        Array(contacts.sorted { $0.messageCount > $1.messageCount }.prefix(5))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Top Connections")
                .font(.headline)

            ForEach(topContacts) { contact in
                HStack(spacing: 12) {
                    // Avatar
                    Circle()
                        .fill(avatarColor(for: contact).gradient)
                        .frame(width: 40, height: 40)
                        .overlay {
                            Text(initials(for: contact))
                                .font(.caption)
                                .fontWeight(.semibold)
                                .foregroundStyle(.white)
                        }

                    // Info
                    VStack(alignment: .leading, spacing: 2) {
                        Text(service.privacySafeName(contact.displayName ?? contact.phoneOrEmail))
                            .font(.subheadline)
                            .fontWeight(.medium)

                        HStack(spacing: 8) {
                            Label("\(contact.messageCount)", systemImage: "message.fill")
                            if contact.heartReactions > 0 {
                                Text("❤️ \(contact.heartReactions)")
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }

                    Spacer()

                    // Strength indicator
                    VStack(spacing: 4) {
                        Text(strengthLabel(contact.relationshipStrength))
                            .font(.caption2)
                            .fontWeight(.medium)

                        ProgressView(value: contact.relationshipStrength)
                            .frame(width: 50)
                            .tint(strengthColor(contact.relationshipStrength))
                    }
                }
            }
        }
        .padding()
        .background(Color(.controlBackgroundColor))
        .cornerRadius(12)
    }

    private func initials(for contact: InsightsService.Contact) -> String {
        let name = contact.displayName ?? contact.phoneOrEmail
        let parts = name.components(separatedBy: " ")
        if parts.count >= 2 {
            return String(parts[0].prefix(1) + parts[1].prefix(1)).uppercased()
        }
        return String(name.prefix(2)).uppercased()
    }

    private func avatarColor(for contact: InsightsService.Contact) -> Color {
        let hash = abs(contact.id.hashValue)
        let colors: [Color] = [.blue, .purple, .pink, .orange, .green, .teal]
        return colors[hash % colors.count]
    }

    private func strengthLabel(_ strength: Double) -> String {
        switch strength {
        case 0.8...1.0: return "Best"
        case 0.6..<0.8: return "Close"
        case 0.4..<0.6: return "Good"
        default: return "New"
        }
    }

    private func strengthColor(_ strength: Double) -> Color {
        switch strength {
        case 0.8...1.0: return .green
        case 0.6..<0.8: return .blue
        case 0.4..<0.6: return .yellow
        default: return .gray
        }
    }
}

// MARK: - Relationship Tiers Card

struct RelationshipTiersCard: View {
    let contacts: [InsightsService.Contact]

    private var tiers: [(name: String, count: Int, color: Color)] {
        let veryClose = contacts.filter { $0.relationshipStrength >= 0.8 }.count
        let close = contacts.filter { $0.relationshipStrength >= 0.6 && $0.relationshipStrength < 0.8 }.count
        let regular = contacts.filter { $0.relationshipStrength >= 0.4 && $0.relationshipStrength < 0.6 }.count
        let occasional = contacts.filter { $0.relationshipStrength < 0.4 }.count

        return [
            ("Very Close", veryClose, .green),
            ("Close", close, .blue),
            ("Regular", regular, .yellow),
            ("Occasional", occasional, .gray)
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Relationship Tiers")
                .font(.headline)

            HStack(spacing: 12) {
                ForEach(tiers, id: \.name) { tier in
                    VStack(spacing: 8) {
                        ZStack {
                            Circle()
                                .stroke(tier.color.opacity(0.3), lineWidth: 8)
                                .frame(width: 60, height: 60)

                            Circle()
                                .trim(from: 0, to: contacts.isEmpty ? 0 : CGFloat(tier.count) / CGFloat(contacts.count))
                                .stroke(tier.color, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                                .frame(width: 60, height: 60)
                                .rotationEffect(.degrees(-90))

                            Text("\(tier.count)")
                                .font(.headline)
                        }

                        Text(tier.name)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .padding()
        .background(Color(.controlBackgroundColor))
        .cornerRadius(12)
    }
}

// MARK: - Group Network Card

struct GroupNetworkCard: View {
    let groupChats: [InsightsService.GroupChat]
    @ObservedObject private var service = InsightsService.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Group Chats")
                .font(.headline)

            ForEach(groupChats) { chat in
                HStack(spacing: 12) {
                    Circle()
                        .fill(Color.purple.gradient)
                        .frame(width: 40, height: 40)
                        .overlay {
                            Image(systemName: "person.3.fill")
                                .font(.system(size: 14))
                                .foregroundStyle(.white)
                        }

                    VStack(alignment: .leading, spacing: 2) {
                        Text(service.privacySafeName(chat.name))
                            .font(.subheadline)
                            .fontWeight(.medium)

                        HStack(spacing: 8) {
                            Label("\(chat.messageCount)", systemImage: "message.fill")
                            Label("\(chat.participantCount)", systemImage: "person.2")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }

                    Spacer()
                }
            }
        }
        .padding()
        .background(Color(.controlBackgroundColor))
        .cornerRadius(12)
    }
}

#Preview {
    GraphView()
}
