import Foundation
import LocalAgentBridge
import Testing
@testable import LocalAgentApp

@Suite("Run inline cards")
@MainActor
struct RunInlineCardsTests {
    @Test("run suspended with approval projects to tool approval")
    func runSuspendedWithApprovalProjectsToToolApproval() {
        let cards = RunInlineCardProjection.project(
            events: [event(kind: .runSuspended, payload: #"{"reason":"approval_required"}"#)],
            approval: ApprovalProtocolRequestDTO(
                approvalId: "approval_1",
                runId: "run_1",
                toolCallEntryId: "tool_call_1",
                message: "Allow Calendar search?",
                requiresLocalAuthentication: false,
                scope: .operation(operation: "calendar.search_events")
            )
        )

        #expect(cards == [
            .toolApproval(ToolApprovalCardState(
                id: "approval_1",
                runId: "run_1",
                title: "Allow Calendar search?",
                toolName: "calendar.search_events"
            )),
        ])
    }

    @Test("pending user interaction projects to pending interaction")
    func pendingUserInteractionProjectsToPendingInteraction() {
        let cards = RunInlineCardProjection.project(events: [
            event(
                kind: .runSuspended,
                payload: #"{"type":"pending_user_interaction","interaction_id":"pending_1","tool_name":"photos.pick_images","tool_call_id":"call_1","manifest_id":"native.photos.pick_images.v1","interaction_kind":"photos_picker","title":"Choose photos"}"#
            ),
        ])

        #expect(cards == [
            .pendingInteraction(PendingInteractionCardState(
                id: "pending_1",
                runId: "run_1",
                toolCallId: "call_1",
                manifestId: "native.photos.pick_images.v1",
                interactionKind: "photos_picker",
                toolName: "photos.pick_images",
                title: "Choose photos"
            )),
        ])
    }

    @Test("pending interaction card exposes continue action")
    func pendingInteractionCardExposesContinueAction() throws {
        let card = try #require(RunInlineCardProjection.project(events: [
            event(
                kind: .runSuspended,
                payload: #"{"type":"pending_user_interaction","interaction_id":"pending_1","tool_name":"photos.pick_images","tool_call_id":"call_1","manifest_id":"native.photos.pick_images.v1","interaction_kind":"photos_picker","title":"Choose photos"}"#
            ),
        ]).first)

        #expect(card.primaryAction == RunInlineCardPrimaryAction(
            title: "Continue",
            systemImageName: "arrow.forward.circle"
        ))
    }

    @Test("pending interaction without manifest is not actionable")
    func pendingInteractionWithoutManifestIsNotActionable() throws {
        let card = try #require(RunInlineCardProjection.project(events: [
            event(
                kind: .runSuspended,
                payload: #"{"type":"pending_user_interaction","interaction_id":"pending_1","tool_name":"photos.pick_images","tool_call_id":"call_1","interaction_kind":"photos_picker","title":"Choose photos"}"#
            ),
        ]).first)

        #expect(card.primaryAction == nil)
    }

    @Test("pending interaction without tool call id is not actionable")
    func pendingInteractionWithoutToolCallIdIsNotActionable() throws {
        let card = try #require(RunInlineCardProjection.project(events: [
            event(
                kind: .runSuspended,
                payload: #"{"type":"pending_user_interaction","interaction_id":"pending_1","tool_name":"photos.pick_images","manifest_id":"native.photos.pick_images.v1","interaction_kind":"photos_picker","title":"Choose photos"}"#
            ),
        ]).first)

        #expect(card.primaryAction == nil)
    }

    @Test("denied permission projects to repair card")
    func deniedPermissionProjectsToRepairCard() {
        let cards = RunInlineCardProjection.project(events: [
            event(
                kind: .toolExecutionFailed,
                payload: #"{"code":"permission_denied","permission_scope":"calendar.events.read_full","message":"Calendar access is off"}"#
            ),
        ])

        #expect(cards == [
            .permissionRepair(PermissionRepairCardState(
                id: "calendar.events.read_full",
                permissionScope: "calendar.events.read_full",
                title: "Calendar access is off"
            )),
        ])
    }

    @Test("missing model projects to model card")
    func missingModelProjectsToModelCard() {
        let cards = RunInlineCardProjection.project(events: [
            event(
                kind: .runFailed,
                payload: #"{"code":"model_missing","message":"Select a model"}"#
            ),
        ])

        #expect(cards == [
            .modelMissing(ModelMissingCardState(
                id: "model_missing",
                title: "Select a model"
            )),
        ])
    }

    @Test("completed run removes transient cards")
    func completedRunRemovesTransientCards() {
        let cards = RunInlineCardProjection.project(events: [
            event(kind: .runSuspended, payload: #"{"reason":"approval_required"}"#),
            event(kind: .assistantMessageCompleted, payload: "Done"),
        ])

        #expect(cards.isEmpty)
    }
}

private func event(
    kind: RuntimeEventKindDTO,
    payload: String,
    id: String = UUID().uuidString
) -> RuntimeEventDTO {
    RuntimeEventDTO(
        id: id,
        sessionId: "session_1",
        parentId: nil,
        runId: "run_1",
        sequence: 1,
        depth: 0,
        kind: kind,
        payload: payload,
        blobRefs: []
    )
}
