import SwiftUI

struct AppShellView: View {
    @Bindable var viewModel: AppShellViewModel
    let container: AppContainer

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var chatViewModel: AgentViewModel
    @State private var builderViewModel: AgentBuilderViewModel

    private let primaryFamilies: [AppRouteFamily] = [.chat, .agents, .tools, .models, .settings]

    @MainActor
    init(viewModel: AppShellViewModel, container: AppContainer) {
        self.viewModel = viewModel
        self.container = container
        _chatViewModel = State(initialValue: container.makeAgentViewModel())
        _builderViewModel = State(initialValue: container.makeAgentBuilderViewModel())
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
            ChatView(
                viewModel: chatViewModel,
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
            ProductPlaceholderView(
                title: "Tools",
                systemImageName: "wrench.and.screwdriver",
                message: "Tool Center will show native capabilities, permissions, approval policy, and audit metadata."
            )
        case .models:
            ProductPlaceholderView(
                title: "Models",
                systemImageName: "cpu",
                message: "Model Center will show local engines, cloud providers, setup status, and active model selection."
            )
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
        List {
            Section("Active Agent") {
                if let activeAgent = viewModel.activeAgent {
                    LabeledContent("Profile", value: activeAgent.profileId)
                    LabeledContent("Revision", value: "\(activeAgent.profileRevisionId)")
                    LabeledContent("Name", value: activeAgent.displayName)
                } else {
                    ContentUnavailableView(
                        "No Active Agent",
                        systemImage: "rectangle.3.group",
                        description: Text("Publish or select an agent to start reliable runs.")
                    )
                }
            }

            Section("Advanced") {
                Toggle("Show Debug", isOn: $viewModel.advancedDebugEnabled)
                Button {
                    viewModel.openDebug(runId: nil)
                } label: {
                    Label("Open Debug", systemImage: "ladybug")
                }
                .disabled(!viewModel.advancedDebugEnabled)
            }
        }
        .navigationTitle("Settings")
    }

    private var debugDestination: some View {
        ProductPlaceholderView(
            title: "Debug",
            systemImageName: "ladybug",
            message: "Runtime traces stay behind the advanced debug affordance."
        )
    }

    @MainActor
    private func usePublishedAgentInChat(_ selection: PublishedAgentSelection) {
        viewModel.usePublishedAgent(selection)
        BuilderFirstHostSelection.apply(selection, to: chatViewModel)
        viewModel.open(.chat(sessionId: nil))
    }
}

private struct ProductPlaceholderView: View {
    var title: String
    var systemImageName: String
    var message: String

    var body: some View {
        ContentUnavailableView(
            title,
            systemImage: systemImageName,
            description: Text(message)
        )
        .navigationTitle(title)
    }
}
