import SwiftUI

struct MessageContentView: View {
    let message: AgentMessageViewState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(message.parts) { part in
                switch part {
                case .text(let text):
                    Text(text.text)
                        .font(.body)
                        .textSelection(.enabled)
                case .reasoning(let reasoning):
                    ReasoningBlockView(reasoning: reasoning)
                case .tool(let tool):
                    Label(tool.displayText, systemImage: "wrench.and.screwdriver")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                case .error(let error):
                    Label(error.message, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.red)
                case .attachment(let attachment):
                    AttachmentChipView(attachment: attachment)
                }
            }

            ForEach(message.attachments) { attachment in
                AttachmentChipView(attachment: attachment)
            }

            if message.isStreaming {
                ProgressView()
                    .controlSize(.small)
            }
        }
    }
}

struct ReasoningBlockView: View {
    let reasoning: ReasoningPartViewState
    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            Text(reasoning.text)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 4)
        } label: {
            Label(reasoning.isStreaming ? "Thinking..." : "Reasoning", systemImage: "brain.head.profile")
                .font(.footnote.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .background(
            Color(.secondarySystemBackground),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .onAppear {
            isExpanded = !reasoning.isCollapsed
        }
        .onChange(of: reasoning.isCollapsed) {
            isExpanded = !reasoning.isCollapsed
        }
    }
}

private struct AttachmentChipView: View {
    let attachment: AttachmentViewState

    var body: some View {
        Label(attachment.displayName, systemImage: attachment.kind == .image ? "photo" : "link")
            .font(.footnote)
            .lineLimit(1)
            .padding(.vertical, 6)
            .padding(.horizontal, 10)
            .background(Color(.tertiarySystemBackground), in: Capsule())
    }
}
