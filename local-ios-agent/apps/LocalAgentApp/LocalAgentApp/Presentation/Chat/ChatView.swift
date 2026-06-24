import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct ChatView: View {
    @Bindable var viewModel: AgentViewModel
    @State private var scrollProxy: ScrollViewProxy?
    @State private var editingMessage: AgentMessageViewState?
    @State private var editText = ""
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var isImportingFile = false
    @State private var intentRouter = AppIntentRouter.shared
    @State private var managementSheet: ChatManagementSheet?

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
                    Menu {
                        Button {
                            managementSheet = .prompts
                        } label: {
                            Label("Prompt", systemImage: "text.quote")
                        }

                        Button {
                            managementSheet = .settings
                        } label: {
                            Label("Settings", systemImage: "slider.horizontal.3")
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text("Local Agent")
                                .font(.headline)
                                .foregroundStyle(.primary)
                            
                            Image(systemName: "chevron.down")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .accessibilityLabel("Agent options")
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
                }
            }
        }
        .task {
            if case .booting = viewModel.state.phase {
                await viewModel.bootstrap()
            }
            await handleIntentRouteIfReady()
        }
        .onChange(of: intentRouter.pendingRoute?.id) {
            Task {
                await handleIntentRouteIfReady()
            }
        }
        .onChange(of: viewModel.state.phase.isRunning) {
            Task {
                await handleIntentRouteIfReady()
            }
        }
        .sheet(isPresented: $viewModel.state.conversations.isPresented) {
            ConversationListView(
                conversations: viewModel.state.conversations.conversations,
                activeSessionId: viewModel.state.currentSessionId,
                errorMessage: viewModel.state.conversations.errorMessage,
                onNewChat: {
                    viewModel.state.conversations.isPresented = false
                    Task { await viewModel.newChat() }
                },
                onSelect: { sessionId in
                    viewModel.state.conversations.isPresented = false
                    Task { await viewModel.selectConversation(sessionId) }
                },
                onRename: { sessionId, title in
                    Task { await viewModel.renameConversation(sessionId, title: title) }
                },
                onArchive: { sessionId in
                    Task { await viewModel.archiveConversation(sessionId) }
                },
                onDelete: { sessionId in
                    Task { await viewModel.deleteConversation(sessionId) }
                }
            )
        }
        .sheet(item: $managementSheet) { sheet in
            switch sheet {
            case .prompts:
                PromptLibrarySheet(library: $viewModel.state.promptLibrary)
            case .settings:
                ModelSettingsSheet(settings: $viewModel.state.modelSettings)
            }
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
        .fileImporter(
            isPresented: $isImportingFile,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            Task {
                await importSelectedFiles(result)
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

            if viewModel.state.draft.targetParentEventId != nil {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.triangle.branch")
                    Text("Forking from here")
                        .lineLimit(1)
                    Button {
                        viewModel.clearForkTarget()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .symbolRenderingMode(.hierarchical)
                    }
                    .buttonStyle(.plain)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.top, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

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
                HStack(spacing: 16) {
                    Button {
                        isImportingFile = true
                    } label: {
                        Image(systemName: "paperclip")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(Color.primary)
                    }
                    .tint(.primary)
                    .accessibilityLabel("Add File")

                    PhotosPicker(
                        selection: $selectedPhotoItem,
                        matching: .images
                    ) {
                        Image(systemName: "photo")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(Color.primary)
                    }
                    .tint(.primary)
                    .accessibilityLabel("Add Photo")
                }
                .disabled(viewModel.state.phase.isRunning)
                .padding(.bottom, 11)
                .padding(.leading, 4)

                HStack(alignment: .bottom, spacing: 8) {
                    TextField("Message Local Agent", text: $viewModel.state.draftText, axis: .vertical)
                        .font(.body)
                        .padding(.horizontal, 16)
                        .padding(.top, 10)
                        .padding(.bottom, 10)
                        .lineLimit(1...6)
                        .tint(.primary)
                        .disabled(viewModel.state.phase.isRunning)

                    Button {
                        Task { await viewModel.send() }
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 28))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(
                                isSendDisabled ? Color.primary : .white,
                                isSendDisabled ? Color.primary.opacity(0.1) : Color.primary
                            )
                    }
                    .tint(.primary)
                    .disabled(isSendDisabled)
                    .animation(.easeInOut(duration: 0.2), value: isSendDisabled)
                    .padding(.trailing, 6)
                    .padding(.bottom, 7)
                }
                .background {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(Color(.systemGray6))
                        .overlay {
                            RoundedRectangle(cornerRadius: 20, style: .continuous)
                                .stroke(Color(.separator).opacity(0.3), lineWidth: 0.5)
                        }
                }
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

    private func importSelectedFiles(_ result: Result<[URL], any Error>) async {
        do {
            let urls = try result.get()
            for url in urls {
                await viewModel.addFile(url)
            }
        } catch {
            viewModel.state.errorMessage = "Unable to import selected file."
        }
    }

    @MainActor
    private func handleIntentRouteIfReady() async {
        guard !viewModel.state.phase.isRunning else {
            return
        }
        if case .booting = viewModel.state.phase {
            return
        }
        guard let route = intentRouter.consumePendingRoute() else {
            return
        }

        switch route.destination {
        case .chat:
            if route.startsNewChat {
                await viewModel.startNewChat(prefilledText: route.prefilledText)
            }
        case .conversations:
            await viewModel.loadConversations()
            viewModel.state.conversations.isPresented = true
        case .prompts:
            managementSheet = .prompts
        case .settings:
            managementSheet = .settings
        }
    }
}

private enum ChatManagementSheet: String, Identifiable {
    case prompts
    case settings

    var id: String { rawValue }
}

private struct DraftAttachmentChip: View {
    let attachment: AttachmentDraftViewState
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: attachmentIconName)
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

    private var attachmentIconName: String {
        switch attachment.kind {
        case .image:
            "photo"
        case .link:
            "link"
        case .file:
            "doc.text"
        }
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

            MessageContentView(message: message, isUserMessage: isUser)
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
