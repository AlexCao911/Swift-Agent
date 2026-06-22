import PhotosUI
import SwiftUI
import UIKit

struct ChatView: View {
    @Bindable var viewModel: AgentViewModel
    @State private var scrollProxy: ScrollViewProxy?
    @State private var editingMessage: AgentMessageViewState?
    @State private var editText = ""
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var isAddingLink = false
    @State private var linkText = ""

    var body: some View {
        NavigationStack {
            ZStack {
                Color(.systemBackground)
                    .ignoresSafeArea()
                messageList
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                composerView
                    .background(.thinMaterial)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 2) {
                        Text("Local Agent")
                            .font(.headline)
                        Text(phaseText)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        Task {
                            await viewModel.loadConversations()
                            viewModel.state.conversations.isPresented = true
                        }
                    } label: {
                        Image(systemName: "sidebar.left")
                    }
                    .accessibilityLabel("Chats")
                }

                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        Task { await viewModel.newChat() }
                    } label: {
                        Image(systemName: "square.and.pencil")
                    }
                    .accessibilityLabel("New Chat")
                    .disabled(viewModel.state.phase.isRunning)

                    if viewModel.state.phase.isRunning {
                        Button {
                            Task { await viewModel.cancel() }
                        } label: {
                            Image(systemName: "stop.circle.fill")
                                .symbolRenderingMode(.hierarchical)
                                .foregroundStyle(.red)
                                .font(.system(size: 22))
                        }
                        .accessibilityLabel("Stop")
                    }

                    providerMenu
                }
            }
        }
        .task {
            if case .booting = viewModel.state.phase {
                await viewModel.bootstrap()
            }
        }
        .sheet(isPresented: $viewModel.state.conversations.isPresented) {
            ConversationListView(
                conversations: viewModel.state.conversations.conversations,
                activeSessionId: viewModel.state.currentSessionId,
                onNewChat: {
                    viewModel.state.conversations.isPresented = false
                    Task { await viewModel.newChat() }
                },
                onSelect: { sessionId in
                    viewModel.state.conversations.isPresented = false
                    Task { await viewModel.selectConversation(sessionId) }
                }
            )
        }
        .alert("Edit Message", isPresented: isEditingMessagePresented) {
            TextField("Message", text: $editText)
            Button("Send") {
                guard let editingMessage else {
                    return
                }
                let text = editText
                self.editingMessage = nil
                editText = ""
                Task {
                    await viewModel.editAndResend(messageId: editingMessage.id, text: text)
                }
            }
            Button("Cancel", role: .cancel) {
                editingMessage = nil
                editText = ""
            }
        }
        .alert("Add Link", isPresented: $isAddingLink) {
            TextField("URL", text: $linkText)
            Button("Add") {
                let rawValue = linkText
                linkText = ""
                Task {
                    await viewModel.addLink(rawValue)
                }
            }
            Button("Cancel", role: .cancel) {
                linkText = ""
            }
        }
        .onChange(of: selectedPhotoItem) {
            guard let selectedPhotoItem else {
                return
            }
            Task {
                await loadSelectedPhoto(selectedPhotoItem)
                self.selectedPhotoItem = nil
            }
        }
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 12) {
                    Color.clear.frame(height: 8)

                    ForEach(viewModel.state.messages) { message in
                        MessageBubble(message: message)
                            .id(message.id)
                            .contextMenu {
                                Button {
                                    UIPasteboard.general.string = message.text
                                } label: {
                                    Label("Copy", systemImage: "doc.on.doc")
                                }

                                Button {
                                    Task { await viewModel.forkFromMessage(message.id) }
                                } label: {
                                    Label("Fork from Here", systemImage: "arrow.triangle.branch")
                                }

                                if message.role == .assistant {
                                    Button {
                                        Task { await viewModel.regenerate(from: message.id) }
                                    } label: {
                                        Label("Regenerate", systemImage: "arrow.clockwise")
                                    }

                                    Button {
                                        Task { await viewModel.continueGeneration() }
                                    } label: {
                                        Label("Continue", systemImage: "text.append")
                                    }
                                }

                                if message.role == .user {
                                    Button {
                                        editingMessage = message
                                        editText = message.text
                                    } label: {
                                        Label("Edit and Resend", systemImage: "pencil")
                                    }
                                }
                            }
                    }

                    if let error = viewModel.state.errorMessage {
                        errorView(text: error)
                    }

                    Color.clear.frame(height: 8)
                }
                .padding(.horizontal, 16)
            }
            .scrollDismissesKeyboard(.interactively)
            .onAppear { scrollProxy = proxy }
            .onChange(of: viewModel.state.messages.count) {
                scrollToBottom()
            }
            .onChange(of: viewModel.state.draftText) {
                scrollToBottom()
            }
        }
    }

    private var composerView: some View {
        VStack(spacing: 0) {
            Divider()

            if !viewModel.state.draft.attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(viewModel.state.draft.attachments) { attachment in
                            DraftAttachmentChip(attachment: attachment) {
                                Task { await viewModel.removeAttachment(attachment.id) }
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
                }
            }

            HStack(alignment: .bottom, spacing: 12) {
                Menu {
                    Button {
                        isAddingLink = true
                    } label: {
                        Label("Link", systemImage: "link")
                    }

                    PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
                        Label("Photo", systemImage: "photo")
                    }
                } label: {
                    Image(systemName: "plus.circle")
                        .font(.system(size: 24))
                        .foregroundStyle(.secondary)
                }
                .disabled(viewModel.state.phase.isRunning)

                TextField("Message Local Agent", text: $viewModel.state.draftText, axis: .vertical)
                    .font(.body)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background {
                        Capsule()
                            .fill(Color(.systemGray6))
                    }
                    .overlay {
                        Capsule()
                            .stroke(Color(.separator).opacity(0.5), lineWidth: 0.5)
                    }
                    .lineLimit(1...6)
                    .disabled(viewModel.state.phase.isRunning)

                Button {
                    Task { await viewModel.send() }
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 30))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(
                            isSendDisabled ? Color(.systemGray4) : .white,
                            isSendDisabled ? Color(.systemGray5) : Color.accentColor
                        )
                        .background(Color.white.opacity(0.01))
                }
                .disabled(isSendDisabled)
                .animation(.easeInOut(duration: 0.2), value: isSendDisabled)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
    }

    private func scrollToBottom() {
        guard let lastId = viewModel.state.messages.last?.id else {
            return
        }
        withAnimation(.easeOut(duration: 0.25)) {
            scrollProxy?.scrollTo(lastId, anchor: .bottom)
        }
    }

    private func errorView(text: String) -> some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill")
            Text(text)
        }
        .font(.footnote)
        .foregroundStyle(.white)
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(Color.red.opacity(0.8), in: Capsule())
        .padding(.vertical, 8)
    }

    private var isSendDisabled: Bool {
        (
            viewModel.state.draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && viewModel.state.draft.attachments.isEmpty
        ) || viewModel.state.phase.isRunning
    }

    private var providerMenu: some View {
        Menu {
            ForEach(viewModel.state.provider.profiles, id: \.id) { profile in
                Button {
                    Task { await viewModel.selectProvider(profile.id) }
                } label: {
                    Label(
                        profile.displayName,
                        systemImage: profile.id == viewModel.state.provider.active?.id ? "checkmark" : "cpu"
                    )
                }
                .disabled(viewModel.state.phase.isRunning)
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .accessibilityLabel("Provider")
        .disabled(viewModel.state.provider.profiles.isEmpty)
    }

    private var isEditingMessagePresented: Binding<Bool> {
        Binding(
            get: { editingMessage != nil },
            set: { isPresented in
                if !isPresented {
                    editingMessage = nil
                    editText = ""
                }
            }
        )
    }

    private var phaseText: String {
        switch viewModel.state.phase {
        case .booting: return "Starting"
        case .ready: return "Online"
        case .running: return "Thinking"
        case .failed: return "Disconnected"
        }
    }

    private func loadSelectedPhoto(_ item: PhotosPickerItem) async {
        guard let data = try? await item.loadTransferable(type: Data.self) else {
            viewModel.state.errorMessage = "Unable to load selected photo."
            return
        }

        let contentType = item.supportedContentTypes.first
        let filenameExtension = contentType?.preferredFilenameExtension ?? "jpg"
        await viewModel.addImage(
            data: data,
            suggestedName: "photo.\(filenameExtension)",
            mimeType: contentType?.preferredMIMEType ?? "image/jpeg"
        )
    }
}

private struct DraftAttachmentChip: View {
    let attachment: AttachmentDraftViewState
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: attachment.kind == .image ? "photo" : "link")
            Text(attachment.displayName)
                .lineLimit(1)
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .symbolRenderingMode(.hierarchical)
            }
            .buttonStyle(.plain)
        }
        .font(.footnote)
        .padding(.vertical, 6)
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .background(Color(.secondarySystemBackground), in: Capsule())
    }
}

private struct MessageBubble: View {
    let message: AgentMessageViewState

    private var isUser: Bool {
        message.role == .user
    }

    var body: some View {
        HStack {
            if isUser {
                Spacer(minLength: 60)
            }

            MessageContentView(message: message)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .foregroundStyle(foreground)
                .background {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(background)
                }
                .frame(
                    maxWidth: UIScreen.main.bounds.width * (isUser ? 0.75 : 0.86),
                    alignment: isUser ? .trailing : .leading
                )

            if !isUser {
                Spacer(minLength: 60)
            }
        }
    }

    private var background: AnyShapeStyle {
        if isUser {
            AnyShapeStyle(Color.accentColor)
        } else {
            AnyShapeStyle(Color(.systemGray5))
        }
    }

    private var foreground: Color {
        isUser ? .white : .primary
    }
}
