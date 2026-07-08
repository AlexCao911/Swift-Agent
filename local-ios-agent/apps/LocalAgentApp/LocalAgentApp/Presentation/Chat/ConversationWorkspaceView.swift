import SwiftUI

struct ConversationWorkspaceView: View {
    @Bindable var shellViewModel: AppShellViewModel
    @Bindable var chatViewModel: AgentViewModel
    var onOpenBuilder: () -> Void
    var runInlineCardActionHandler: RunInlineCardActionHandler?

    @State private var workspaceViewModel = ConversationWorkspaceViewModel()
    @State private var isContextInspectorPresented = false

    var body: some View {
        ChatView(
            viewModel: chatViewModel,
            onOpenBuilder: onOpenBuilder,
            onInspectContext: { isContextInspectorPresented = true },
            onRunInlineCardAction: handleRunInlineCardAction
        )
        .sheet(isPresented: $isContextInspectorPresented) {
            ContextInspectorView(
                snapshot: ContextInspectorProjection.project(messages: chatViewModel.state.messages)
            )
        }
        .task {
            syncRuntimeMirror()
        }
        .onChange(of: shellViewModel.activeAgent) {
            syncRuntimeMirror()
        }
    }

    @MainActor
    private func syncRuntimeMirror() {
        guard let activeAgent = shellViewModel.activeAgent,
              let state = try? workspaceViewModel.runtimeStateForSend(
                currentState: chatViewModel.state,
                activeAgent: activeAgent
              )
        else {
            return
        }

        chatViewModel.state = state
    }

    @MainActor
    private func handleRunInlineCardAction(_ card: RunInlineCardState) {
        guard let runInlineCardActionHandler else {
            return
        }

        Task {
            _ = await runInlineCardActionHandler.handle(card)
        }
    }
}
