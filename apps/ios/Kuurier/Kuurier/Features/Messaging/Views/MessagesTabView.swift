import SwiftUI

/// Main messaging tab view with organizations and DMs
struct MessagesTabView: View {
    @StateObject private var messagingService = MessagingService.shared
    @State private var showNewMessage = false
    @State private var showNewOrg = false
    @State private var selectedChannel: Channel?
    @State private var selectedOrg: Organization?
    @State private var channelToDelete: Channel?
    @State private var showDeleteConfirm = false
    @State private var deleteError: String?
    @State private var showDeleteError = false

    var body: some View {
        NavigationStack {
            List {
                // Direct Messages Section
                if !messagingService.dmChannels.isEmpty {
                    Section("Direct Messages") {
                        ForEach(messagingService.dmChannels) { channel in
                            ChannelRowView(channel: channel)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    selectedChannel = channel
                                }
                                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                    Button(role: .destructive) {
                                        channelToDelete = channel
                                        showDeleteConfirm = true
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }

                                    Button {
                                        hideChannel(channel)
                                    } label: {
                                        Label("Hide", systemImage: "eye.slash")
                                    }
                                    .tint(.orange)
                                }
                        }
                    }
                }

                // Event Channels Section
                if !messagingService.eventChannels.isEmpty {
                    Section("Event Chats") {
                        ForEach(messagingService.eventChannels) { channel in
                            EventChannelRowView(channel: channel)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    selectedChannel = channel
                                }
                                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                    Button(role: .destructive) {
                                        channelToDelete = channel
                                        showDeleteConfirm = true
                                    } label: {
                                        Label("Leave", systemImage: "rectangle.portrait.and.arrow.right")
                                    }

                                    Button {
                                        hideChannel(channel)
                                    } label: {
                                        Label("Hide", systemImage: "eye.slash")
                                    }
                                    .tint(.orange)
                                }
                        }
                    }
                }

                // Organizations Section
                if !messagingService.organizations.isEmpty {
                    Section("Organizations") {
                        ForEach(messagingService.organizations) { org in
                            OrganizationRowView(org: org, channelCount: channelCount(for: org))
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    selectedOrg = org
                                }
                        }
                    }
                }

                // Empty state
                if messagingService.organizations.isEmpty && messagingService.dmChannels.isEmpty && messagingService.eventChannels.isEmpty {
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
            .navigationDestination(item: $selectedOrg) { org in
                OrganizationDetailView(organization: org)
            }
            .sheet(isPresented: $showNewMessage) {
                NewMessageView()
            }
            .sheet(isPresented: $showNewOrg) {
                CreateOrganizationView()
            }
            .overlay {
                if messagingService.isLoadingOrgs && messagingService.organizations.isEmpty {
                    ProgressView()
                }
            }
            .alert("Delete Conversation?", isPresented: $showDeleteConfirm) {
                Button("Cancel", role: .cancel) {
                    channelToDelete = nil
                }
                Button("Delete", role: .destructive) {
                    if let channel = channelToDelete {
                        deleteChannel(channel)
                    }
                }
            } message: {
                if let channel = channelToDelete {
                    if channel.type == .dm {
                        Text("This will remove the conversation from your list. The other person will still have their copy.")
                    } else {
                        Text("This will leave the channel. You can rejoin later if it's public.")
                    }
                }
            }
            .alert("Error", isPresented: $showDeleteError) {
                Button("OK") {}
            } message: {
                Text(deleteError ?? "Failed to delete conversation")
            }
        }
    }

    private func loadData() async {
        await messagingService.fetchOrganizations()
        await messagingService.fetchChannels()
    }

    private func channelCount(for org: Organization) -> Int {
        messagingService.channelsByOrg[org.id]?.count ?? 0
    }

    private func deleteChannel(_ channel: Channel) {
        Task {
            do {
                if channel.type == .dm {
                    // For DMs, hide the conversation
                    try await messagingService.hideConversation(channelId: channel.id)
                } else {
                    // For groups/events, leave the channel
                    try await messagingService.leaveChannel(channel.id)
                }
                // Also clear any pending messages for this channel
                PendingMessageStore.shared.clearChannel(channelId: channel.id)
            } catch {
                deleteError = error.localizedDescription
                showDeleteError = true
            }
            channelToDelete = nil
        }
    }

    private func hideChannel(_ channel: Channel) {
        Task {
            do {
                try await messagingService.hideConversation(channelId: channel.id)
            } catch {
                deleteError = error.localizedDescription
                showDeleteError = true
            }
        }
    }
}

// MARK: - Organization Row View

struct OrganizationRowView: View {
    let org: Organization
    let channelCount: Int

    var body: some View {
        HStack(spacing: 12) {
            OrgAvatarView(org: org)

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(org.name)
                        .font(.headline)
                    if let role = org.role, role == "admin" {
                        Image(systemName: "crown.fill")
                            .foregroundColor(.yellow)
                            .font(.caption2)
                    }
                }
                Text("\(org.memberCount) members")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            // Channel count badge
            if channelCount > 0 {
                Text("\(channelCount)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color(.systemGray5))
                    .clipShape(Capsule())
            }

            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Organization Detail View

struct OrganizationDetailView: View {
    let organization: Organization
    @Environment(\.dismiss) private var dismiss
    @StateObject private var messagingService = MessagingService.shared
    @State private var selectedChannel: Channel?
    @State private var showCreateChannel = false
    @State private var showSettings = false
    @State private var governanceInfo: OrgGovernanceInfo?
    @State private var showDeleteConfirm = false
    @State private var showArchiveConfirm = false
    @State private var showLeaveConfirm = false
    @State private var errorMessage: String?
    @State private var showError = false

    private var orgChannels: [Channel] {
        messagingService.channels.filter { $0.orgId == organization.id && $0.type != .dm }
    }

    var body: some View {
        List {
            // Organization header section
            Section {
                VStack(spacing: 16) {
                    // Large avatar
                    OrgAvatarLargeView(org: organization)

                    // Org info
                    VStack(spacing: 4) {
                        HStack {
                            Text(organization.name)
                                .font(.title2)
                                .fontWeight(.bold)
                            if let role = organization.role, role == "admin" {
                                Image(systemName: "crown.fill")
                                    .foregroundColor(.yellow)
                            }
                        }

                        Text("\(organization.memberCount) members")
                            .font(.subheadline)
                            .foregroundColor(.secondary)

                        if let info = governanceInfo {
                            Text("\(info.adminCount) admin\(info.adminCount == 1 ? "" : "s")")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        if let description = organization.description, !description.isEmpty {
                            Text(description)
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                                .padding(.top, 4)
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .listRowBackground(Color.clear)
            }

            // Pending transfer requests
            if let transfers = governanceInfo?.pendingTransfers, !transfers.isEmpty {
                Section("Pending Admin Requests") {
                    ForEach(transfers) { transfer in
                        HStack {
                            VStack(alignment: .leading) {
                                Text("Admin transfer request")
                                    .font(.subheadline)
                                Text("Expires \(transfer.expiresAt, style: .relative)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Button("Accept") {
                                Task { await acceptTransfer(transfer.id) }
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.green)
                            Button("Decline") {
                                Task { await declineTransfer(transfer.id) }
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }
            }

            // Channels section
            Section("Channels") {
                if orgChannels.isEmpty {
                    HStack {
                        Spacer()
                        VStack(spacing: 8) {
                            Image(systemName: "bubble.left.and.bubble.right")
                                .font(.title)
                                .foregroundColor(.secondary)
                            Text("No channels yet")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                        .padding(.vertical, 20)
                        Spacer()
                    }
                } else {
                    ForEach(orgChannels) { channel in
                        ChannelRowView(channel: channel)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                selectedChannel = channel
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) {
                                    leaveChannel(channel)
                                } label: {
                                    Label("Leave", systemImage: "rectangle.portrait.and.arrow.right")
                                }

                                if organization.role == "admin" {
                                    Button {
                                        archiveChannel(channel)
                                    } label: {
                                        Label("Archive", systemImage: "archivebox")
                                    }
                                    .tint(.orange)
                                }
                            }
                    }
                }

                // Create channel button (for admins)
                if organization.role == "admin" {
                    Button(action: { showCreateChannel = true }) {
                        HStack {
                            Image(systemName: "plus.circle.fill")
                                .foregroundColor(.orange)
                            Text("Create Channel")
                                .foregroundColor(.primary)
                        }
                    }
                }
            }

            // Actions section
            Section {
                if organization.role == "admin" {
                    NavigationLink(destination: Text("Invite Members - Coming Soon")) {
                        Label("Invite Members", systemImage: "person.badge.plus")
                    }
                    NavigationLink(destination: OrgSettingsView(organization: organization, governanceInfo: governanceInfo)) {
                        Label("Settings", systemImage: "gear")
                    }
                }

                // Leave button with safeguard check
                Button(role: .destructive, action: { showLeaveConfirm = true }) {
                    Label("Leave Organization", systemImage: "rectangle.portrait.and.arrow.right")
                }
                .disabled(governanceInfo?.canLeave == false)

                // Admin-only danger zone
                if organization.role == "admin" {
                    Button(role: .destructive, action: { showArchiveConfirm = true }) {
                        Label("Archive Organization", systemImage: "archivebox")
                    }

                    if governanceInfo?.canDelete == true {
                        Button(role: .destructive, action: { showDeleteConfirm = true }) {
                            Label("Delete Organization", systemImage: "trash")
                        }
                    }
                }
            } footer: {
                if governanceInfo?.canLeave == false {
                    Text("You cannot leave because you are the only admin. Transfer admin role to another member first.")
                        .font(.caption)
                        .foregroundColor(.red)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(organization.name)
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $selectedChannel) { channel in
            ConversationView(channel: channel)
        }
        .sheet(isPresented: $showCreateChannel) {
            CreateChannelView(organization: organization)
        }
        .alert("Leave Organization?", isPresented: $showLeaveConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Leave", role: .destructive) { leaveOrg() }
        } message: {
            Text("You will no longer have access to this organization's channels.")
        }
        .alert("Archive Organization?", isPresented: $showArchiveConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Archive", role: .destructive) { archiveOrg() }
        } message: {
            Text("The organization will be hidden but can be restored later.")
        }
        .alert("Delete Organization?", isPresented: $showDeleteConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Delete Permanently", role: .destructive) { deleteOrg() }
        } message: {
            Text("This action cannot be undone. All channels and messages will be permanently deleted.")
        }
        .alert("Error", isPresented: $showError) {
            Button("OK") {}
        } message: {
            Text(errorMessage ?? "An error occurred")
        }
        .task {
            await loadGovernanceInfo()
            await messagingService.fetchChannels(forOrg: organization.id)
        }
        .refreshable {
            await loadGovernanceInfo()
            await messagingService.fetchChannels(forOrg: organization.id)
        }
    }

    private func loadGovernanceInfo() async {
        do {
            governanceInfo = try await messagingService.getGovernanceInfo(orgId: organization.id)
        } catch {
            print("Failed to load governance info: \(error)")
        }
    }

    private func leaveOrg() {
        Task {
            do {
                try await messagingService.leaveOrganization(id: organization.id)
                dismiss()
            } catch {
                errorMessage = "Failed to leave organization: \(error.localizedDescription)"
                showError = true
            }
        }
    }

    private func archiveOrg() {
        Task {
            do {
                try await messagingService.archiveOrganization(id: organization.id)
                dismiss()
            } catch {
                errorMessage = "Failed to archive organization: \(error.localizedDescription)"
                showError = true
            }
        }
    }

    private func deleteOrg() {
        Task {
            do {
                try await messagingService.deleteOrganization(id: organization.id)
                dismiss()
            } catch {
                errorMessage = "Failed to delete organization: \(error.localizedDescription)"
                showError = true
            }
        }
    }

    private func acceptTransfer(_ requestId: String) async {
        do {
            try await messagingService.respondToTransfer(requestId: requestId, accept: true)
            await loadGovernanceInfo()
        } catch {
            errorMessage = "Failed to accept transfer: \(error.localizedDescription)"
            showError = true
        }
    }

    private func declineTransfer(_ requestId: String) async {
        do {
            try await messagingService.respondToTransfer(requestId: requestId, accept: false)
            await loadGovernanceInfo()
        } catch {
            errorMessage = "Failed to decline transfer: \(error.localizedDescription)"
            showError = true
        }
    }

    private func leaveChannel(_ channel: Channel) {
        Task {
            do {
                try await messagingService.leaveChannel(channel.id)
                PendingMessageStore.shared.clearChannel(channelId: channel.id)
            } catch {
                errorMessage = "Failed to leave channel: \(error.localizedDescription)"
                showError = true
            }
        }
    }

    private func archiveChannel(_ channel: Channel) {
        Task {
            do {
                try await messagingService.archiveChannel(channelId: channel.id)
            } catch {
                errorMessage = "Failed to archive channel: \(error.localizedDescription)"
                showError = true
            }
        }
    }
}

// MARK: - Organization Settings View

struct OrgSettingsView: View {
    let organization: Organization
    let governanceInfo: OrgGovernanceInfo?

    @State private var showTransferAdmin = false
    @State private var transferUserId = ""
    @State private var isLoading = false
    @State private var showSuccess = false
    @State private var successMessage = ""
    @State private var errorMessage: String?

    var body: some View {
        Form {
            Section("Organization Info") {
                LabeledContent("Members", value: "\(governanceInfo?.memberCount ?? organization.memberCount)")
                LabeledContent("Admins", value: "\(governanceInfo?.adminCount ?? 1)")
                LabeledContent("Minimum Admins", value: "\(governanceInfo?.minAdmins ?? 1)")
            }

            Section {
                Button(action: { showTransferAdmin = true }) {
                    Label("Transfer Admin Role", systemImage: "person.badge.key")
                }

                NavigationLink(destination: Text("Manage Members - Coming Soon")) {
                    Label("Manage Members", systemImage: "person.2")
                }
            } header: {
                Text("Admin Actions")
            } footer: {
                Text("Transferring admin role allows another member to help manage the organization. You will remain an admin unless you demote yourself.")
            }

            Section("Security") {
                NavigationLink(destination: Text("Audit Log - Coming Soon")) {
                    Label("Audit Log", systemImage: "list.bullet.rectangle")
                }
            }
        }
        .navigationTitle("Settings")
        .sheet(isPresented: $showTransferAdmin) {
            NavigationStack {
                Form {
                    Section {
                        TextField("User ID", text: $transferUserId)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    } header: {
                        Text("Transfer Admin Role")
                    } footer: {
                        Text("Enter the user ID of the member you want to promote to admin. They will receive a request to accept.")
                    }
                }
                .navigationTitle("Transfer Admin")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { showTransferAdmin = false }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Send Request") {
                            sendTransferRequest()
                        }
                        .disabled(transferUserId.isEmpty || isLoading)
                    }
                }
            }
        }
        .alert("Success", isPresented: $showSuccess) {
            Button("OK") {}
        } message: {
            Text(successMessage)
        }
        .alert("Error", isPresented: .constant(errorMessage != nil)) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func sendTransferRequest() {
        isLoading = true
        Task {
            do {
                let response = try await MessagingService.shared.requestAdminTransfer(
                    orgId: organization.id,
                    toUserId: transferUserId
                )
                successMessage = response.message
                showSuccess = true
                showTransferAdmin = false
                transferUserId = ""
            } catch {
                errorMessage = error.localizedDescription
            }
            isLoading = false
        }
    }
}

// MARK: - Large Org Avatar

struct OrgAvatarLargeView: View {
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
            .frame(width: 80, height: 80)
            .clipShape(RoundedRectangle(cornerRadius: 16))
        } else {
            initialsView
        }
    }

    private var initialsView: some View {
        RoundedRectangle(cornerRadius: 16)
            .fill(Color(.systemGray5))
            .frame(width: 80, height: 80)
            .overlay {
                Text(String(org.name.prefix(2)).uppercased())
                    .font(.title)
                    .fontWeight(.semibold)
                    .foregroundColor(.secondary)
            }
    }
}

// MARK: - Create Channel View

struct CreateChannelView: View {
    let organization: Organization
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var description = ""
    @State private var isPrivate = false
    @State private var isLoading = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Channel Details") {
                    TextField("Channel name", text: $name)
                        .textInputAutocapitalization(.never)
                    TextField("Description (optional)", text: $description)
                }

                Section {
                    Toggle("Private Channel", isOn: $isPrivate)
                } footer: {
                    Text(isPrivate
                        ? "Only invited members can see and join this channel"
                        : "All organization members can see and join this channel")
                }

                if let error = error {
                    Section {
                        Text(error)
                            .foregroundColor(.red)
                    }
                }
            }
            .navigationTitle("New Channel")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") { createChannel() }
                        .disabled(name.isEmpty || isLoading)
                }
            }
        }
    }

    private func createChannel() {
        isLoading = true
        error = nil
        Task {
            do {
                _ = try await MessagingService.shared.createChannel(
                    in: organization.id,
                    name: name.lowercased().replacingOccurrences(of: " ", with: "-"),
                    description: description.isEmpty ? nil : description,
                    type: isPrivate ? .privateChannel : .publicChannel
                )
                await MessagingService.shared.fetchChannels(forOrg: organization.id)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
            isLoading = false
        }
    }
}

// MARK: - Event Channel Row View

struct EventChannelRowView: View {
    let channel: Channel

    var body: some View {
        HStack(spacing: 12) {
            // Event icon
            Image(systemName: "calendar.badge.clock")
                .font(.title2)
                .foregroundColor(.white)
                .frame(width: 40, height: 40)
                .background(Color.green)
                .cornerRadius(8)

            VStack(alignment: .leading, spacing: 2) {
                Text(channel.displayName.replacingOccurrences(of: "Event: ", with: ""))
                    .font(.body)
                    .fontWeight(.medium)
                    .lineLimit(1)

                HStack(spacing: 4) {
                    Image(systemName: "person.2.fill")
                        .font(.caption2)
                    Text("\(channel.memberCount) attendees")
                        .font(.caption)
                }
                .foregroundColor(.secondary)
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
                    .background(Color.green)
                    .clipShape(Capsule())
            }

            // Last activity time
            if let lastActivity = channel.lastActivity {
                Text(formatEventTime(lastActivity))
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 4)
    }

    private func formatEventTime(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

// MARK: - Channel Row View

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

// MARK: - Org Avatar View

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

// MARK: - New Message View

struct NewMessageView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""
    @State private var isLoading = false

    var body: some View {
        NavigationStack {
            VStack {
                TextField("Enter user ID", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .padding()

                Spacer()

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

// MARK: - Create Organization View

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
                await MessagingService.shared.fetchChannels()
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
            isLoading = false
        }
    }
}

// MARK: - Discover Organizations View

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
