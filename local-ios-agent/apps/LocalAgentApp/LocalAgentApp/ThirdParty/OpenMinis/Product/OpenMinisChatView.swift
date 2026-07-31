import CoreTransferable
import Foundation
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct OpenMinisPickedPhoto: Transferable, Sendable {
    let fileURL: URL
    let displayName: String
    let mediaType: String
    let byteCount: Int

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image) { received in
            try importing(fileURL: received.file)
        }
    }

    static func importing(
        fileURL: URL,
        cacheDirectory: URL = FileManager.default.temporaryDirectory.appending(
            path: "LocalAgentPhotoImports",
            directoryHint: .isDirectory
        )
    ) throws -> Self {
        let values = try fileURL.resourceValues(forKeys: [.fileSizeKey])
        let displayName = fileURL.lastPathComponent.isEmpty
            ? "photo.jpg"
            : fileURL.lastPathComponent
        guard let byteCount = values.fileSize else {
            throw OpenMinisPickedPhotoError.sizeUnavailable(displayName)
        }
        guard byteCount <= OpenMinisAttachmentPolicy.productDefault
            .maximumSingleAttachmentBytes
        else {
            throw OpenMinisPickedPhotoError.tooLarge(displayName)
        }

        try FileManager.default.createDirectory(
            at: cacheDirectory,
            withIntermediateDirectories: true
        )
        let destination = cacheDirectory.appending(
            path: "\(UUID().uuidString.lowercased())-\(displayName)"
        )
        try FileManager.default.copyItem(at: fileURL, to: destination)
        guard let copiedByteCount = try destination.resourceValues(
            forKeys: [.fileSizeKey]
        ).fileSize else {
            try? FileManager.default.removeItem(at: destination)
            throw OpenMinisPickedPhotoError.sizeUnavailable(displayName)
        }
        guard copiedByteCount <= OpenMinisAttachmentPolicy.productDefault
            .maximumSingleAttachmentBytes
        else {
            try? FileManager.default.removeItem(at: destination)
            throw OpenMinisPickedPhotoError.tooLarge(displayName)
        }
        let type = UTType(filenameExtension: fileURL.pathExtension)
        return Self(
            fileURL: destination,
            displayName: displayName,
            mediaType: type?.preferredMIMEType ?? "image/jpeg",
            byteCount: copiedByteCount
        )
    }
}

private enum OpenMinisPickedPhotoError: LocalizedError {
    case sizeUnavailable(String)
    case tooLarge(String)

    var errorDescription: String? {
        switch self {
        case let .sizeUnavailable(name):
            "Attachment size is unavailable for \(name)"
        case let .tooLarge(name):
            "Attachment \(name) exceeds the configured size limit"
        }
    }
}

// Adapted from OpenMinis' AIChatView presentation. Conversation mutations still
// leave this view through the injected Rust-facing facade.
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
struct OpenMinisChatView: View {
    @AppStorage("localagent.ish.raw-networking-disclosure.seen")
    private var hasSeenLinuxNetworkDisclosure = false
    @State private var showsLinuxNetworkDisclosure = false
    @State private var showsConversationSkills = false
    @State private var showsClearConfirmation = false
    @State private var editingMessageID: String?
    @State private var editDraft = ""
    @State private var selectedPhotoItems: [PhotosPickerItem] = []
    @State private var showsFileImporter = false
    @ObservedObject private var skillStore = SkillStore.shared

    @Bindable var shellViewModel: AppShellViewModel
    @ObservedObject var viewModel: AIChatViewModel
    @ObservedObject var chatStore: ChatStore
    var onOpenBuilder: () -> Void
    var onOpenModels: () -> Void
    var onOpenConversation: (String) -> Void
    var onShowConversations: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            messageList
            composer
        }
        .background(OpenMinisChatColors.background)
        .navigationTitle(currentSessionTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Button(action: onOpenModels) {
                    VStack(spacing: 1) {
                        Text(currentSessionTitle)
                            .font(.headline)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        HStack(spacing: 3) {
                            Text(
                                shellViewModel.activeModel?.displayName
                                    ?? "Choose a model"
                            )
                            Image(systemName: "chevron.down")
                                .font(.system(size: 8, weight: .semibold))
                        }
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Choose local or cloud model")
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    showsConversationSkills = true
                } label: {
                    Label("Conversation Skills", systemImage: "puzzlepiece.extension")
                }

                conversationMenu
            }
        }
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
                for item in items {
                    do {
                        guard let photo = try await item.loadTransferable(
                            type: OpenMinisPickedPhoto.self
                        ) else { continue }
                        viewModel.addPhotoAttachment(photo)
                    } catch {
                        viewModel.reportAttachmentError(error)
                    }
                }
            }
        }
    }

    private var currentSessionTitle: String {
        chatStore.sessions.first {
            $0.sessionId == viewModel.conversationStreamID
        }?.title ?? shellViewModel.activeAgent?.displayName ?? "Minis"
    }

    private var conversationMenu: some View {
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
            Button(action: onOpenBuilder) {
                Label("Configure Agent", systemImage: "slider.horizontal.3")
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
            Label("Conversation actions", systemImage: "ellipsis")
        }
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
        VStack(spacing: 12) {
            Spacer(minLength: 100)
            Image(systemName: "sparkles")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.tertiary)
            Text(shellViewModel.activeAgent?.displayName ?? "Minis")
                .font(.title3.weight(.semibold))
            Text("What can I help you with?")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer(minLength: 100)
        }
        .frame(maxWidth: .infinity, minHeight: 420)
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !slashSkillMatches.isEmpty {
                VStack(spacing: 0) {
                    ForEach(slashSkillMatches.prefix(6)) { skill in
                        Button {
                            skillStore.activateFromSlash(
                                skillID: skill.id,
                                conversationStreamID: viewModel.conversationStreamID
                            )
                            viewModel.draft = "/\(skill.id) "
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "puzzlepiece.extension")
                                    .foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(skill.name)
                                        .foregroundStyle(.primary)
                                    if !skill.description.isEmpty {
                                        Text(skill.description)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                }
                                Spacer()
                                if skillStore.isEnabled(
                                    skill.id,
                                    for: viewModel.conversationStreamID
                                ) {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 9)
                        }
                        .buttonStyle(.plain)

                        if skill.id != slashSkillMatches.prefix(6).last?.id {
                            Divider().padding(.leading, 42)
                        }
                    }
                }
                .background(.regularMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(OpenMinisChatColors.border, lineWidth: 0.5)
                }
            }

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
                Menu {
                    PhotosPicker(
                        selection: $selectedPhotoItems,
                        maxSelectionCount: 10,
                        matching: .images
                    ) {
                        Label("Photo Library", systemImage: "photo")
                    }

                    Button {
                        showsFileImporter = true
                    } label: {
                        Label("Choose Files", systemImage: "doc")
                    }
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 18, weight: .medium))
                        .frame(width: 36, height: 36)
                        .background(OpenMinisChatColors.secondaryBackground)
                        .clipShape(Circle())
                }
                .accessibilityLabel("Add attachment")

                TextField(
                    "Message \(shellViewModel.activeAgent?.displayName ?? "Minis")",
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
        .background(.ultraThinMaterial)
    }

    private var slashSkillMatches: [Skill] {
        guard viewModel.draft.hasPrefix("/") else { return [] }
        let command = viewModel.draft.dropFirst()
        guard command.allSatisfy({ !$0.isWhitespace }) else { return [] }
        return skillStore.slashCommandMatches(
            query: String(command),
            conversationStreamID: viewModel.conversationStreamID
        )
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
