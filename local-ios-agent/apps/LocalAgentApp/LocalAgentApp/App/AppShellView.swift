import SwiftUI

struct AppShellView: View {
    @Bindable var viewModel: AppShellViewModel
    let container: AppContainer

    @StateObject private var openMinisChatViewModel: AIChatViewModel
    @StateObject private var openMinisChatStore: ChatStore
    @State private var builderViewModel: AgentBuilderViewModel
    @State private var toolCenterViewModel: ToolCenterViewModel
    @State private var modelCenterViewModel: ModelCenterViewModel
    @State private var cloudApprovalRequest: AppCloudApprovalRequest?

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
        OpenMinisContentView(
            shellViewModel: viewModel,
            chatViewModel: openMinisChatViewModel,
            chatStore: openMinisChatStore,
            builderViewModel: builderViewModel,
            toolCenterViewModel: toolCenterViewModel,
            modelCenterViewModel: modelCenterViewModel,
            debugService: container.runDebugService,
            onUsePublishedAgent: usePublishedAgentInChat
        )
        .task {
            for await request in container.cloudApprovalBroker.updates {
                cloudApprovalRequest = request
            }
        }
        .task {
            await openMinisChatViewModel.restore()
            if case let .chat(sessionID) = viewModel.route,
               sessionID != nil {
                synchronizeChatRoute()
            }
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
