import SwiftUI

struct ConversationListView: View {
    let conversations: [ConversationSummaryViewState]
    let activeSessionId: String?
    let errorMessage: String?
    let onNewChat: () -> Void
    let onSelect: (String) -> Void
    let onRename: (String, String) -> Void
    let onArchive: (String) -> Void
    let onDelete: (String) -> Void

    @State private var searchText = ""
    @State private var renamingConversation: ConversationSummaryViewState?

    private var sections: [ConversationSectionViewState] {
        ConversationService.groupConversations(
            conversations,
            searchQuery: searchText
        )
    }

    var body: some View {
        NavigationStack {
            List {

                if let errorMessage,
                   !errorMessage.isEmpty
                {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.red)
                }

                if sections.isEmpty {
                    Text(searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "No chats yet" : "No matching chats")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(sections) { section in
                        Section(section.title) {
                            ForEach(section.conversations) { conversation in
                                ConversationRowButton(
                                    conversation: conversation,
                                    isActive: conversation.sessionId == activeSessionId,
                                    onSelect: onSelect
                                )
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

                                    Button {
                                        renamingConversation = conversation
                                    } label: {
                                        Label("Rename", systemImage: "pencil")
                                    }
                                    .tint(.blue)
                                }
                                .contextMenu {
                                    Button {
                                        renamingConversation = conversation
                                    } label: {
                                        Label("Rename", systemImage: "pencil")
                                    }

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
                }
            }
            .navigationTitle("Chats")
            .searchable(
                text: $searchText,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: Text("Search chats")
            )
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        onNewChat()
                    } label: {
                        Image(systemName: "square.and.pencil")
                    }
                    .accessibilityLabel("New Chat")
                }
            }
            .sheet(item: $renamingConversation) { conversation in
                RenameConversationSheet(
                    conversation: conversation,
                    onRename: onRename
                )
            }
        }
    }
}

private struct ConversationRowButton: View {
    let conversation: ConversationSummaryViewState
    let isActive: Bool
    let onSelect: (String) -> Void

    var body: some View {
        Button {
            onSelect(conversation.sessionId)
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(conversation.title)
                        .font(.headline)
                        .lineLimit(1)
                        .foregroundStyle(.primary)

                    ConversationMetadataLine(
                        isActive: isActive,
                        date: conversation.lastMessageDate
                    )
                }

                Spacer()

                if isActive {
                    Image(systemName: "checkmark")
                        .foregroundStyle(Color.accentColor)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct ConversationMetadataLine: View {
    let isActive: Bool
    let date: Date?

    var body: some View {
        if isActive || date != nil {
            HStack(spacing: 4) {
                if isActive {
                    Text("Current")
                }
                if isActive, date != nil {
                    Text("·")
                }
                if let date {
                    Text(date, style: .time)
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
    }
}

private struct RenameConversationSheet: View {
    let conversation: ConversationSummaryViewState
    let onRename: (String, String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var title: String

    init(
        conversation: ConversationSummaryViewState,
        onRename: @escaping (String, String) -> Void
    ) {
        self.conversation = conversation
        self.onRename = onRename
        _title = State(initialValue: conversation.title)
    }

    private var trimmedTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Title") {
                    TextField("Conversation title", text: $title)
                        .textInputAutocapitalization(.sentences)
                }
            }
            .navigationTitle("Rename")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onRename(conversation.sessionId, trimmedTitle)
                        dismiss()
                    }
                    .disabled(trimmedTitle.isEmpty || trimmedTitle == conversation.title)
                }
            }
        }
    }
}
