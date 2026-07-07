import SwiftUI

struct ConversationWorkspaceView: View {
    @Bindable var shellViewModel: AppShellViewModel
    @Bindable var chatViewModel: AgentViewModel
    var onOpenBuilder: () -> Void

    @State private var workspaceViewModel = ConversationWorkspaceViewModel()

    var body: some View {
        ChatView(
            viewModel: chatViewModel,
            onOpenBuilder: onOpenBuilder
        )
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
}
