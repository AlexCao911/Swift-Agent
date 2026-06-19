import Foundation
import SwiftUI

struct ChatView: View {
    @Bindable var viewModel: AgentViewModel

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                messageList
                Divider()
                composer
            }
            .navigationTitle("Local Agent")
            .toolbar {
                if viewModel.state.phase.isRunning {
                    Button {
                        Task { await viewModel.cancel() }
                    } label: {
                        Image(systemName: "stop.circle")
                    }
                    .accessibilityLabel("Cancel")
                }
            }
            .task {
                if case .booting = viewModel.state.phase {
                    await viewModel.bootstrap()
                }
            }
        }
    }

    private var messageList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                ForEach(viewModel.state.messages) { message in
                    MessageBubble(message: message)
                }
                if let error = viewModel.state.errorMessage {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding()
        }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField("Message", text: $viewModel.state.draft, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...4)
                .disabled(viewModel.state.phase.isRunning)

            Button {
                Task { await viewModel.send() }
            } label: {
                Image(systemName: "paperplane.fill")
            }
            .buttonStyle(.borderedProminent)
            .disabled(viewModel.state.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || viewModel.state.phase.isRunning)
            .accessibilityLabel("Send")
        }
        .padding()
        .background(.background)
    }
}

private struct MessageBubble: View {
    let message: AgentMessageViewState

    var body: some View {
        HStack {
            if message.role == .user {
                Spacer(minLength: 32)
            }

            Text(message.text.isEmpty && message.isStreaming ? "..." : message.text)
                .font(.body)
                .foregroundStyle(foreground)
                .padding(.vertical, 9)
                .padding(.horizontal, 12)
                .background(background, in: RoundedRectangle(cornerRadius: 8))
                .frame(maxWidth: 520, alignment: message.role == .user ? .trailing : .leading)

            if message.role != .user {
                Spacer(minLength: 32)
            }
        }
    }

    private var background: Color {
        switch message.role {
        case .user:
            Color.accentColor
        case .assistant:
            Color(.secondarySystemBackground)
        case .tool:
            Color(.tertiarySystemBackground)
        }
    }

    private var foreground: Color {
        message.role == .user ? .white : .primary
    }
}
