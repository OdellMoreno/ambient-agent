import SwiftUI

// MARK: - People View
// Shows contacts and relationship insights from message data

struct PeopleView: View {
    @ObservedObject private var service = InsightsService.shared
    @State private var selectedContact: InsightsService.Contact?
    @State private var sortOrder: SortOrder = .messageCount

    enum SortOrder: String, CaseIterable {
        case messageCount = "Most Active"
        case recent = "Most Recent"
        case name = "Name"
    }

    var sortedContacts: [InsightsService.Contact] {
        switch sortOrder {
        case .messageCount:
            return service.contacts.sorted { $0.messageCount > $1.messageCount }
        case .recent:
            return service.contacts.sorted { $0.lastMessageDate > $1.lastMessageDate }
        case .name:
            return service.contacts.sorted { ($0.displayName ?? $0.phoneOrEmail) < ($1.displayName ?? $1.phoneOrEmail) }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Your Network")
                    .font(.title2)
                    .fontWeight(.semibold)

                Spacer()

                Picker("Sort", selection: $sortOrder) {
                    ForEach(SortOrder.allCases, id: \.self) { order in
                        Text(order.rawValue).tag(order)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 280)
            }
            .padding()

            // Summary Cards
            if !service.contacts.isEmpty {
                HStack(spacing: 16) {
                    SummaryCard(
                        title: "Total Contacts",
                        value: "\(service.contacts.count)",
                        icon: "person.2.fill",
                        color: .blue
                    )
                    SummaryCard(
                        title: "Close Friends",
                        value: "\(service.contacts.filter { $0.messageCount >= 100 }.count)",
                        icon: "heart.fill",
                        color: .pink
                    )
                    SummaryCard(
                        title: "Messages (30d)",
                        value: "\(service.contacts.reduce(0) { $0 + $1.messageCount })",
                        icon: "message.fill",
                        color: .green
                    )
                    SummaryCard(
                        title: "Active Today",
                        value: "\(service.contacts.filter { $0.daysSinceContact == 0 }.count)",
                        icon: "clock.fill",
                        color: .orange
                    )
                }
                .padding(.horizontal)
                .padding(.bottom)
            }

            Divider()

            // Contact List
            if service.isLoading {
                ProgressView("Loading contacts...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if service.contacts.isEmpty {
                ContentUnavailableView(
                    "No Contacts Found",
                    systemImage: "person.2.slash",
                    description: Text("Grant Full Disk Access to analyze your messages")
                )
            } else {
                List(sortedContacts, selection: $selectedContact) { contact in
                    ContactRow(contact: contact)
                        .tag(contact)
                        .contextMenu {
                            Button(role: .destructive) {
                                service.blockContact(contact.id)
                            } label: {
                                Label("Block Contact", systemImage: "hand.raised.fill")
                            }
                        }
                }
                .listStyle(.inset)
            }
        }
        .navigationTitle("People")
        .task {
            if service.contacts.isEmpty {
                await service.loadContacts()
            }
        }
        .refreshable {
            await service.loadContacts()
        }
    }
}

// MARK: - Summary Card

struct SummaryCard: View {
    let title: String
    let value: String
    let icon: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: icon)
                    .foregroundStyle(color)
                Spacer()
            }

            Text(value)
                .font(.title)
                .fontWeight(.bold)

            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.controlBackgroundColor))
        .cornerRadius(12)
    }
}

// MARK: - Contact Row

struct ContactRow: View {
    let contact: InsightsService.Contact
    @ObservedObject private var service = InsightsService.shared

    var body: some View {
        HStack(spacing: 12) {
            // Avatar
            ZStack {
                Circle()
                    .fill(avatarColor.gradient)
                    .frame(width: 44, height: 44)

                Text(initials)
                    .font(.headline)
                    .foregroundStyle(.white)
            }

            // Info
            VStack(alignment: .leading, spacing: 4) {
                Text(displayName)
                    .font(.headline)

                HStack(spacing: 8) {
                    // Sent/Received with balance indicator
                    HStack(spacing: 2) {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 8))
                        Text("\(contact.sentCount)")
                        Image(systemName: "arrow.down")
                            .font(.system(size: 8))
                        Text("\(contact.receivedCount)")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    // Reactions (if any)
                    if contact.heartReactions > 0 {
                        HStack(spacing: 2) {
                            Text("❤️")
                                .font(.system(size: 10))
                            Text("\(contact.heartReactions)")
                        }
                        .font(.caption)
                    }

                    if contact.attachmentCount > 0 {
                        HStack(spacing: 2) {
                            Image(systemName: "photo")
                                .font(.system(size: 10))
                            Text("\(contact.attachmentCount)")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }

                    if contact.daysSinceContact == 0 {
                        Text("Today")
                            .font(.caption)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.green.opacity(0.2))
                            .foregroundStyle(.green)
                            .cornerRadius(4)
                    } else if contact.daysSinceContact <= 7 {
                        Text("\(contact.daysSinceContact)d ago")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer()

            // Relationship Strength
            RelationshipBadge(strength: contact.relationshipStrength)
        }
        .padding(.vertical, 4)
    }

    private var displayName: String {
        let name = contact.displayName ?? contact.phoneOrEmail
        return service.privacySafeName(name)
    }

    private var initials: String {
        // Always show initials even in privacy mode (they're already obscured)
        let name = contact.displayName ?? contact.phoneOrEmail
        let parts = name.components(separatedBy: " ")
        if parts.count >= 2 {
            return String(parts[0].prefix(1) + parts[1].prefix(1)).uppercased()
        }
        return String(name.prefix(2)).uppercased()
    }

    private var avatarColor: Color {
        let hash = abs(contact.id.hashValue)
        let colors: [Color] = [.blue, .purple, .pink, .orange, .green, .teal]
        return colors[hash % colors.count]
    }
}

// MARK: - Relationship Badge

struct RelationshipBadge: View {
    let strength: Double

    var body: some View {
        VStack(spacing: 2) {
            Text(label)
                .font(.caption2)
                .fontWeight(.medium)

            // Mini bar
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.gray.opacity(0.2))

                    RoundedRectangle(cornerRadius: 2)
                        .fill(color)
                        .frame(width: geo.size.width * strength)
                }
            }
            .frame(width: 50, height: 4)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(color.opacity(0.1))
        .cornerRadius(6)
    }

    private var label: String {
        switch strength {
        case 0.8...1.0: return "Very Close"
        case 0.6..<0.8: return "Close"
        case 0.4..<0.6: return "Regular"
        case 0.2..<0.4: return "Occasional"
        default: return "New"
        }
    }

    private var color: Color {
        switch strength {
        case 0.8...1.0: return .green
        case 0.6..<0.8: return .blue
        case 0.4..<0.6: return .yellow
        default: return .gray
        }
    }
}

// MARK: - Contact Extension for Identifiable

extension InsightsService.Contact: Hashable {
    static func == (lhs: InsightsService.Contact, rhs: InsightsService.Contact) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

#Preview {
    PeopleView()
}
