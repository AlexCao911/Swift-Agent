import Foundation
import LocalAgentBridge
import SwiftUI

enum RunInlineCardState: Equatable, Identifiable, Sendable {
    case toolApproval(ToolApprovalCardState)
    case pendingInteraction(PendingInteractionCardState)
    case permissionRepair(PermissionRepairCardState)
    case modelMissing(ModelMissingCardState)
    case runStatus(RunStatusCardState)

    var id: String {
        switch self {
        case .toolApproval(let state):
            "approval:\(state.id)"
        case .pendingInteraction(let state):
            "pending:\(state.id)"
        case .permissionRepair(let state):
            "permission:\(state.id)"
        case .modelMissing(let state):
            "model:\(state.id)"
        case .runStatus(let state):
            "run:\(state.id)"
        }
    }
}

struct RunInlineCardPrimaryAction: Equatable, Sendable {
    var title: String
    var systemImageName: String
}

struct ToolApprovalCardState: Equatable, Sendable {
    var id: String
    var runId: String
    var title: String
    var toolName: String
}

struct PendingInteractionCardState: Equatable, Sendable {
    var id: String
    var runId: String
    var toolCallId: String
    var manifestId: String
    var interactionKind: String
    var toolName: String
    var title: String
}

struct PermissionRepairCardState: Equatable, Sendable {
    var id: String
    var permissionScope: String
    var title: String
}

struct ModelMissingCardState: Equatable, Sendable {
    var id: String
    var title: String
}

struct RunStatusCardState: Equatable, Sendable {
    var id: String
    var title: String
    var message: String
}

enum RunInlineCardProjection {
    static func project(
        state: AgentViewState,
        approval: ApprovalProtocolRequestDTO? = nil
    ) -> [RunInlineCardState] {
        project(events: state.transientRunEvents, approval: approval)
    }

    static func project(
        events: [RuntimeEventDTO],
        approval: ApprovalProtocolRequestDTO? = nil
    ) -> [RunInlineCardState] {
        if events.contains(where: \.removesTransientRunCards) {
            return []
        }

        if let approval {
            return [
                .toolApproval(ToolApprovalCardState(
                    id: approval.approvalId,
                    runId: approval.runId,
                    title: approval.message,
                    toolName: approval.scope.operationName ?? "tool"
                )),
            ]
        }

        if let pending = events.compactMap(projectPendingInteraction).last {
            return [.pendingInteraction(pending)]
        }

        if let permission = events.compactMap(projectPermissionRepair).last {
            return [.permissionRepair(permission)]
        }

        if let modelMissing = events.compactMap(projectModelMissing).last {
            return [.modelMissing(modelMissing)]
        }

        if let status = events.compactMap(projectRunStatus).last {
            return [.runStatus(status)]
        }

        return []
    }

    private static func projectPendingInteraction(_ event: RuntimeEventDTO) -> PendingInteractionCardState? {
        guard event.kind == .runSuspended,
              let payload = event.jsonPayload,
              payload["type"] as? String == "pending_user_interaction"
        else {
            return nil
        }

        let interactionId = payload["interaction_id"] as? String ?? event.id
        let runId = payload["run_id"] as? String ?? event.runId ?? ""
        let toolCallId = payload["tool_call_id"] as? String ?? ""
        let manifestId = payload["manifest_id"] as? String ?? ""
        let interactionKind = payload["interaction_kind"] as? String ?? ""
        let toolName = payload["tool_name"] as? String ?? "native tool"
        let title = payload["title"] as? String ?? "Continue in Local Agent"
        return PendingInteractionCardState(
            id: interactionId,
            runId: runId,
            toolCallId: toolCallId,
            manifestId: manifestId,
            interactionKind: interactionKind,
            toolName: toolName,
            title: title
        )
    }

    private static func projectPermissionRepair(_ event: RuntimeEventDTO) -> PermissionRepairCardState? {
        guard event.kind == .toolExecutionFailed,
              let payload = event.jsonPayload,
              payload["code"] as? String == "permission_denied",
              let scope = payload["permission_scope"] as? String
        else {
            return nil
        }

        let message = payload["message"] as? String ?? "Permission is required."
        return PermissionRepairCardState(id: scope, permissionScope: scope, title: message)
    }

    private static func projectModelMissing(_ event: RuntimeEventDTO) -> ModelMissingCardState? {
        guard event.kind == .runFailed,
              let payload = event.jsonPayload,
              payload["code"] as? String == "model_missing"
        else {
            return nil
        }

        let message = payload["message"] as? String ?? "Select a model to continue."
        return ModelMissingCardState(id: "model_missing", title: message)
    }

    private static func projectRunStatus(_ event: RuntimeEventDTO) -> RunStatusCardState? {
        guard event.kind == .runWaitingTool else {
            return nil
        }

        return RunStatusCardState(
            id: event.runId ?? event.id,
            title: "Waiting for tool",
            message: event.payload
        )
    }
}

struct RunInlineCardView: View {
    var state: RunInlineCardState
    var onPrimaryAction: ((RunInlineCardState) -> Void)? = nil

    var body: some View {
        switch state {
        case .toolApproval(let state):
            RunInlineCardChrome(
                title: state.title,
                subtitle: state.toolName,
                systemImageName: "checkmark.shield",
                action: primaryAction,
                onAction: primaryActionHandler
            )
        case .pendingInteraction(let state):
            RunInlineCardChrome(
                title: state.title,
                subtitle: state.toolName,
                systemImageName: "hand.tap",
                action: primaryAction,
                onAction: primaryActionHandler
            )
        case .permissionRepair(let state):
            RunInlineCardChrome(
                title: state.title,
                subtitle: state.permissionScope,
                systemImageName: "lock.open",
                action: primaryAction,
                onAction: primaryActionHandler
            )
        case .modelMissing(let state):
            RunInlineCardChrome(
                title: state.title,
                subtitle: "Model setup required",
                systemImageName: "cpu",
                action: primaryAction,
                onAction: primaryActionHandler
            )
        case .runStatus(let state):
            RunInlineCardChrome(
                title: state.title,
                subtitle: state.message,
                systemImageName: "clock",
                action: primaryAction,
                onAction: primaryActionHandler
            )
        }
    }

    private var primaryAction: RunInlineCardPrimaryAction? {
        guard onPrimaryAction != nil else {
            return nil
        }
        return state.primaryAction
    }

    private var primaryActionHandler: (() -> Void)? {
        guard state.primaryAction != nil, let onPrimaryAction else {
            return nil
        }
        return { onPrimaryAction(state) }
    }
}

private struct RunInlineCardChrome: View {
    var title: String
    var subtitle: String
    var systemImageName: String
    var action: RunInlineCardPrimaryAction? = nil
    var onAction: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: systemImageName)
                    .font(.headline)
                    .foregroundStyle(.secondary)
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Spacer(minLength: 8)
            }

            if let action, let onAction {
                Button(action: onAction) {
                    Label(action.title, systemImage: action.systemImageName)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
    }
}

private extension RuntimeEventDTO {
    var jsonPayload: [String: Any]? {
        guard let data = payload.data(using: .utf8) else {
            return nil
        }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    var removesTransientRunCards: Bool {
        kind == .assistantMessageCompleted || kind == .runCancelled
    }
}

private extension ApprovalProtocolScopeDTO {
    var operationName: String? {
        switch self {
        case .operation(let operation):
            operation
        case .egress(let operation, _, _, _):
            operation
        case .unknown:
            nil
        }
    }
}
