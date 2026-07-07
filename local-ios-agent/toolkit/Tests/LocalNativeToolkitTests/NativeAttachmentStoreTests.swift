import Foundation
import Testing
@testable import LocalNativeToolkit

@Suite("Native attachment and pending interaction stores")
struct NativeAttachmentStoreTests {
    @Test
    func attachmentStoreTracksRepairStates() async throws {
        let store = InMemoryNativeAttachmentStore()
        let record = NativeAttachmentRecord(
            id: "att_1",
            sourceFamily: "files",
            contentType: "text/plain",
            displayName: "notes.txt",
            accessState: .available,
            sizeBytes: 12,
            sensitivity: .private,
            trustLevel: .untrustedExternalContent
        )

        await store.put(record)
        #expect(await store.get("att_1")?.accessState == .available)

        await store.markNeedsUserReselection("att_1")
        #expect(await store.get("att_1")?.accessState == .needsUserReselection)
    }

    @Test
    func pendingInteractionStoreRestoresByRunAndToolCall() async throws {
        let store = InMemoryPendingUserInteractionStore()
        let record = PendingUserInteractionRecord(
            id: "pending_1",
            runId: "run_1",
            toolCallId: "call_1",
            manifestId: "native.photos.pick_images.v1",
            interactionKind: .photosPicker,
            state: .requested,
            resumablePayloadSummary: "Pick images",
            expiresAtMillis: nil
        )

        try await store.put(record)
        let restored = try await store.pending(runId: "run_1", toolCallId: "call_1")

        #expect(restored?.id == "pending_1")
        #expect(restored?.interactionKind == .photosPicker)
    }

    @Test
    func pendingInteractionStoreMarksLifecycleStates() async throws {
        let store = InMemoryPendingUserInteractionStore()
        let record = PendingUserInteractionRecord(
            id: "pending_1",
            runId: "run_1",
            toolCallId: "call_1",
            manifestId: "native.photos.pick_images.v1",
            interactionKind: .photosPicker,
            state: .requested,
            resumablePayloadSummary: "Pick images",
            expiresAtMillis: nil
        )

        try await store.put(record)
        try await store.markState(.presentingSystemUI, id: "pending_1")
        let presenting = try await store.pending(runId: "run_1", toolCallId: "call_1")
        try await store.markState(.completed, id: "pending_1")
        let completed = try await store.pending(runId: "run_1", toolCallId: "call_1")

        #expect(presenting?.state == .presentingSystemUI)
        #expect(completed?.state == .completed)
    }

    @Test
    func fileBackedPendingInteractionStoreSurvivesRecreation() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "pending-interactions-\(UUID().uuidString)")
        let record = PendingUserInteractionRecord(
            id: "pending_1",
            runId: "run_1",
            toolCallId: "call_1",
            manifestId: "native.files.pick_document.v1",
            interactionKind: .filePicker,
            state: .requested,
            resumablePayloadSummary: "Pick a document",
            expiresAtMillis: nil
        )

        let writer = try FileBackedPendingUserInteractionStore(directory: directory)
        try await writer.put(record)
        let reader = try FileBackedPendingUserInteractionStore(directory: directory)
        let restored = try await reader.pending(runId: "run_1", toolCallId: "call_1")

        #expect(restored?.id == "pending_1")
        #expect(restored?.state == .requested)
    }

    @Test
    func presentationGatePersistsBeforePresentingSystemUI() async throws {
        let store = InMemoryPendingUserInteractionStore()
        let record = PendingUserInteractionRecord(
            id: "pending_1",
            runId: "run_1",
            toolCallId: "call_1",
            manifestId: "native.photos.pick_images.v1",
            interactionKind: .photosPicker,
            state: .requested,
            resumablePayloadSummary: "Pick images",
            expiresAtMillis: nil
        )
        var persistedBeforePresentation = false

        try await PendingInteractionPresentationGate.persistBeforePresenting(
            record,
            store: store
        ) {
            let stored = try await store.pending(
                runId: "run_1",
                toolCallId: "call_1"
            )
            persistedBeforePresentation = stored?.state == .presentingSystemUI
        }

        #expect(persistedBeforePresentation)
    }
}
