import SwiftUI

struct ConversationListView: View {
    let conversations: [ConversationSummaryViewState]
    let activeSessionId: String?
    let onNewChat: () -> Void
    let onSelect: (String) -> Void
    let onArchive: (String) -> Void
    let onDelete: (String) -> Void

    var body: some View {
        NavigationStack {
            List {
                Button {
                    onNewChat()
                } label: {
                    Label("New Chat", systemImage: "square.and.pencil")
                }

                Section("Conversations") {
                    ForEach(conversations) { conversation in
                        Button {
                            onSelect(conversation.sessionId)
                        } label: {
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(conversation.title)
                                        .lineLimit(1)
                                        .foregroundStyle(.primary)
                                    if conversation.sessionId == activeSessionId {
                                        Text("Current")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                }
                                Spacer()
                                if conversation.sessionId == activeSessionId {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.tint)
                                }
                            }
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                onDelete(conversation.sessionId)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }

                            Button {
                                onArchive(conversation.sessionId)
                            } label: {
                                Label("Archive", systemImage: "archivebox")
                            }
                            .tint(.gray)
                        }
                        .contextMenu {
                            Button {
                                onArchive(conversation.sessionId)
                            } label: {
                                Label("Archive", systemImage: "archivebox")
                            }

                            Button(role: .destructive) {
                                onDelete(conversation.sessionId)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }
            }
            .navigationTitle("Chats")
        }
    }
}
