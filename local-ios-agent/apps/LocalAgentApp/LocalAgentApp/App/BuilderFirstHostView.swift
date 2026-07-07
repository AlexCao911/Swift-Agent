import SwiftUI

enum BuilderFirstHostSelection {
    @MainActor
    static func apply(_ selection: PublishedAgentSelection, to viewModel: AgentViewModel) {
        viewModel.state.selectedAgentProfileId = selection.profileId
        viewModel.state.selectedAgentProfileRevisionId = selection.profileRevisionId
    }
}

struct BuilderFirstHostView: View {
    @State private var chatViewModel: AgentViewModel
    @State private var builderViewModel: AgentBuilderViewModel
    @State private var isBuilderPresented = false

    @MainActor
    init(container: AppContainer) {
        _chatViewModel = State(initialValue: container.makeAgentViewModel())
        _builderViewModel = State(initialValue: container.makeAgentBuilderViewModel())
    }

    var body: some View {
        ChatView(
            viewModel: chatViewModel,
            onOpenBuilder: {
                isBuilderPresented = true
            }
        )
        .sheet(isPresented: $isBuilderPresented) {
            AgentBuilderView(
                viewModel: builderViewModel,
                onUseInChat: { selection in
                    BuilderFirstHostSelection.apply(selection, to: chatViewModel)
                    isBuilderPresented = false
                }
            )
        }
    }
}
