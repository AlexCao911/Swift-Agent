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
}

actor RunInlineCardActionHandler: RunInlineCardActionHandling {
    private let broker: any NativeInteractionBrokering
    private(set) var lastErrorMessage: String?

    init(broker: any NativeInteractionBrokering) {
        self.broker = broker
    }

    func handle(_ card: RunInlineCardState) async -> NativeInteractionResult? {
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
}

extension RunInlineCardState {
    var primaryAction: RunInlineCardPrimaryAction? {
        switch self {
        case .pendingInteraction(let state) where state.isActionable:
            RunInlineCardPrimaryAction(title: "Continue", systemImageName: "arrow.forward.circle")
        default:
            nil
        }
    }
}

extension PendingInteractionCardState {
    var isActionable: Bool {
        PendingInteractionKind(rawValue: interactionKind) != nil
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
