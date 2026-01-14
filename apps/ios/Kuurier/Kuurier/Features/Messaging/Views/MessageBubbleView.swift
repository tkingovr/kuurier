import SwiftUI

/// Displays a single message bubble
struct MessageBubbleView: View {
    let message: Message
    let isFromCurrentUser: Bool

    private var bubbleColor: Color {
        isFromCurrentUser ? Color.blue : Color(.systemGray5)
    }

    private var textColor: Color {
        isFromCurrentUser ? .white : .primary
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if isFromCurrentUser {
                Spacer(minLength: 60)
            }

            VStack(alignment: isFromCurrentUser ? .trailing : .leading, spacing: 4) {
                // Sender name (for group chats, not DMs)
                if !isFromCurrentUser {
                    Text(message.senderId.prefix(8) + "...")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }

                // Message bubble
                HStack(alignment: .bottom, spacing: 6) {
                    if message.messageType == .system {
                        // System message style
                        Text(message.decryptedContent ?? "[Encrypted]")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                            .italic()
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Color(.systemGray6))
                            .cornerRadius(12)
                    } else {
                        // Regular message
                        Text(message.decryptedContent ?? "[Encrypted]")
                            .font(.body)
                            .foregroundColor(textColor)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(bubbleColor)
                            .cornerRadius(16)
                    }
                }

                // Timestamp and status
                HStack(spacing: 4) {
                    Text(formatTime(message.createdAt))
                        .font(.caption2)
                        .foregroundColor(.secondary)

                    if message.editedAt != nil {
                        Text("(edited)")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
            }

            if !isFromCurrentUser {
                Spacer(minLength: 60)
            }
        }
    }

    private func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        let calendar = Calendar.current

        if calendar.isDateInToday(date) {
            formatter.dateFormat = "h:mm a"
        } else if calendar.isDateInYesterday(date) {
            formatter.dateFormat = "'Yesterday' h:mm a"
        } else {
            formatter.dateFormat = "MMM d, h:mm a"
        }

        return formatter.string(from: date)
    }
}

/// Date separator view for grouping messages by day
struct MessageDateSeparator: View {
    let date: Date

    var body: some View {
        HStack {
            VStack { Divider() }
            Text(formatDate(date))
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.horizontal, 8)
            VStack { Divider() }
        }
        .padding(.vertical, 8)
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        let calendar = Calendar.current

        if calendar.isDateInToday(date) {
            return "Today"
        } else if calendar.isDateInYesterday(date) {
            return "Yesterday"
        } else {
            formatter.dateFormat = "EEEE, MMMM d"
            return formatter.string(from: date)
        }
    }
}

/// Typing indicator view
struct TypingIndicatorView: View {
    @State private var animationOffset: CGFloat = 0

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            HStack(spacing: 4) {
                ForEach(0..<3) { index in
                    Circle()
                        .fill(Color.secondary)
                        .frame(width: 6, height: 6)
                        .offset(y: animationOffset(for: index))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color(.systemGray5))
            .cornerRadius(16)

            Spacer()
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 0.6).repeatForever()) {
                animationOffset = -4
            }
        }
    }

    private func animationOffset(for index: Int) -> CGFloat {
        let delay = Double(index) * 0.15
        return animationOffset * cos(delay * .pi)
    }
}

#Preview("Sent Message") {
    MessageBubbleView(
        message: Message(
            id: "1",
            channelId: "ch1",
            senderId: "me",
            ciphertext: Data(),
            messageType: .text,
            replyToId: nil,
            createdAt: Date(),
            editedAt: nil,
            decryptedContent: "Hello! This is a test message from me."
        ),
        isFromCurrentUser: true
    )
    .padding()
}

#Preview("Received Message") {
    MessageBubbleView(
        message: Message(
            id: "2",
            channelId: "ch1",
            senderId: "other-user-id",
            ciphertext: Data(),
            messageType: .text,
            replyToId: nil,
            createdAt: Date().addingTimeInterval(-3600),
            editedAt: nil,
            decryptedContent: "Hi there! This is a reply from someone else."
        ),
        isFromCurrentUser: false
    )
    .padding()
}

#Preview("Typing Indicator") {
    TypingIndicatorView()
        .padding()
}
