import Foundation
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

// Adapted from OpenMinis' chat palette and message composition. The LocalAgent
// data flow remains owned by the injected facade and Rust-facing runtime.
private enum OpenMinisChatColors {
    static let background = Color(uiColor: .systemBackground)
    static let secondaryBackground = Color(uiColor: .secondarySystemBackground)
    static let inputBackground = Color(uiColor: .secondarySystemBackground)
    static let border = Color(uiColor: .separator).opacity(0.45)
    static let primaryText = Color(uiColor: .label)
    static let secondaryText = Color(uiColor: .secondaryLabel)
    static let userBubble = Color(uiColor: .tertiarySystemFill)
    static let toolBackground = Color(uiColor: .tertiarySystemGroupedBackground)
}

@MainActor
struct OpenMinisProductShellView: View {
    @AppStorage("localagent.ish.raw-networking-disclosure.seen")
    private var hasSeenLinuxNetworkDisclosure = false
    @State private var showsLinuxNetworkDisclosure = false
    @State private var showsConversationSkills = false
    @State private var showsClearConfirmation = false
    @State private var editingMessageID: String?
    @State private var editDraft = ""
    @State private var selectedPhotoItems: [PhotosPickerItem] = []
    @State private var showsFileImporter = false

    @Bindable var shellViewModel: AppShellViewModel
    @ObservedObject var viewModel: AIChatViewModel
    @ObservedObject var chatStore: ChatStore
    var onOpenBuilder: () -> Void
    var onOpenConversation: (String) -> Void
    var onShowConversations: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            productHeader
            Divider()
            messageList
            composer
        }
        .background(OpenMinisChatColors.background)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            KaTeXRenderer.shared.warmUp()
            if !hasSeenLinuxNetworkDisclosure {
                showsLinuxNetworkDisclosure = true
            }
        }
        .alert("Linux Tool Networking", isPresented: $showsLinuxNetworkDisclosure) {
            Button("I Understand") {
                hasSeenLinuxNetworkDisclosure = true
            }
        } message: {
            Text(
                "Linux tools have raw network access enabled. curl, wget, apk, DNS, and sockets use an independent network path and do not pass through the cloud-model egress filter."
            )
        }
        .sheet(isPresented: $showsConversationSkills) {
            NavigationStack {
                SessionSkillsView(
                    conversationStreamID: viewModel.conversationStreamID
                )
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") {
                            showsConversationSkills = false
                        }
                    }
                }
            }
        }
        .alert("Edit message", isPresented: editAlertBinding) {
            TextField("Message", text: $editDraft)
            Button("Cancel", role: .cancel) {
                editingMessageID = nil
            }
            Button("Save") {
                guard let editingMessageID else { return }
                let replacement = editDraft
                self.editingMessageID = nil
                Task {
                    await viewModel.edit(
                        targetEventID: editingMessageID,
                        replacementText: replacement
                    )
                }
            }
        }
        .confirmationDialog(
            "Clear this conversation?",
            isPresented: $showsClearConfirmation,
            titleVisibility: .visible
        ) {
            Button("Clear conversation", role: .destructive) {
                Task { await viewModel.clear() }
            }
        }
        .fileImporter(
            isPresented: $showsFileImporter,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            do {
                for url in try result.get() {
                    try viewModel.addFileAttachment(from: url)
                }
            } catch {
                viewModel.reportAttachmentError(error)
            }
        }
        .onChange(of: selectedPhotoItems) { _, items in
            guard !items.isEmpty else { return }
            selectedPhotoItems = []
            Task {
                for (index, item) in items.enumerated() {
                    do {
                        guard let data = try await item.loadTransferable(
                            type: Data.self
                        ) else { continue }
                        let type = item.supportedContentTypes.first {
                            $0.conforms(to: .image)
                        }
                        try viewModel.addPhotoAttachment(
                            data: data,
                            preferredFilename: "photo-\(index + 1).\(type?.preferredFilenameExtension ?? "jpg")",
                            mediaType: type?.preferredMIMEType ?? "image/jpeg"
                        )
                    } catch {
                        viewModel.reportAttachmentError(error)
                    }
                }
            }
        }
    }

    private var productHeader: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(shellViewModel.activeAgent?.displayName ?? "Local Agent")
                    .font(.headline)
                    .foregroundStyle(OpenMinisChatColors.primaryText)
                Text(shellViewModel.activeModel?.displayName ?? "Choose a model")
                    .font(.caption)
                    .foregroundStyle(OpenMinisChatColors.secondaryText)
            }

            Spacer()

            Button {
                showsConversationSkills = true
            } label: {
                Label("Skills", systemImage: "puzzlepiece.extension")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Conversation Skills")

            Button(action: onOpenBuilder) {
                Label("Agent", systemImage: "slider.horizontal.3")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Configure agent")

            Menu {
                Button(action: onShowConversations) {
                    Label("Conversations", systemImage: "list.bullet")
                }
                Button {
                    onOpenConversation(
                        "conversation-\(UUID().uuidString.lowercased())"
                    )
                } label: {
                    Label("New conversation", systemImage: "square.and.pencil")
                }
                Divider()
                Button(role: .destructive) {
                    showsClearConfirmation = true
                } label: {
                    Label("Clear conversation", systemImage: "eraser")
                }
                Button(role: .destructive) {
                    Task {
                        await viewModel.archive()
                        if viewModel.errorMessage == nil {
                            onOpenConversation(
                                "conversation-\(UUID().uuidString.lowercased())"
                            )
                        }
                    }
                } label: {
                    Label("Archive conversation", systemImage: "archivebox")
                }
            } label: {
                Label("Conversation actions", systemImage: "ellipsis.circle")
                    .labelStyle(.iconOnly)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 18) {
                    if visibleMessages.isEmpty {
                        emptyConversation
                    } else {
                        ForEach(visibleMessages) { message in
                            OpenMinisMessageRow(
                                message: message,
                                onRetry: retryAnchorEventID(for: message).map { anchorID in {
                                    Task {
                                        await viewModel.retry(
                                            anchorEventID: anchorID
                                        )
                                    }
                                }},
                                onEdit: {
                                    editDraft = message.text
                                    editingMessageID = message.id
                                },
                                onDelete: {
                                    Task {
                                        await viewModel.delete(
                                            targetEventID: message.id
                                        )
                                    }
                                },
                                onBranch: {
                                    let branchID =
                                        "conversation-\(UUID().uuidString.lowercased())"
                                    Task {
                                        await viewModel.branch(
                                            anchorEventID: message.id,
                                            newConversationStreamID: branchID
                                        )
                                        if viewModel.errorMessage == nil {
                                            onOpenConversation(branchID)
                                        }
                                    }
                                }
                            )
                                .id(message.id)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 20)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: visibleMessages.count) {
                guard let lastID = visibleMessages.last?.id else {
                    return
                }
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(lastID, anchor: .bottom)
                }
            }
        }
    }

    private var editAlertBinding: Binding<Bool> {
        Binding(
            get: { editingMessageID != nil },
            set: { presented in
                if !presented {
                    editingMessageID = nil
                }
            }
        )
    }

    private var visibleMessages: [ChatMessage] {
        chatStore.projectedMessages(
            conversationStreamID: viewModel.conversationStreamID
        )
    }

    private func retryAnchorEventID(for message: ChatMessage) -> String? {
        guard message.role == .assistant else { return nil }
        return chatStore.retryAnchorEventID(
            forAssistantMessageID: message.id,
            conversationStreamID: viewModel.conversationStreamID
        )
    }

    private var emptyConversation: some View {
        ContentUnavailableView {
            Label("Start a conversation", systemImage: "sparkles")
        } description: {
            Text("Local and cloud models share the same Rust Agent Core.")
        }
        .frame(maxWidth: .infinity, minHeight: 320)
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !viewModel.inputAttachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(viewModel.inputAttachments) { attachment in
                            HStack(spacing: 4) {
                                Label(
                                    attachment.displayName,
                                    systemImage: attachment.kind == .image
                                        ? "photo"
                                        : "doc"
                                )
                                Button {
                                    viewModel.removeInputAttachment(id: attachment.id)
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(
                                    "Remove \(attachment.displayName)"
                                )
                            }
                                .font(.caption)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(OpenMinisChatColors.toolBackground)
                                .clipShape(Capsule())
                        }
                    }
                }
            }

            HStack(alignment: .bottom, spacing: 10) {
                PhotosPicker(
                    selection: $selectedPhotoItems,
                    maxSelectionCount: 10,
                    matching: .images
                ) {
                    Image(systemName: "photo")
                        .frame(width: 28, height: 36)
                }
                .accessibilityLabel("Choose photos")

                Button {
                    showsFileImporter = true
                } label: {
                    Image(systemName: "paperclip")
                        .frame(width: 28, height: 36)
                }
                .accessibilityLabel("Choose files")

                TextField(
                    "Message Local Agent",
                    text: $viewModel.draft,
                    axis: .vertical
                )
                .lineLimit(1...8)
                .textFieldStyle(.plain)
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .background(OpenMinisChatColors.inputBackground)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(OpenMinisChatColors.border, lineWidth: 0.5)
                }
                .onSubmit {
                    Task { await viewModel.send() }
                }

                Button {
                    Task {
                        if viewModel.isRunning {
                            await viewModel.stop()
                        } else {
                            await viewModel.send()
                        }
                    }
                } label: {
                    Image(systemName: viewModel.isRunning ? "stop.fill" : "arrow.up")
                        .font(.system(size: 16, weight: .semibold))
                        .frame(width: 36, height: 36)
                        .foregroundStyle(Color(uiColor: .systemBackground))
                        .background(Color(uiColor: .label))
                        .clipShape(Circle())
                }
                .disabled(
                    !viewModel.isRunning
                        && (
                            viewModel.draft.trimmingCharacters(
                                in: .whitespacesAndNewlines
                            ).isEmpty
                            && viewModel.inputAttachments.isEmpty
                        )
                )
                .accessibilityLabel(
                    viewModel.isRunning ? "Stop response" : "Send message"
                )
            }

            if let errorMessage = viewModel.errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .background(.bar)
    }
}

private struct OpenMinisMessageRow: View {
    let message: AgentMessageViewState
    var onRetry: (() -> Void)?
    var onEdit: () -> Void
    var onDelete: () -> Void
    var onBranch: () -> Void

    var body: some View {
        Group {
            switch message.role {
            case .user:
                HStack {
                    Spacer(minLength: 54)
                    messageBody
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(OpenMinisChatColors.userBubble)
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
            case .assistant:
                HStack {
                    messageBody
                    Spacer(minLength: 24)
                }
            case .tool:
                HStack {
                    messageBody
                        .padding(10)
                        .background(OpenMinisChatColors.toolBackground)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    Spacer(minLength: 24)
                }
            }
        }
        .contextMenu {
            if let onRetry {
                Button(action: onRetry) {
                    Label("Retry from here", systemImage: "arrow.clockwise")
                }
            }
            if message.role == .user {
                Button(action: onEdit) {
                    Label("Edit", systemImage: "pencil")
                }
            }
            if message.role != .tool {
                Button(action: onBranch) {
                    Label("Branch", systemImage: "arrow.triangle.branch")
                }
                Button(role: .destructive, action: onDelete) {
                    Label("Delete from here", systemImage: "trash")
                }
            }
        }
    }

    private var messageBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(message.parts) { part in
                OpenMinisMessagePartView(part: part)
            }

            if !message.attachments.isEmpty {
                ForEach(message.attachments) { attachment in
                    Label(attachment.displayName, systemImage: attachmentIcon(attachment.kind))
                        .font(.caption)
                        .foregroundStyle(OpenMinisChatColors.secondaryText)
                }
            }
            if message.streaming.isStreaming && message.parts.isEmpty {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    private func attachmentIcon(_ kind: AttachmentKindViewState) -> String {
        switch kind {
        case .image:
            "photo"
        case .link:
            "link"
        case .file:
            "doc"
        }
    }
}

private struct OpenMinisMessagePartView: View {
    let part: MessagePartViewState

    var body: some View {
        switch part {
        case let .text(text):
            OpenMinisMarkdownView(text.text)
                .foregroundStyle(OpenMinisChatColors.primaryText)
        case let .reasoning(reasoning):
            DisclosureGroup("Reasoning") {
                OpenMinisMarkdownView(reasoning.text)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 4)
            }
            .font(.callout)
            .foregroundStyle(OpenMinisChatColors.secondaryText)
        case let .tool(tool):
            Label(tool.displayText, systemImage: "wrench.and.screwdriver")
                .font(.callout)
                .foregroundStyle(OpenMinisChatColors.secondaryText)
        case let .error(error):
            Label(error.message, systemImage: "exclamationmark.triangle")
                .font(.callout)
                .foregroundStyle(.red)
        case let .attachment(attachment):
            Label(attachment.displayName, systemImage: "paperclip")
                .font(.callout)
                .foregroundStyle(OpenMinisChatColors.secondaryText)
        }
    }
}
