import SwiftUI

struct AgentBuilderCardView: View {
    var card: AgentBuilderCardDraft
    var selectedToolCount: Int
    var onSelect: () -> Void
    var onUpdateIdentity: (String, String) -> Void
    var onUpdatePrompt: (String, String, String) -> Void
    var onSetContextStep: (String, Bool) -> Void
    var onConfigureTools: () -> Void
    var onPreviewContext: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button(action: onSelect) {
                header
            }
            .buttonStyle(.plain)

            if case .identity(let payload) = card.payload {
                identityControls(payload)
            }

            if case .prompt(let payload) = card.payload {
                promptControls(payload)
            }

            if case .contextPipeline(let payload) = card.payload {
                contextControls(payload)
            }

            if card.kind == .toolBelt {
                Button {
                    onConfigureTools()
                } label: {
                    Label("Choose Tools", systemImage: "wrench.and.screwdriver")
                }
                .buttonStyle(.bordered)
            }

            if card.kind == .contextPipeline {
                Button {
                    onPreviewContext()
                } label: {
                    Label("Preview Context", systemImage: "eye")
                }
                .buttonStyle(.bordered)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(.quaternary)
        }
        .disabled(!card.isEnabled && card.payload.disabled != nil)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: card.kind.systemImageName)
                .frame(width: 28, height: 28)
                .foregroundStyle(card.isEnabled ? .blue : .secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text(card.kind.title)
                    .font(.headline)
                Text(summary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer()
            statusBadge
        }
    }

    private func identityControls(_ payload: AgentIdentityPayload) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Agent name", text: Binding(
                get: { payload.displayName },
                set: { value in
                    onUpdateIdentity(value, payload.description)
                }
            ))
            .textFieldStyle(.roundedBorder)

            TextField("Description", text: Binding(
                get: { payload.description },
                set: { value in
                    onUpdateIdentity(payload.displayName, value)
                }
            ), axis: .vertical)
            .lineLimit(2...4)
            .textFieldStyle(.roundedBorder)
        }
    }

    private func promptControls(_ payload: PromptPayload) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Persona", text: Binding(
                get: { payload.persona },
                set: { value in
                    onUpdatePrompt(payload.systemPrompt, value, payload.responseStyle)
                }
            ))
            .textFieldStyle(.roundedBorder)

            TextField("Response style", text: Binding(
                get: { payload.responseStyle },
                set: { value in
                    onUpdatePrompt(payload.systemPrompt, payload.persona, value)
                }
            ))
            .textFieldStyle(.roundedBorder)

            TextField("System prompt", text: Binding(
                get: { payload.systemPrompt },
                set: { value in
                    onUpdatePrompt(value, payload.persona, payload.responseStyle)
                }
            ), axis: .vertical)
            .lineLimit(2...5)
            .textFieldStyle(.roundedBorder)
        }
    }

    private func contextControls(_ payload: ContextPipelinePayload) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(payload.steps) { step in
                Toggle(isOn: Binding(
                    get: { step.isEnabled },
                    set: { value in onSetContextStep(step.id, value) }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(step.kind.title)
                            .font(.subheadline)
                        Text(budgetPolicyLabel(for: step))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .disabled(step.budgetPolicy == "required")
            }
        }
    }

    private func budgetPolicyLabel(for step: ContextStepDraft) -> String {
        switch step.budgetPolicy {
        case "required":
            "Required"
        case "budgeted":
            "Budgeted"
        case "disabled":
            "Disabled"
        default:
            step.budgetPolicy
        }
    }

    @ViewBuilder
    private var statusBadge: some View {
        if card.isPublishAffecting {
            Label("Included", systemImage: "checkmark.seal")
                .foregroundStyle(.green)
        } else if card.isEnabled {
            Label("Preview only", systemImage: "eye")
                .foregroundStyle(.secondary)
        } else {
            Label("Later", systemImage: "lock")
                .foregroundStyle(.secondary)
        }
    }

    private var summary: String {
        switch card.payload {
        case .identity(let payload):
            payload.description
        case .prompt(let payload):
            payload.persona
        case .toolBelt:
            selectedToolCount == 0 ? "No tools selected" : "\(selectedToolCount) tools selected"
        case .contextPipeline(let payload):
            "\(payload.steps.filter(\.isEnabled).count) enabled context steps"
        case .disabled(let payload):
            payload.reason
        }
    }
}

struct AgentBuilderBottomBar: View {
    var lifecycle: AgentDraftLifecycleState
    var publishedSelection: PublishedAgentSelection?
    var onValidate: () -> Void
    var onPublish: () -> Void
    var onUseInChat: (PublishedAgentSelection) -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text(statusText)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer()

            Button("Validate", action: onValidate)
                .disabled(lifecycle == .validating || lifecycle == .publishing)

            Button("Publish", action: onPublish)
                .buttonStyle(.borderedProminent)
                .disabled(lifecycle != .readyToPublish)

            if let publishedSelection {
                Button {
                    onUseInChat(publishedSelection)
                } label: {
                    Label("Use", systemImage: "arrow.right.circle")
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("Use published revision \(publishedSelection.profileRevisionId) in Chat")
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
    }

    private var statusText: String {
        switch lifecycle {
        case .empty:
            "No draft loaded"
        case .editing:
            "Editing"
        case .dirty:
            "Draft changed"
        case .validating:
            "Validating..."
        case .invalid:
            "Needs attention"
        case .readyToPublish:
            "Ready to publish"
        case .publishing:
            "Publishing..."
        case .published(let revision):
            "Published revision \(revision)"
        case .publishFailed(let message):
            message
        }
    }
}
