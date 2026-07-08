import LocalAgentBridge
import LocalNativeToolkit

enum NativeInteractionResult: Equatable, Sendable {
    case completed
    case cancelledByUser
    case failed
}

protocol NativeInteractionPresenting: Sendable {
    func present(_ record: PendingUserInteractionRecord) async throws -> NativeInteractionResult
}

protocol NativeInteractionBrokering: Sendable {
    func present(_ record: PendingUserInteractionRecord) async throws -> NativeInteractionResult
}

protocol ToolApprovalResponding: Sendable {
    func submitApproval(id: String, decision: ApprovalDecisionDTO) async throws
}

struct ExecutionBridgeToolApprovalResponder: ToolApprovalResponding {
    private let bridge: any ExecutionBridgeClient

    init(bridge: any ExecutionBridgeClient) {
        self.bridge = bridge
    }

    func submitApproval(id: String, decision: ApprovalDecisionDTO) async throws {
        try await bridge.approveTool(id: id, decision: decision)
    }
}

actor NativeInteractionBroker {
    private let store: any PendingUserInteractionStore
    private let presenter: any NativeInteractionPresenting

    init(
        store: any PendingUserInteractionStore,
        presenter: any NativeInteractionPresenting
    ) {
        self.store = store
        self.presenter = presenter
    }

    func present(_ record: PendingUserInteractionRecord) async throws -> NativeInteractionResult {
        try await store.put(record)
        try await store.markState(.presentingSystemUI, id: record.id)

        do {
            let result = try await presenter.present(record)
            switch result {
            case .completed:
                try await store.markState(.completed, id: record.id)
            case .cancelledByUser:
                try await store.markState(.cancelledByUser, id: record.id)
            case .failed:
                try await store.markState(.failed, id: record.id)
            }
            return result
        } catch {
            try await store.markState(.failed, id: record.id)
            throw error
        }
    }
}

extension NativeInteractionBroker: NativeInteractionBrokering {}

struct UnavailableNativeInteractionPresenter: NativeInteractionPresenting {
    func present(_ record: PendingUserInteractionRecord) async throws -> NativeInteractionResult {
        .failed
    }
}

protocol RunInlineCardActionHandling: Sendable {
    func handle(_ card: RunInlineCardState) async -> NativeInteractionResult?
    func handle(_ action: RunInlineCardAction, for card: RunInlineCardState) async -> NativeInteractionResult?
}

actor RunInlineCardActionHandler: RunInlineCardActionHandling {
    private let broker: any NativeInteractionBrokering
    private let approvalResponder: (any ToolApprovalResponding)?
    private(set) var lastErrorMessage: String?

    init(
        broker: any NativeInteractionBrokering,
        approvalResponder: (any ToolApprovalResponding)? = nil
    ) {
        self.broker = broker
        self.approvalResponder = approvalResponder
    }

    func handle(_ card: RunInlineCardState) async -> NativeInteractionResult? {
        guard let action = card.actions.first else {
            return nil
        }
        return await handle(action, for: card)
    }

    func handle(_ action: RunInlineCardAction, for card: RunInlineCardState) async -> NativeInteractionResult? {
        switch (card, action.kind) {
        case (.pendingInteraction, .continuePendingInteraction):
            return await handlePendingInteraction(card)
        case (.toolApproval(let state), .approveTool):
            return await submitApproval(id: state.id, approved: true, reason: nil)
        case (.toolApproval(let state), .denyTool):
            return await submitApproval(id: state.id, approved: false, reason: "Denied by user")
        default:
            return nil
        }
    }

    private func handlePendingInteraction(_ card: RunInlineCardState) async -> NativeInteractionResult? {
        guard case .pendingInteraction(let state) = card,
              let record = state.pendingUserInteractionRecord()
        else {
            return nil
        }

        do {
            let result = try await broker.present(record)
            if result == .failed {
                lastErrorMessage = "Native interaction could not be completed."
            } else {
                lastErrorMessage = nil
            }
            return result
        } catch {
            lastErrorMessage = error.localizedDescription
            return .failed
        }
    }

    private func submitApproval(
        id: String,
        approved: Bool,
        reason: String?
    ) async -> NativeInteractionResult {
        guard let approvalResponder else {
            lastErrorMessage = "Tool approval is not available."
            return .failed
        }

        do {
            try await approvalResponder.submitApproval(
                id: id,
                decision: ApprovalDecisionDTO(approved: approved, reason: reason)
            )
            lastErrorMessage = nil
            return .completed
        } catch {
            lastErrorMessage = error.localizedDescription
            return .failed
        }
    }
}

extension PendingInteractionCardState {
    var isActionable: Bool {
        disabledReason == nil
            && PendingInteractionKind(rawValue: interactionKind) != nil
            && !runId.isEmpty
            && !toolCallId.isEmpty
            && !manifestId.isEmpty
    }

    func pendingUserInteractionRecord() -> PendingUserInteractionRecord? {
        guard let kind = PendingInteractionKind(rawValue: interactionKind),
              !runId.isEmpty,
              !toolCallId.isEmpty,
              !manifestId.isEmpty
        else {
            return nil
        }

        return PendingUserInteractionRecord(
            id: id,
            runId: runId,
            toolCallId: toolCallId,
            manifestId: manifestId,
            interactionKind: kind,
            state: .requested,
            resumablePayloadSummary: title,
            expiresAtMillis: nil
        )
    }
}
