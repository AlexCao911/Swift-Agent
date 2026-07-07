import SwiftUI

struct AppShellView: View {
    @Bindable var viewModel: AppShellViewModel
    let container: AppContainer

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var chatViewModel: AgentViewModel
    @State private var builderViewModel: AgentBuilderViewModel
    @State private var toolCenterViewModel: ToolCenterViewModel
    @State private var modelCenterViewModel: ModelCenterViewModel

    private let primaryFamilies: [AppRouteFamily] = [.chat, .agents, .tools, .models, .settings]

    @MainActor
    init(viewModel: AppShellViewModel, container: AppContainer) {
        self.viewModel = viewModel
        self.container = container
        _chatViewModel = State(initialValue: container.makeAgentViewModel())
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
            ConversationWorkspaceView(
                shellViewModel: viewModel,
                chatViewModel: chatViewModel,
                onOpenBuilder: {
                    viewModel.openBuilder(
                        profileId: viewModel.activeAgent?.profileId,
                        revisionId: viewModel.activeAgent?.profileRevisionId
                    )
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
            ModelCenterView(viewModel: modelCenterViewModel, shellViewModel: viewModel)
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
            snapshot: DebugTraceProjection.project(
                routeRunId: debugRunId,
                activeAgent: viewModel.activeAgent,
                archive: nil
            )
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
        BuilderFirstHostSelection.apply(selection, to: chatViewModel)
        viewModel.open(.chat(sessionId: nil))
    }
}
