import LocalNativeToolkit

enum NativeInteractionResult: Equatable, Sendable {
    case completed
    case cancelledByUser
    case failed
}

protocol NativeInteractionPresenting: Sendable {
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
