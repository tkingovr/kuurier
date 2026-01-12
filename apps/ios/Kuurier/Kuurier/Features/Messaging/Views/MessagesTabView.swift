import SwiftUI

/// Main messaging tab view with organization and channel list
struct MessagesTabView: View {
    @StateObject private var messagingService = MessagingService.shared
    @State private var showNewMessage = false
    @State private var showNewOrg = false
    @State private var selectedChannel: Channel?

    var body: some View {
        NavigationStack {
            List {
                // Direct Messages Section
                if !messagingService.dmChannels.isEmpty {
                    Section("Direct Messages") {
                        ForEach(messagingService.dmChannels) { channel in
                            ChannelRowView(channel: channel)
                                .onTapGesture {
                                    selectedChannel = channel
                                }
                        }
                    }
                }

                // Organizations & Channels
                ForEach(messagingService.organizations) { org in
                    Section {
                        // Organization header
                        HStack {
                            OrgAvatarView(org: org)
                            VStack(alignment: .leading) {
                                Text(org.name)
                                    .font(.headline)
                                Text("\(org.memberCount) members")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            if let role = org.role, role == "admin" {
                                Image(systemName: "crown.fill")
                                    .foregroundColor(.yellow)
                                    .font(.caption)
                            }
                        }

                        // Channels in this org
                        let orgChannels = messagingService.channelsByOrg[org.id] ?? []
                        ForEach(orgChannels) { channel in
                            ChannelRowView(channel: channel)
                                .onTapGesture {
                                    selectedChannel = channel
                                }
                        }
                    }
                }

                // Empty state
                if messagingService.organizations.isEmpty && messagingService.dmChannels.isEmpty {
                    ContentUnavailableView(
                        "No Conversations",
                        systemImage: "bubble.left.and.bubble.right",
                        description: Text("Join an organization or start a direct message")
                    )
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Messages")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button(action: { showNewMessage = true }) {
                            Label("New Message", systemImage: "square.and.pencil")
                        }
                        Button(action: { showNewOrg = true }) {
                            Label("Create Organization", systemImage: "plus.circle")
                        }
                        NavigationLink(destination: DiscoverOrgsView()) {
                            Label("Discover Organizations", systemImage: "magnifyingglass")
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .refreshable {
                await loadData()
            }
            .task {
                await loadData()
            }
            .navigationDestination(item: $selectedChannel) { channel in
                ConversationView(channel: channel)
            }
            .sheet(isPresented: $showNewMessage) {
                NewMessageView()
            }
            .sheet(isPresented: $showNewOrg) {
                CreateOrganizationView()
            }
            .overlay {
                if messagingService.isLoadingOrgs || messagingService.isLoadingChannels {
                    ProgressView()
                }
            }
        }
    }

    private func loadData() async {
        await messagingService.fetchOrganizations()
        await messagingService.fetchChannels()
    }
}

/// Row view for a channel in the list
struct ChannelRowView: View {
    let channel: Channel

    var body: some View {
        HStack(spacing: 12) {
            // Channel icon
            Image(systemName: channelIcon)
                .foregroundColor(channelColor)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(channel.displayName)
                    .font(.body)
                    .lineLimit(1)

                if let description = channel.description, !description.isEmpty {
                    Text(description)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            // Unread badge
            if channel.unreadCount > 0 {
                Text("\(channel.unreadCount)")
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .foregroundColor(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.blue)
                    .clipShape(Capsule())
            }

            // Last activity time
            if let lastActivity = channel.lastActivity {
                Text(formatTime(lastActivity))
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private var channelIcon: String {
        switch channel.type {
        case .dm:
            return "person.fill"
        case .publicChannel:
            return "number"
        case .privateChannel:
            return "lock.fill"
        case .event:
            return "calendar"
        }
    }

    private var channelColor: Color {
        switch channel.type {
        case .dm:
            return .blue
        case .publicChannel:
            return .primary
        case .privateChannel:
            return .orange
        case .event:
            return .green
        }
    }

    private func formatTime(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

/// Avatar view for organizations
struct OrgAvatarView: View {
    let org: Organization

    var body: some View {
        if let avatarUrl = org.avatarUrl, let url = URL(string: avatarUrl) {
            AsyncImage(url: url) { image in
                image
                    .resizable()
                    .scaledToFill()
            } placeholder: {
                initialsView
            }
            .frame(width: 40, height: 40)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        } else {
            initialsView
        }
    }

    private var initialsView: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(Color(.systemGray5))
            .frame(width: 40, height: 40)
            .overlay {
                Text(String(org.name.prefix(2)).uppercased())
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundColor(.secondary)
            }
    }
}

/// View for creating a new direct message
struct NewMessageView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""
    @State private var isLoading = false

    var body: some View {
        NavigationStack {
            VStack {
                // Search field
                TextField("Enter user ID", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .padding()

                Spacer()

                // Start conversation button
                Button(action: startConversation) {
                    if isLoading {
                        ProgressView()
                    } else {
                        Text("Start Conversation")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(searchText.isEmpty || isLoading)
                .padding()
            }
            .navigationTitle("New Message")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private func startConversation() {
        isLoading = true
        Task {
            do {
                _ = try await MessagingService.shared.getOrCreateDM(with: searchText)
                dismiss()
            } catch {
                print("Failed to create DM: \(error)")
            }
            isLoading = false
        }
    }
}

/// View for creating a new organization
struct CreateOrganizationView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var description = ""
    @State private var isPublic = true
    @State private var isLoading = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Organization Details") {
                    TextField("Name", text: $name)
                    TextField("Description (optional)", text: $description)
                }

                Section {
                    Toggle("Public Organization", isOn: $isPublic)
                } footer: {
                    Text(isPublic
                        ? "Anyone can discover and join this organization"
                        : "Members must be invited to join")
                }

                if let error = error {
                    Section {
                        Text(error)
                            .foregroundColor(.red)
                    }
                }
            }
            .navigationTitle("New Organization")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") { createOrg() }
                        .disabled(name.isEmpty || isLoading)
                }
            }
        }
    }

    private func createOrg() {
        isLoading = true
        error = nil
        Task {
            do {
                _ = try await MessagingService.shared.createOrganization(
                    name: name,
                    description: description.isEmpty ? nil : description,
                    isPublic: isPublic
                )
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
            isLoading = false
        }
    }
}

/// View for discovering public organizations
struct DiscoverOrgsView: View {
    @State private var organizations: [Organization] = []
    @State private var isLoading = false
    @State private var error: String?

    var body: some View {
        List(organizations) { org in
            HStack {
                OrgAvatarView(org: org)
                VStack(alignment: .leading) {
                    Text(org.name)
                        .font(.headline)
                    if let description = org.description {
                        Text(description)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(2)
                    }
                    Text("\(org.memberCount) members")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Button("Join") {
                    Task { await joinOrg(org) }
                }
                .buttonStyle(.bordered)
            }
        }
        .navigationTitle("Discover")
        .task {
            await loadOrgs()
        }
        .refreshable {
            await loadOrgs()
        }
        .overlay {
            if isLoading {
                ProgressView()
            } else if organizations.isEmpty {
                ContentUnavailableView(
                    "No Organizations",
                    systemImage: "building.2",
                    description: Text("No public organizations available")
                )
            }
        }
    }

    private func loadOrgs() async {
        isLoading = true
        do {
            organizations = try await MessagingService.shared.discoverOrganizations()
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }

    private func joinOrg(_ org: Organization) async {
        do {
            try await MessagingService.shared.joinOrganization(id: org.id)
            await loadOrgs()
        } catch {
            print("Failed to join: \(error)")
        }
    }
}

#Preview {
    MessagesTabView()
}
