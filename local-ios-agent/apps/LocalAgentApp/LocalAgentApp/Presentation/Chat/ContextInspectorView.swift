import LocalAgentBridge
import LocalNativeToolkit
import SwiftUI

struct ContextInspectorSnapshot: Equatable, Sendable {
    var segments: [ContextInspectorSegment]
    var warnings: [String]
    var isPreviewOnly: Bool

    var label: String {
        isPreviewOnly ? "Preview only" : "Runtime trace"
    }
}

struct ContextInspectorSegment: Equatable, Sendable, Identifiable {
    var id: String
    var title: String
    var sourceKind: String
    var trustLevel: NativeToolTrustLevel
    var tokenEstimate: Int?
    var previewText: String
    var warning: String?
}

enum ContextInspectorProjection {
    static func project(
        messages: [AgentMessageViewState] = [],
        toolResults: [ToolResultDTO] = [],
        runtimeEvents: [RuntimeEventDTO] = [],
        isPreviewOnly: Bool = false
    ) -> ContextInspectorSnapshot {
        let messageSegments = messages.compactMap(projectMessage)
        let eventToolResults = runtimeEvents.compactMap(projectToolResultEvent)
        let toolSegments = (toolResults + eventToolResults).enumerated().map {
            projectToolResult(offset: $0.offset, result: $0.element)
        }
        let segments = messageSegments + toolSegments
        let warnings = uniqueWarnings(from: segments)

        return ContextInspectorSnapshot(
            segments: segments,
            warnings: warnings,
            isPreviewOnly: isPreviewOnly
        )
    }

    private static func projectMessage(_ message: AgentMessageViewState) -> ContextInspectorSegment? {
        guard message.role == .user else {
            return nil
        }

        return ContextInspectorSegment(
            id: "message:\(message.id)",
            title: "User message",
            sourceKind: "conversation",
            trustLevel: .userInstruction,
            tokenEstimate: nil,
            previewText: message.text,
            warning: nil
        )
    }

    private static func projectToolResult(
        offset: Int,
        result: ToolResultDTO
    ) -> ContextInspectorSegment {
        guard let envelope = decodeEnvelope(result.structuredJson) else {
            let warning = "Source metadata is missing; treat this context as partially trusted."
            return ContextInspectorSegment(
                id: "tool:legacy:\(offset)",
                title: "Tool result",
                sourceKind: "unknown",
                trustLevel: .trustedToolResult,
                tokenEstimate: estimateTokens(in: result.modelText),
                previewText: result.modelText,
                warning: warning
            )
        }

        let trustLevel = envelope.contextPolicy.trustLevel
        return ContextInspectorSegment(
            id: "tool:\(envelope.toolCallId)",
            title: envelope.contextPolicy.sourceLabel,
            sourceKind: envelope.provenance.sourceKind,
            trustLevel: trustLevel,
            tokenEstimate: estimateTokens(in: result.modelText),
            previewText: result.modelText,
            warning: warning(for: trustLevel)
        )
    }

    private static func projectToolResultEvent(_ event: RuntimeEventDTO) -> ToolResultDTO? {
        guard event.kind == .toolResultMessage,
              let data = event.payload.data(using: .utf8)
        else {
            return nil
        }
        return try? JSONDecoder().decode(ToolResultDTO.self, from: data)
    }

    private static func decodeEnvelope(_ structuredJson: String) -> ToolResultEnvelopeV1? {
        guard let data = structuredJson.data(using: .utf8) else {
            return nil
        }
        return try? JSONDecoder().decode(ToolResultEnvelopeV1.self, from: data)
    }

    private static func warning(for trustLevel: NativeToolTrustLevel) -> String? {
        switch trustLevel {
        case .untrustedExternalContent:
            "External content can contain instructions the model should not follow."
        case .trustedAppPolicy, .userInstruction, .trustedToolResult:
            nil
        }
    }

    private static func uniqueWarnings(from segments: [ContextInspectorSegment]) -> [String] {
        var seen: Set<String> = []
        return segments.compactMap(\.warning).filter { warning in
            seen.insert(warning).inserted
        }
    }

    private static func estimateTokens(in text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }
        let roughWordCount = trimmed.split(whereSeparator: \.isWhitespace).count
        return max(1, Int(Double(roughWordCount) * 1.35))
    }
}

struct ContextInspectorView: View {
    var snapshot: ContextInspectorSnapshot

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label(snapshot.label, systemImage: snapshot.isPreviewOnly ? "eye" : "timeline.selection")
                        .font(.headline)
                    Text("Read-only view of context sources, trust labels, and model-visible excerpts.")
                        .foregroundStyle(.secondary)
                }

                if !snapshot.warnings.isEmpty {
                    Section("Warnings") {
                        ForEach(snapshot.warnings, id: \.self) { warning in
                            Label(warning, systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.orange)
                        }
                    }
                }

                Section("Context") {
                    if snapshot.segments.isEmpty {
                        ContentUnavailableView(
                            "No Context Trace",
                            systemImage: "doc.text.magnifyingglass",
                            description: Text("Send a message or open a preview to inspect context sources.")
                        )
                    } else {
                        ForEach(snapshot.segments) { segment in
                            ContextInspectorSegmentRow(segment: segment)
                        }
                    }
                }
            }
            .navigationTitle("Context")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

private struct ContextInspectorSegmentRow: View {
    var segment: ContextInspectorSegment

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(segment.title)
                    .font(.headline)
                Spacer(minLength: 8)
                Text(segment.trustLevel.rawValue)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color(.secondarySystemBackground), in: Capsule())
            }

            HStack(spacing: 8) {
                Label(segment.sourceKind, systemImage: "tag")
                if let tokenEstimate = segment.tokenEstimate {
                    Label("\(tokenEstimate) tokens", systemImage: "number")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            Text(segment.previewText)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(4)

            if let warning = segment.warning {
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}
