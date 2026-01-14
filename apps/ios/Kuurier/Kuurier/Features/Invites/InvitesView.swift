import SwiftUI

struct InvitesView: View {
    @StateObject private var inviteService = InviteService.shared
    @EnvironmentObject var authService: AuthService
    @State private var showingGenerateSheet = false
    @State private var newlyGeneratedInvite: InviteCode?
    @State private var inviteToRevoke: InviteCode?

    var body: some View {
        List {
            // Error display
            if let error = inviteService.error {
                Section {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.red)
                        Text(error)
                            .foregroundColor(.red)
                            .font(.caption)
                    }
                }
            }

            // Stats section
            Section {
                statsView
            }

            // Generate button
            if inviteService.canGenerateInvite {
                Section {
                    Button(action: {
                        Task {
                            if let invite = await inviteService.generateInvite() {
                                newlyGeneratedInvite = invite
                                showingGenerateSheet = true
                            }
                        }
                    }) {
                        HStack {
                            Image(systemName: "plus.circle.fill")
                                .foregroundColor(.orange)
                            Text("Generate New Invite")
                            Spacer()
                            if inviteService.isLoading {
                                ProgressView()
                            }
                        }
                    }
                    .disabled(inviteService.isLoading)
                }
            }

            // Active invites
            if !inviteService.activeInvites.isEmpty {
                Section("Active Invites") {
                    ForEach(inviteService.activeInvites) { invite in
                        InviteCodeRow(invite: invite) {
                            inviteToRevoke = invite
                        }
                    }
                }
            }

            // Used invites
            if !inviteService.usedInvites.isEmpty {
                Section("Used Invites") {
                    ForEach(inviteService.usedInvites) { invite in
                        InviteCodeRow(invite: invite, onRevoke: nil)
                    }
                }
            }

            // Trust requirement info
            if let user = authService.currentUser, user.trustScore < 30 {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Image(systemName: "lock.fill")
                                .foregroundColor(.orange)
                            Text("Invites Locked")
                                .fontWeight(.medium)
                        }
                        Text("You need a trust score of 30 to generate invites. Current: \(user.trustScore)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text("Get vouched by trusted members to increase your score.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .navigationTitle("Invites")
        .navigationBarTitleDisplayMode(.large)
        .refreshable {
            await inviteService.fetchInvites()
        }
        .task {
            await inviteService.fetchInvites()
        }
        .sheet(isPresented: $showingGenerateSheet) {
            if let invite = newlyGeneratedInvite {
                ShareInviteSheet(invite: invite)
            }
        }
        .alert("Revoke Invite?", isPresented: .init(
            get: { inviteToRevoke != nil },
            set: { if !$0 { inviteToRevoke = nil } }
        )) {
            Button("Cancel", role: .cancel) {
                inviteToRevoke = nil
            }
            Button("Revoke", role: .destructive) {
                if let invite = inviteToRevoke {
                    Task {
                        _ = await inviteService.revokeInvite(code: invite.code)
                        inviteToRevoke = nil
                    }
                }
            }
        } message: {
            Text("This invite code will no longer work. You'll get the slot back to create a new one.")
        }
    }

    private var statsView: some View {
        VStack(spacing: 12) {
            HStack {
                StatBox(title: "Available", value: "\(inviteService.availableToMake)", color: .green)
                StatBox(title: "Active", value: "\(inviteService.activeCount)", color: .orange)
                StatBox(title: "Used", value: "\(inviteService.usedCount)", color: .gray)
            }

            if inviteService.totalAllowance > 0 {
                HStack {
                    Text("Total allowance: \(inviteService.totalAllowance)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    Text("Earn more by increasing trust")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Stat Box

struct StatBox: View {
    let title: String
    let value: String
    let color: Color

    var body: some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.title2)
                .fontWeight(.bold)
                .foregroundColor(color)
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(color.opacity(0.1))
        .cornerRadius(8)
    }
}

// MARK: - Invite Code Row

struct InviteCodeRow: View {
    let invite: InviteCode
    let onRevoke: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(invite.code)
                    .font(.system(.body, design: .monospaced))
                    .fontWeight(.semibold)

                Spacer()

                statusBadge
            }

            HStack {
                if invite.status == .active {
                    Text("Expires \(invite.expiresAt, style: .relative)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else if invite.status == .used, let usedAt = invite.usedAt {
                    Text("Used \(usedAt, style: .relative)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                if invite.status == .active {
                    ShareLink(item: shareMessage) {
                        Image(systemName: "square.and.arrow.up")
                            .foregroundColor(.orange)
                    }
                    .buttonStyle(.plain)

                    if let onRevoke = onRevoke {
                        Button(action: onRevoke) {
                            Image(systemName: "trash")
                                .foregroundColor(.red)
                        }
                        .buttonStyle(.plain)
                        .padding(.leading, 8)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var statusBadge: some View {
        Text(invite.status.rawValue.capitalized)
            .font(.caption)
            .fontWeight(.medium)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(statusColor.opacity(0.2))
            .foregroundColor(statusColor)
            .cornerRadius(4)
    }

    private var statusColor: Color {
        switch invite.status {
        case .active: return .green
        case .used: return .gray
        case .expired: return .red
        }
    }

    private var shareMessage: String {
        """
        Join me on Kuurier - the secure platform for activists.

        Use my invite code: \(invite.code)

        Download: https://kuurier.app
        """
    }
}

// MARK: - Share Invite Sheet

struct ShareInviteSheet: View {
    let invite: InviteCode
    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer()

                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 60))
                    .foregroundColor(.green)

                Text("Invite Created!")
                    .font(.title)
                    .fontWeight(.bold)

                VStack(spacing: 8) {
                    Text("Share this code with someone you trust:")
                        .foregroundColor(.secondary)

                    Text(invite.code)
                        .font(.system(.largeTitle, design: .monospaced))
                        .fontWeight(.bold)
                        .foregroundColor(.orange)
                        .padding()
                        .background(Color.orange.opacity(0.1))
                        .cornerRadius(12)
                }

                Text("Expires \(invite.expiresAt, style: .date)")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Spacer()

                VStack(spacing: 12) {
                    Button(action: copyCode) {
                        HStack {
                            Image(systemName: "doc.on.doc")
                            Text("Copy Code")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .padding()
                    .background(Color.orange)
                    .foregroundColor(.white)
                    .cornerRadius(12)

                    ShareLink(item: shareMessage) {
                        HStack {
                            Image(systemName: "square.and.arrow.up")
                            Text("Share")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .padding()
                    .background(Color.gray.opacity(0.2))
                    .foregroundColor(.primary)
                    .cornerRadius(12)
                }
                .padding(.horizontal)

                Spacer()
            }
            .padding()
            .navigationTitle("New Invite")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func copyCode() {
        UIPasteboard.general.string = invite.code
    }

    private var shareMessage: String {
        """
        Join me on Kuurier - the secure platform for activists.

        Use my invite code: \(invite.code)

        Download: https://kuurier.app
        """
    }
}

#Preview {
    NavigationStack {
        InvitesView()
            .environmentObject(AuthService.shared)
    }
}
