import LocalNativeToolkit
import Testing
@testable import LocalAgentApp

@Suite("Native interaction broker")
struct NativeInteractionBrokerTests {
    @Test
    func pendingInteractionCardCreatesBrokerRecord() throws {
        let card = PendingInteractionCardState(
            id: "pending_1",
            runId: "run_1",
            toolCallId: "call_1",
            manifestId: "native.photos.pick_images.v1",
            interactionKind: "photos_picker",
            toolName: "photos.pick_images",
            title: "Choose images"
        )

        let record = try #require(card.pendingUserInteractionRecord())

        #expect(record == PendingUserInteractionRecord(
            id: "pending_1",
            runId: "run_1",
            toolCallId: "call_1",
            manifestId: "native.photos.pick_images.v1",
            interactionKind: .photosPicker,
            state: .requested,
            resumablePayloadSummary: "Choose images",
            expiresAtMillis: nil
        ))
    }

    @Test
    func pendingInteractionCardWithoutManifestDoesNotCreateBrokerRecord() {
        let card = PendingInteractionCardState(
            id: "pending_1",
            runId: "run_1",
            toolCallId: "call_1",
            manifestId: "",
            interactionKind: "photos_picker",
            toolName: "photos.pick_images",
            title: "Choose images"
        )

        #expect(card.pendingUserInteractionRecord() == nil)
    }

    @Test
    func persistsAndMarksPresentingBeforeSystemUI() async throws {
        let store = RecordingPendingInteractionStore()
        let record = pendingRecord()
        let presenter = InspectingInteractionPresenter(store: store)
        let broker = NativeInteractionBroker(store: store, presenter: presenter)

        let result = try await broker.present(record)

        #expect(result == .completed)
        #expect(await presenter.didSeePresentingState == true)
        #expect(await store.states == [.requested, .presentingSystemUI, .completed])
    }

    @Test
    func userCancellationIsPersisted() async throws {
        let store = RecordingPendingInteractionStore()
        let record = pendingRecord()
        let broker = NativeInteractionBroker(
            store: store,
            presenter: StaticInteractionPresenter(result: .cancelledByUser)
        )

        let result = try await broker.present(record)

        #expect(result == .cancelledByUser)
        #expect(await store.states == [.requested, .presentingSystemUI, .cancelledByUser])
    }

    private func pendingRecord() -> PendingUserInteractionRecord {
        PendingUserInteractionRecord(
            id: "pending_1",
            runId: "run_1",
            toolCallId: "call_1",
            manifestId: "native.photos.pick_images.v1",
            interactionKind: .photosPicker,
            state: .requested,
            resumablePayloadSummary: "Pick images",
            expiresAtMillis: nil
        )
    }
}

private actor RecordingPendingInteractionStore: PendingUserInteractionStore {
    private var records: [String: PendingUserInteractionRecord] = [:]
    private(set) var states: [PendingInteractionState] = []

    func put(_ record: PendingUserInteractionRecord) async throws {
        records[record.id] = record
        states.append(record.state)
    }

    func pending(runId: String, toolCallId: String) async throws -> PendingUserInteractionRecord? {
        records.values.first { $0.runId == runId && $0.toolCallId == toolCallId }
    }

    func markState(_ state: PendingInteractionState, id: String) async throws {
        guard var record = records[id] else {
            return
        }
        record.state = state
        records[id] = record
        states.append(state)
    }
}

private actor InspectingInteractionPresenter: NativeInteractionPresenting {
    private let store: RecordingPendingInteractionStore
    private(set) var didSeePresentingState = false

    init(store: RecordingPendingInteractionStore) {
        self.store = store
    }

    func present(_ record: PendingUserInteractionRecord) async throws -> NativeInteractionResult {
        let persisted = try await store.pending(runId: record.runId, toolCallId: record.toolCallId)
        didSeePresentingState = persisted?.state == .presentingSystemUI
        return .completed
    }
}

private struct StaticInteractionPresenter: NativeInteractionPresenting {
    var result: NativeInteractionResult

    func present(_ record: PendingUserInteractionRecord) async throws -> NativeInteractionResult {
        result
    }
}
