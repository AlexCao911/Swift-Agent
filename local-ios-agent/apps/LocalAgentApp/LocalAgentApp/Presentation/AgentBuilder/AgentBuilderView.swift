import SwiftUI

struct AgentBuilderView: View {
    @Bindable var viewModel: AgentBuilderViewModel
    var onUseInChat: (PublishedAgentSelection) -> Void

    @State private var isToolPickerPresented = false
    @State private var isPreviewPresented = false
    @State private var isPublishReviewPresented = false

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 12) {
                    if let draft = viewModel.draft {
                        ForEach(draft.cards.sorted { $0.position < $1.position }) { card in
                            AgentBuilderCardView(
                                card: card,
                                selectedToolCount: draft.selectedToolIds.count,
                                onSelect: { viewModel.selectCard(card.id) },
                                onUpdateIdentity: { displayName, description in
                                    viewModel.updateIdentity(
                                        displayName: displayName,
                                        description: description
                                    )
                                },
                                onUpdatePrompt: { systemPrompt, persona, responseStyle in
                                    viewModel.updatePrompt(
                                        systemPrompt: systemPrompt,
                                        persona: persona,
                                        responseStyle: responseStyle
                                    )
                                },
                                onSetContextStep: { stepId, isEnabled in
                                    viewModel.setContextStep(stepId, isEnabled: isEnabled)
                                },
                                onConfigureTools: { isToolPickerPresented = true },
                                onPreviewContext: {
                                    Task {
                                        await viewModel.previewContext(
                                            sampleUserMessage: "What should this agent know before answering?"
                                        )
                                        isPreviewPresented = true
                                    }
                                }
                            )
                        }
                    } else {
                        ContentUnavailableView(
                            "No Agent Draft",
                            systemImage: "square.stack.3d.up",
                            description: Text("Load a template to start composing an agent.")
                        )
                    }
                }
                .padding()
            }
            .navigationTitle("Agent Builder")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Review") {
                        isPublishReviewPresented = true
                    }
                    .disabled(viewModel.draft == nil || viewModel.lifecycle == .publishing)
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                AgentBuilderBottomBar(
                    lifecycle: viewModel.lifecycle,
                    publishedSelection: viewModel.publishedAgentSelection,
                    onValidate: { Task { await viewModel.validateCurrentDraft() } },
                    onPublish: { Task { await viewModel.publishCurrentDraft() } },
                    onUseInChat: onUseInChat
                )
                .background(.thinMaterial)
            }
        }
        .task {
            if viewModel.draft == nil {
                await viewModel.load()
            }
        }
        .sheet(isPresented: $isToolPickerPresented) {
            AgentBuilderToolPickerView(
                tools: viewModel.toolCards,
                selectedToolIds: viewModel.draft?.selectedToolIds ?? [],
                onToggle: { toolId in viewModel.toggleTool(toolId) }
            )
        }
        .sheet(isPresented: $isPreviewPresented) {
            AgentBuilderContextPreviewView(preview: viewModel.preview)
        }
        .sheet(isPresented: $isPublishReviewPresented) {
            AgentBuilderPublishReviewView(
                lifecycle: viewModel.lifecycle,
                readiness: viewModel.readiness,
                draft: viewModel.draft,
                publishedSelection: viewModel.publishedAgentSelection,
                onValidate: { Task { await viewModel.validateCurrentDraft() } },
                onPublish: { Task { await viewModel.publishCurrentDraft() } }
            )
        }
    }
}
