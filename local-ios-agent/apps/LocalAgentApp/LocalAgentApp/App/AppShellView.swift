import SwiftUI

struct AppShellView: View {
    @Bindable var viewModel: AppShellViewModel
    let container: AppContainer

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @StateObject private var openMinisChatViewModel: AIChatViewModel
    @StateObject private var openMinisChatStore: ChatStore
    @State private var builderViewModel: AgentBuilderViewModel
    @State private var toolCenterViewModel: ToolCenterViewModel
    @State private var modelCenterViewModel: ModelCenterViewModel
    @State private var cloudApprovalRequest: AppCloudApprovalRequest?

    private let primaryFamilies: [AppRouteFamily] = [.chat, .agents, .tools, .models, .settings]

    @MainActor
    init(viewModel: AppShellViewModel, container: AppContainer) {
        self.viewModel = viewModel
        self.container = container
        let chatStore = container.makeOpenMinisChatStore()
        _openMinisChatViewModel = StateObject(
            wrappedValue: container.makeOpenMinisChatViewModel(
                shellViewModel: viewModel,
                chatStore: chatStore
            )
        )
        _openMinisChatStore = StateObject(
            wrappedValue: chatStore
        )
        _builderViewModel = State(initialValue: container.makeAgentBuilderViewModel())
        _toolCenterViewModel = State(initialValue: container.makeToolCenterViewModel())
        _modelCenterViewModel = State(initialValue: container.makeModelCenterViewModel())
    }

    var body: some View {
        Group {
            if horizontalSizeClass == .regular {
                NavigationSplitView {
                    sidebar
                } detail: {
                    NavigationStack {
                        destination(for: selectedFamily)
                    }
                }
            } else {
                TabView(selection: routeFamilyBinding) {
                    ForEach(primaryFamilies) { family in
                        NavigationStack {
                            destination(for: family)
                        }
                        .tabItem {
                            Label(family.title, systemImage: family.systemImageName)
                        }
                        .tag(family)
                    }
                }
            }
        }
        .task {
            for await request in container.cloudApprovalBroker.updates {
                cloudApprovalRequest = request
            }
        }
        .task {
            synchronizeChatRoute()
        }
        .onChange(of: viewModel.route) {
            synchronizeChatRoute()
        }
        .sheet(item: $cloudApprovalRequest, onDismiss: {
            Task { await container.cloudApprovalBroker.dismissCurrent() }
        }) { request in
            CloudApprovalSheet(request: request) { decision in
                Task { await container.cloudApprovalBroker.respond(decision) }
            }
        }
        .sheet(isPresented: $viewModel.showsConversationList) {
            ConversationListSheet(
                sessions: openMinisChatStore.sessions,
                onSelect: { sessionID in
                    viewModel.showsConversationList = false
                    viewModel.open(.chat(sessionId: sessionID))
                },
                onNewConversation: {
                    viewModel.showsConversationList = false
                    viewModel.open(.chat(sessionId: nil))
                }
            )
        }
        .sheet(isPresented: $viewModel.showsPromptDocuments) {
            NavigationStack {
                PromptDocumentsSettingsView()
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") {
                                viewModel.showsPromptDocuments = false
                            }
                        }
                    }
            }
        }
    }

    private var sidebar: some View {
        List {
            ForEach(primaryFamilies) { family in
                Button {
                    viewModel.open(family.defaultRoute)
                } label: {
                    Label(family.title, systemImage: family.systemImageName)
                }
                .buttonStyle(.plain)
                .foregroundStyle(selectedFamily == family ? .primary : .secondary)
            }
        }
        .navigationTitle("Local Agent")
    }

    private var selectedFamily: AppRouteFamily {
        let family = viewModel.route.family
        return primaryFamilies.contains(family) ? family : .settings
    }

    private var routeFamilyBinding: Binding<AppRouteFamily> {
        Binding(
            get: { selectedFamily },
            set: { family in
                viewModel.open(family.defaultRoute)
            }
        )
    }

    @ViewBuilder
    private func destination(for family: AppRouteFamily) -> some View {
        switch family {
        case .chat:
            OpenMinisProductShellView(
                shellViewModel: viewModel,
                viewModel: openMinisChatViewModel,
                chatStore: openMinisChatStore,
                onOpenBuilder: {
                    viewModel.openBuilder(
                        profileId: viewModel.activeAgent?.profileId,
                        revisionId: viewModel.activeAgent?.profileRevisionId
                    )
                },
                onOpenConversation: { conversationStreamID in
                    viewModel.open(.chat(sessionId: conversationStreamID))
                },
                onShowConversations: {
                    viewModel.showsConversationList = true
                }
            )
            .navigationTitle("Chat")
        case .agents:
            AgentBuilderView(
                viewModel: builderViewModel,
                onUseInChat: usePublishedAgentInChat
            )
        case .tools:
            ToolCenterView(viewModel: toolCenterViewModel)
        case .models:
            ModelCenterView(viewModel: modelCenterViewModel)
        case .settings:
            if case .debug = viewModel.route {
                debugDestination
            } else {
                settingsDestination
            }
        case .debug:
            debugDestination
        }
    }

    private var settingsDestination: some View {
        PrivacySettingsView(
            shellViewModel: viewModel,
            toolCenterViewModel: toolCenterViewModel
        )
    }

    private var debugDestination: some View {
        DebugTraceView(
            routeRunId: debugRunId,
            activeAgent: viewModel.activeAgent,
            debugService: container.runDebugService
        )
    }

    private var debugRunId: String? {
        if case .debug(let runId) = viewModel.route {
            return runId
        }
        return nil
    }

    @MainActor
    private func usePublishedAgentInChat(_ selection: PublishedAgentSelection) {
        viewModel.usePublishedAgent(selection)
        viewModel.open(.chat(sessionId: nil))
    }

    @MainActor
    private func synchronizeChatRoute() {
        guard case let .chat(sessionID) = viewModel.route else {
            return
        }
        let conversationStreamID = sessionID
            ?? viewModel.resolveChatConversationID(
                currentConversationID: openMinisChatViewModel.conversationStreamID
            )
        openMinisChatViewModel.switchConversation(to: conversationStreamID)
        if let draft = viewModel.consumePendingChatDraft() {
            openMinisChatViewModel.prefill(draft)
        }
    }
}

private struct ConversationListSheet: View {
    let sessions: [ChatSession]
    var onSelect: (String) -> Void
    var onNewConversation: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Button(action: onNewConversation) {
                    Label("New conversation", systemImage: "square.and.pencil")
                }
                ForEach(sessions.sorted {
                    ($0.lastMessageDate ?? .distantPast)
                        > ($1.lastMessageDate ?? .distantPast)
                }) { session in
                    Button {
                        onSelect(session.sessionId)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(session.title)
                            Text(session.sessionId)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Conversations")
        }
    }
}
