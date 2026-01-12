import SwiftUI

/// Message input area for composing and sending messages
struct ComposeMessageView: View {
    @Binding var text: String
    var isFocused: FocusState<Bool>.Binding
    let onSend: () -> Void

    @State private var textEditorHeight: CGFloat = 36

    private let minHeight: CGFloat = 36
    private let maxHeight: CGFloat = 120

    var body: some View {
        HStack(alignment: .bottom, spacing: 12) {
            // Attachment button (for future media support)
            Button(action: {
                // TODO: Open media picker
            }) {
                Image(systemName: "plus.circle.fill")
                    .font(.title2)
                    .foregroundColor(.secondary)
            }

            // Text input
            ZStack(alignment: .leading) {
                // Placeholder
                if text.isEmpty {
                    Text("Message")
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                }

                // Text editor with dynamic height
                TextEditor(text: $text)
                    .focused(isFocused)
                    .frame(minHeight: minHeight, maxHeight: maxHeight)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color(.systemGray6))
                    .cornerRadius(20)
                    .scrollContentBackground(.hidden)
            }

            // Send button
            Button(action: {
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    onSend()
                }
            }) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title)
                    .foregroundColor(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .secondary : .blue)
            }
            .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(.systemBackground))
    }
}

/// Simplified message input for quick composition
struct SimpleComposeView: View {
    @Binding var text: String
    let placeholder: String
    let onSend: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            TextField(placeholder, text: $text)
                .textFieldStyle(.roundedBorder)
                .submitLabel(.send)
                .onSubmit {
                    if !text.isEmpty {
                        onSend()
                    }
                }

            Button(action: {
                if !text.isEmpty {
                    onSend()
                }
            }) {
                Image(systemName: "paperplane.fill")
                    .foregroundColor(text.isEmpty ? .secondary : .blue)
            }
            .disabled(text.isEmpty)
        }
        .padding()
    }
}

/// Reply indicator shown when replying to a message
struct ReplyIndicatorView: View {
    let message: Message
    let onCancel: () -> Void

    var body: some View {
        HStack {
            Rectangle()
                .fill(Color.blue)
                .frame(width: 3)

            VStack(alignment: .leading, spacing: 2) {
                Text("Replying to")
                    .font(.caption)
                    .foregroundColor(.blue)
                Text(message.decryptedContent ?? "[Encrypted]")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Button(action: onCancel) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(Color(.systemGray6))
    }
}

#Preview {
    struct PreviewWrapper: View {
        @State var text = ""
        @FocusState var isFocused: Bool

        var body: some View {
            VStack {
                Spacer()
                ComposeMessageView(
                    text: $text,
                    isFocused: $isFocused,
                    onSend: { print("Send: \(text)") }
                )
            }
        }
    }

    return PreviewWrapper()
}
