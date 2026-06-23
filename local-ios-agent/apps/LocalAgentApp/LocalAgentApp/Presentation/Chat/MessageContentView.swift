import SwiftUI
import UIKit

struct MessageContentView: View {
    let message: AgentMessageViewState
    let isUserMessage: Bool

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
                    AttachmentChipView(attachment: attachment, isUserMessage: isUserMessage)
                }
            }

            ForEach(message.attachments) { attachment in
                AttachmentChipView(attachment: attachment, isUserMessage: isUserMessage)
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
    let isUserMessage: Bool

    var body: some View {
        if attachment.kind == .image, let image = image {
            VStack(alignment: .leading, spacing: 6) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 148, height: 104)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                Label(attachment.displayName, systemImage: "photo")
                    .font(.caption2)
                    .lineLimit(1)
                    .foregroundStyle(labelForeground)
            }
            .padding(6)
            .background(chipBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        } else {
            Label(attachment.displayName, systemImage: attachment.kind == .image ? "photo" : "link")
                .font(.footnote)
                .lineLimit(1)
                .foregroundStyle(labelForeground)
                .padding(.vertical, 6)
                .padding(.horizontal, 10)
                .background(chipBackground, in: Capsule())
        }
    }

    private var image: UIImage? {
        guard let localPath = attachment.localPath else {
            return nil
        }
        return UIImage(contentsOfFile: localPath)
    }

    private var labelForeground: Color {
        isUserMessage ? .white : .primary
    }

    private var chipBackground: Color {
        isUserMessage ? .white.opacity(0.18) : Color(.tertiarySystemBackground)
    }
}
