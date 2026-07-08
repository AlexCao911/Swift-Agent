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

struct RunInlineCardAction: Equatable, Identifiable, Sendable {
    enum Kind: String, Equatable, Sendable {
        case approveTool
        case denyTool
        case continuePendingInteraction
    }

    var kind: Kind
    var title: String
    var systemImageName: String
    var isDestructive: Bool

    var id: String { kind.rawValue }

    static let approveTool = RunInlineCardAction(
        kind: .approveTool,
        title: "Approve",
        systemImageName: "checkmark.circle",
        isDestructive: false
    )

    static let denyTool = RunInlineCardAction(
        kind: .denyTool,
        title: "Deny",
        systemImageName: "xmark.circle",
        isDestructive: true
    )

    static let continuePendingInteraction = RunInlineCardAction(
        kind: .continuePendingInteraction,
        title: "Continue",
        systemImageName: "arrow.forward.circle",
        isDestructive: false
    )
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
    var disabledReason: String? = nil
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

extension RunInlineCardState {
    var actions: [RunInlineCardAction] {
        switch self {
        case .toolApproval:
            [.approveTool, .denyTool]
        case .pendingInteraction(let state) where state.isActionable:
            [.continuePendingInteraction]
        default:
            []
        }
    }

    var primaryAction: RunInlineCardPrimaryAction? {
        guard let action = actions.first else {
            return nil
        }
        return RunInlineCardPrimaryAction(
            title: action.title,
            systemImageName: action.systemImageName
        )
    }

    var disabledReason: String? {
        switch self {
        case .pendingInteraction(let state) where !state.isActionable:
            state.disabledReason ?? "This interaction is missing runtime details."
        case .permissionRepair:
            "Repair this permission in Tools or Settings."
        case .modelMissing:
            "Select a model in Models before continuing."
        default:
            nil
        }
    }
}

enum RunInlineCardProjection {
    static func project(
        state: AgentViewState,
        approval: ApprovalProtocolRequestDTO? = nil
    ) -> [RunInlineCardState] {
        project(events: state.transientRunEvents, approval: approval ?? state.pendingApprovalRequest)
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
        let disabledReason = payload["disabled_reason"] as? String
        return PendingInteractionCardState(
            id: interactionId,
            runId: runId,
            toolCallId: toolCallId,
            manifestId: manifestId,
            interactionKind: interactionKind,
            toolName: toolName,
            title: title,
            disabledReason: disabledReason
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

enum RunInlineCardActionStateReducer {
    static func apply(
        _ result: NativeInteractionResult?,
        action: RunInlineCardAction,
        card: RunInlineCardState,
        to state: inout AgentViewState
    ) {
        switch (result, card, action.kind) {
        case (.completed, .toolApproval(let approval), .approveTool),
             (.completed, .toolApproval(let approval), .denyTool):
            guard state.pendingApprovalRequest?.approvalId == approval.id else {
                return
            }
            state.pendingApprovalRequest = nil
        case (.completed, .pendingInteraction(let pending), .continuePendingInteraction):
            state.transientRunEvents.removeAll { $0.id == pending.id }
        case (.failed, .pendingInteraction(let pending), .continuePendingInteraction):
            markPendingInteraction(
                pending.id,
                disabledReason: "Native interaction could not be completed.",
                in: &state
            )
        default:
            return
        }
    }

    private static func markPendingInteraction(
        _ id: String,
        disabledReason: String,
        in state: inout AgentViewState
    ) {
        guard let index = state.transientRunEvents.firstIndex(where: { event in
            event.id == id || event.jsonPayload?["interaction_id"] as? String == id
        }),
              var payload = state.transientRunEvents[index].jsonPayload
        else {
            return
        }

        payload["disabled_reason"] = disabledReason
        guard let json = jsonString(payload) else {
            return
        }
        state.transientRunEvents[index].payload = json
    }

    private static func jsonString(_ object: [String: Any]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }
}

struct RunInlineCardView: View {
    var state: RunInlineCardState
    var onAction: ((RunInlineCardState, RunInlineCardAction) -> Void)? = nil

    var body: some View {
        switch state {
        case .toolApproval(let state):
            RunInlineCardChrome(
                title: state.title,
                subtitle: state.toolName,
                systemImageName: "checkmark.shield",
                actions: actions,
                disabledReason: disabledReason,
                onAction: actionHandler
            )
        case .pendingInteraction(let state):
            RunInlineCardChrome(
                title: state.title,
                subtitle: state.toolName,
                systemImageName: "hand.tap",
                actions: actions,
                disabledReason: disabledReason,
                onAction: actionHandler
            )
        case .permissionRepair(let state):
            RunInlineCardChrome(
                title: state.title,
                subtitle: state.permissionScope,
                systemImageName: "lock.open",
                actions: actions,
                disabledReason: disabledReason,
                onAction: actionHandler
            )
        case .modelMissing(let state):
            RunInlineCardChrome(
                title: state.title,
                subtitle: "Model setup required",
                systemImageName: "cpu",
                actions: actions,
                disabledReason: disabledReason,
                onAction: actionHandler
            )
        case .runStatus(let state):
            RunInlineCardChrome(
                title: state.title,
                subtitle: state.message,
                systemImageName: "clock",
                actions: actions,
                disabledReason: disabledReason,
                onAction: actionHandler
            )
        }
    }

    private var actions: [RunInlineCardAction] {
        guard onAction != nil else {
            return []
        }
        return state.actions
    }

    private var disabledReason: String? {
        guard actions.isEmpty else {
            return nil
        }
        return state.disabledReason
    }

    private var actionHandler: ((RunInlineCardAction) -> Void)? {
        guard let onAction else {
            return nil
        }
        return { action in onAction(state, action) }
    }
}

private struct RunInlineCardChrome: View {
    var title: String
    var subtitle: String
    var systemImageName: String
    var actions: [RunInlineCardAction] = []
    var disabledReason: String? = nil
    var onAction: ((RunInlineCardAction) -> Void)? = nil

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

            if let onAction, !actions.isEmpty {
                HStack(spacing: 8) {
                    ForEach(actions) { action in
                        Button(role: action.isDestructive ? .destructive : nil) {
                            onAction(action)
                        } label: {
                            Label(action.title, systemImage: action.systemImageName)
                        }
                        .buttonStyle(.bordered)
                        .tint(action.isDestructive ? .red : .accentColor)
                        .controlSize(.small)
                    }
                }
            } else if let disabledReason {
                Label(disabledReason, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
