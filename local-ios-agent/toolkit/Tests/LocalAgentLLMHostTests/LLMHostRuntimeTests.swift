import Foundation
import LocalAgentBridge
import LocalAgentLLMContracts
import Testing
@testable import LocalAgentLLMHost

@Suite("LLM host runtime")
struct LLMHostRuntimeTests {
    @Test
    func generatedSessionHandlesContain256RandomBits() throws {
        var handles = Set<String>()

        for _ in 0..<64 {
            let handle = try HostSessionHandleGenerator.generate()
            #expect(handles.insert(handle).inserted)
            let base64 = handle
                .replacingOccurrences(of: "-", with: "+")
                .replacingOccurrences(of: "_", with: "/")
                .paddingToBase64MultipleOfFour()
            #expect(Data(base64Encoded: base64)?.count == 32)
        }
    }

    @Test
    func boundedInboxRejectsTheSixtyFifthCommandWithoutDroppingFIFOData() {
        let inbox = BoundedHostCommandInbox()

        for value in 0..<64 {
            #expect(inbox.copyAndEnqueue(Data([UInt8(value)])) == .copied)
        }
        #expect(inbox.copyAndEnqueue(Data([255])) == .backpressure)
        for value in 0..<64 {
            #expect(inbox.pop() == Data([UInt8(value)]))
        }
        #expect(inbox.pop() == nil)
        #expect(inbox.copyAndEnqueue(Data([255])) == .copied)
    }

    @Test
    func duplicateCommandReturnsExistingAcknowledgementWithoutStartingTwice() async throws {
        let harness = try await HostRuntimeHarness.make(lifecycle: .committed)
        let command = try harness.command(id: "a", sequence: 1)

        #expect(harness.runtime.copy(try dispatch(command)) == .copied)
        #expect(harness.runtime.copy(try dispatch(command)) == .copied)
        await harness.runtime.drain()

        #expect(await harness.driver.startCount() == 1)
        #expect(await harness.sink.acknowledgedCommandIDs() == ["a", "a"])
        #expect(await harness.sink.lastRejectionCode() == nil)
    }

    @Test
    func reusedSequenceWithDifferentIdentityRejectsWithoutBackendCall() async throws {
        let harness = try await HostRuntimeHarness.make(lifecycle: .committed)
        let start = try harness.command(id: "a", sequence: 1)
        let conflict = try harness.command(id: "b", sequence: 1, kind: .cancelGeneration)

        #expect(harness.runtime.copy(try dispatch(start)) == .copied)
        #expect(harness.runtime.copy(try dispatch(conflict)) == .copied)
        await harness.runtime.drain()

        #expect(await harness.driver.startCount() == 1)
        #expect(await harness.driver.cancelCount() == 0)
        #expect(await harness.sink.lastRejectionCode() == "llm.command.sequence_conflict")
    }

    @Test
    func sequenceGapRejectsWithoutBackendCall() async throws {
        let harness = try await HostRuntimeHarness.make(lifecycle: .committed)
        let gap = try harness.command(id: "gap", sequence: 2)

        #expect(harness.runtime.copy(try dispatch(gap)) == .copied)
        await harness.runtime.drain()

        #expect(await harness.driver.startCount() == 0)
        #expect(await harness.sink.lastRejectionCode() == "llm.command.sequence_gap")
    }

    @Test
    func wrongEpochAndWrongRunAreRejectedWithoutConsumingTheLedger() async throws {
        let wrongEpoch = try await HostRuntimeHarness.make(lifecycle: .committed)
        let epochCommand = try wrongEpoch.command(
            id: "wrong-epoch",
            sequence: 1,
            epoch: try HostProcessEpoch.generate().rawValue
        )
        #expect(wrongEpoch.runtime.copy(try dispatch(epochCommand)) == .copied)
        await wrongEpoch.runtime.drain()
        #expect(await wrongEpoch.driver.startCount() == 0)
        #expect(await wrongEpoch.sink.lastRejectionCode() == "llm.command.wrong_epoch")

        let wrongRun = try await HostRuntimeHarness.make(lifecycle: .committed)
        let runCommand = try wrongRun.command(id: "wrong-run", sequence: 1, runID: "other-run")
        #expect(wrongRun.runtime.copy(try dispatch(runCommand)) == .copied)
        await wrongRun.runtime.drain()
        #expect(await wrongRun.driver.startCount() == 0)
        #expect(await wrongRun.sink.lastRejectionCode() == "llm.command.wrong_run")

        let valid = try wrongRun.command(id: "valid", sequence: 1)
        #expect(wrongRun.runtime.copy(try dispatch(valid)) == .copied)
        await wrongRun.runtime.drain()
        #expect(await wrongRun.driver.startCount() == 1)
    }

    @Test
    func cleanupDuringOpeningClosesTheOwnerWithoutInstallingADriver() async throws {
        let harness = try await HostRuntimeHarness.make(lifecycle: .opening, installDriver: false)
        let counter = CloseCounter()
        await harness.cleanupOwner.register(id: "first-open-resource") {
            await counter.increment()
        }

        #expect(harness.runtime.copy(try cleanupDispatch(harness: harness)) == .copied)
        await harness.runtime.drain()

        #expect(await counter.value() == 1)
        #expect(await harness.runtime.bridgeActor.hasInstalledDriver(for: harness.handle) == false)
        #expect(await harness.runtime.bridgeActor.lifecycle(for: harness.handle) == .closed)
        #expect(await harness.sink.closedDisposition() == .closed)
    }

    @Test
    func committedStartMayArriveWhileCommitFFIIsReturning() async throws {
        let harness = try await HostRuntimeHarness.make(lifecycle: .commitInFlight)
        let command = try harness.command(id: "committed-start", sequence: 1)

        #expect(harness.runtime.copy(try dispatch(command)) == .copied)
        await harness.runtime.drain()

        #expect(await harness.runtime.bridgeActor.lifecycle(for: harness.handle) == .committed)
        await waitUntil { await harness.driver.startCount() == 1 }
        #expect(await harness.driver.startCount() == 1)
    }

    @Test
    func v2GenerationStartsOnceAndOnlyAfterRustAcknowledgesTheCommand() async throws {
        let executor = RecordingV2ModelExecutor()
        let harness = try await HostRuntimeHarness.make(
            lifecycle: .committed,
            modelExecutor: executor
        )
        let command = try harness.v2GenerationCommand(id: "v2", sequence: 1)

        #expect(harness.runtime.copy(try dispatch(command)) == .copied)
        await harness.runtime.drain()
        await waitUntil { await harness.sink.eventKinds().contains(.generationCompleted) }

        #expect(await executor.requestCount() == 1)
        #expect(await harness.sink.operations().first == "ack:v2")
        #expect(await harness.sink.operations().dropFirst().first == "event:generation_started")

        #expect(harness.runtime.copy(try dispatch(command)) == .copied)
        await harness.runtime.drain()
        #expect(await executor.requestCount() == 1)
    }

    @Test
    func rustOwnedV2StartAdoptsItsRunScopedSessionWithoutV1Preparation() async throws {
        let fixture = try await HostRuntimeHarness.make(lifecycle: .committed)
        let command = try fixture.v2GenerationCommand(id: "rust-react", sequence: 1)
        let executor = RecordingV2ModelExecutor()
        let sink = RecordingRustSink(acceptsCleanupAcknowledgement: true)
        let runtime = LLMHostRuntime(
            hostProcessEpoch: HostRuntimeHarness.epoch,
            rustSink: sink,
            modelExecutor: executor
        )

        #expect(runtime.copy(try dispatch(command)) == .copied)
        await runtime.drain()
        await waitUntil { await sink.eventKinds().contains(.generationCompleted) }

        #expect(await executor.requestCount() == 1)
        #expect(await sink.lastRejectionCode() == nil)
        #expect(await runtime.bridgeActor.lifecycle(for: command.sessionHandle) == .committed)
    }

    @Test
    func v2CloseSessionFinishesRunOwnedModelResources() async throws {
        let executor = RecordingV2ModelExecutor()
        let harness = try await HostRuntimeHarness.make(
            lifecycle: .committed,
            modelExecutor: executor
        )
        let start = try harness.v2GenerationCommand(id: "start", sequence: 1)
        let close = try harness.v2LifecycleCommand(
            id: "close",
            sequence: 2,
            kind: .closeSession
        )

        #expect(harness.runtime.copy(try dispatch(start)) == .copied)
        await harness.runtime.drain()
        await waitUntil { await harness.sink.eventKinds().contains(.generationCompleted) }
        #expect(harness.runtime.copy(try dispatch(close)) == .copied)
        await harness.runtime.drain()
        await waitUntil { await executor.finishedRuns() == ["run-1"] }
        await waitUntil { await harness.sink.eventKinds().contains(.sessionClosed) }

        #expect(await executor.finishedRuns() == ["run-1"])
        #expect(await harness.sink.eventKinds().contains(.sessionClosed))
    }

    @Test
    func rejectedCleanupAcknowledgementQuarantinesTheSession() async throws {
        let harness = try await HostRuntimeHarness.make(
            lifecycle: .registrationInFlight,
            installDriver: false,
            acceptsCleanupAcknowledgement: false
        )

        #expect(harness.runtime.copy(try cleanupDispatch(harness: harness)) == .copied)
        await harness.runtime.drain()

        #expect(await harness.runtime.bridgeActor.lifecycle(for: harness.handle) == .quarantined)
        #expect(await harness.sink.confirmedCloseCount() == 0)
    }

    @Test
    func closedHandlesBecomeTombstonesAndCannotBeReallocated() async throws {
        let harness = try await HostRuntimeHarness.make(lifecycle: .committed)
        try await harness.runtime.bridgeActor.beginClosing(harness.handle)
        try await harness.runtime.bridgeActor.recordSessionClosed(harness.handle)

        do {
            try await harness.runtime.bridgeActor.allocate(harness.allocatedSession())
            Issue.record("expected an ABA allocation failure")
        } catch let error as LLMHostRuntimeError {
            #expect(error.code == "llm.host.session_handle_reused")
        }

        let late = try harness.command(id: "late", sequence: 1)
        #expect(harness.runtime.copy(try dispatch(late)) == .copied)
        await harness.runtime.drain()
        #expect(await harness.sink.lastRejectionCode() == "llm.command.closed_session")
        #expect(await harness.driver.startCount() == 0)
    }

    @Test
    func cleanupOwnerReturnsOneClosedThenAlreadyClosedDisposition() async {
        let owner = PreparedSessionCleanupOwner()
        let counter = CloseCounter()
        await owner.register(id: "resource") {
            await counter.increment()
        }

        async let first = owner.close()
        async let second = owner.close()
        let dispositions = await [first, second]

        #expect(Set(dispositions) == Set([.closed, .alreadyClosed]))
        #expect(await counter.value() == 1)
        #expect(await owner.close() == .alreadyClosed)
    }
}

private func waitUntil(_ predicate: @escaping @Sendable () async -> Bool) async {
    for _ in 0..<100 where !(await predicate()) {
        try? await Task.sleep(for: .milliseconds(1))
    }
}

private struct HostRuntimeHarness {
    static let epoch = HostProcessEpoch(
        rawValue: "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
    )!

    let runtime: LLMHostRuntime
    let sink: RecordingRustSink
    let driver: RecordingDriver
    let cleanupOwner: PreparedSessionCleanupOwner
    let handle = "session-1"
    let runID = "run-1"
    let preparationID = "preparation-1"
    let registrationDigest = String(repeating: "b", count: 64)
    let fixture: HostCommandEnvelope

    static func make(
        lifecycle: HostSessionLifecycle,
        installDriver: Bool = true,
        acceptsCleanupAcknowledgement: Bool = true,
        modelExecutor: (any ModelGenerationExecuting)? = nil
    ) async throws -> HostRuntimeHarness {
        let sink = RecordingRustSink(
            acceptsCleanupAcknowledgement: acceptsCleanupAcknowledgement
        )
        let runtime = LLMHostRuntime(
            hostProcessEpoch: epoch,
            rustSink: sink,
            modelExecutor: modelExecutor
        )
        let harness = try HostRuntimeHarness(
            runtime: runtime,
            sink: sink,
            driver: RecordingDriver(),
            cleanupOwner: PreparedSessionCleanupOwner(),
            fixture: loadCommandFixture()
        )
        try await runtime.bridgeActor.allocate(harness.allocatedSession())
        try await harness.advance(to: lifecycle, installDriver: installDriver)
        return harness
    }

    func allocatedSession() -> AllocatedHostSession {
        AllocatedHostSession(
            sessionHandle: handle,
            preparationID: preparationID,
            proposedRunID: runID,
            swiftSnapshotID: "snapshot-1",
            bindingHash: String(repeating: "a", count: 64),
            hostProcessEpoch: Self.epoch,
            preparedSessionRegistrationDigest: registrationDigest,
            cleanupOwner: cleanupOwner
        )
    }

    func advance(to lifecycle: HostSessionLifecycle, installDriver: Bool) async throws {
        guard lifecycle != .allocated else { return }
        try await runtime.bridgeActor.beginRegistration(handle)
        guard lifecycle != .registrationInFlight else { return }
        try await runtime.bridgeActor.markRegistered(handle)
        guard lifecycle != .registeredNotOpen else { return }
        try await runtime.bridgeActor.beginOpen(handle)
        guard lifecycle != .opening else { return }
        if installDriver {
            try await runtime.bridgeActor.installOpenedDriver(driver, for: handle)
        } else {
            try await runtime.bridgeActor.markOpenedAwaitingCommit(handle)
        }
        guard lifecycle != .openedAwaitingCommit else { return }
        try await runtime.bridgeActor.beginCommit(handle)
        guard lifecycle != .commitInFlight else { return }
        if lifecycle == .commitOutcomeUnknown {
            try await runtime.bridgeActor.markCommitOutcomeUnknown(handle)
        } else if lifecycle == .committed {
            try await runtime.bridgeActor.markCommitted(handle)
        }
    }

    func command(
        id: String,
        sequence: UInt64,
        kind: HostCommandKind = .startGeneration,
        epoch: String = HostRuntimeHarness.epoch.rawValue,
        runID: String? = nil
    ) throws -> HostCommandEnvelope {
        let draft = HostCommandEnvelope(
            schemaVersion: 1,
            commandID: id,
            runID: runID ?? self.runID,
            sessionHandle: handle,
            hostProcessEpoch: epoch,
            commandSequence: sequence,
            generationTurnID: fixture.generationTurnID,
            kind: kind,
            payloadDigest: fixture.payloadDigest,
            disclosureDigest: fixture.disclosureDigest,
            commandEnvelopeDigest: "",
            disclosure: fixture.disclosure,
            payload: fixture.payload
        )
        return HostCommandEnvelope(
            schemaVersion: draft.schemaVersion,
            commandID: draft.commandID,
            runID: draft.runID,
            sessionHandle: draft.sessionHandle,
            hostProcessEpoch: draft.hostProcessEpoch,
            commandSequence: draft.commandSequence,
            generationTurnID: draft.generationTurnID,
            kind: draft.kind,
            payloadDigest: draft.payloadDigest,
            disclosureDigest: draft.disclosureDigest,
            commandEnvelopeDigest: try draft.recomputedDigest().hex,
            disclosure: draft.disclosure,
            payload: draft.payload
        )
    }

    func v2GenerationCommand(
        id: String,
        sequence: UInt64
    ) throws -> HostCommandEnvelope {
        let payload = HostCommandPayload.generationV2(HostModelRequest(
            runID: runID,
            conversationStreamID: "conversation-1",
            systemPrompt: "system",
            orderedMessages: [],
            attachmentReferences: [],
            orderedToolDefinitions: []
        ))
        let payloadDigest = try payload.computedDigest().hex
        let disclosure = GenerationDisclosure(
            schemaVersion: "1",
            generationTurnID: "turn-v2",
            contentDigest: payloadDigest,
            sourceRevisionDigest: String(repeating: "0", count: 64),
            dataClasses: [.text],
            highestSensitivity: .private,
            safeDisplaySummary: SafeDisplaySummary(
                sourceKinds: [.conversation],
                addedItemCounts: [.init(dataClass: .text, count: 1)],
                approximateAddedSize: .lessThanOneKiB,
                triggeringToolDisplayKeys: []
            )
        )
        let draft = HostCommandEnvelope(
            schemaVersion: 2,
            commandID: id,
            runID: runID,
            sessionHandle: handle,
            hostProcessEpoch: Self.epoch.rawValue,
            commandSequence: sequence,
            generationTurnID: disclosure.generationTurnID,
            kind: .startGeneration,
            payloadDigest: payloadDigest,
            disclosureDigest: try disclosure.computedDigest().hex,
            commandEnvelopeDigest: "",
            disclosure: disclosure,
            payload: payload
        )
        return HostCommandEnvelope(
            schemaVersion: draft.schemaVersion,
            commandID: draft.commandID,
            runID: draft.runID,
            sessionHandle: draft.sessionHandle,
            hostProcessEpoch: draft.hostProcessEpoch,
            commandSequence: draft.commandSequence,
            generationTurnID: draft.generationTurnID,
            kind: draft.kind,
            payloadDigest: draft.payloadDigest,
            disclosureDigest: draft.disclosureDigest,
            commandEnvelopeDigest: try draft.recomputedDigest().hex,
            disclosure: draft.disclosure,
            payload: draft.payload
        )
    }

    func v2LifecycleCommand(
        id: String,
        sequence: UInt64,
        kind: HostCommandKind
    ) throws -> HostCommandEnvelope {
        let payload = HostCommandPayload.lifecycleV2()
        let payloadDigest = try payload.computedDigest().hex
        let draft = HostCommandEnvelope(
            schemaVersion: 2,
            commandID: id,
            runID: runID,
            sessionHandle: handle,
            hostProcessEpoch: Self.epoch.rawValue,
            commandSequence: sequence,
            generationTurnID: nil,
            kind: kind,
            payloadDigest: payloadDigest,
            disclosureDigest: nil,
            commandEnvelopeDigest: "",
            disclosure: nil,
            payload: payload
        )
        return HostCommandEnvelope(
            schemaVersion: draft.schemaVersion,
            commandID: draft.commandID,
            runID: draft.runID,
            sessionHandle: draft.sessionHandle,
            hostProcessEpoch: draft.hostProcessEpoch,
            commandSequence: draft.commandSequence,
            generationTurnID: draft.generationTurnID,
            kind: draft.kind,
            payloadDigest: draft.payloadDigest,
            disclosureDigest: draft.disclosureDigest,
            commandEnvelopeDigest: try draft.recomputedDigest().hex,
            disclosure: draft.disclosure,
            payload: draft.payload
        )
    }
}

private actor RecordingDriver: LLMHostSessionDriver {
    private var starts = 0
    private var cancels = 0
    private var closes = 0

    func makeAuthorizedLaunch(
        for turn: HostGenerationTurn,
        mode: HostGenerationMode
    ) async throws -> AuthorizedHostGenerationLaunch {
        starts += 1
        return AuthorizedHostGenerationLaunch {
            HostGenerationOperation(
                opaqueOperationID: turn.commandID,
                events: AsyncThrowingStream { continuation in
                    continuation.finish()
                }
            )
        }
    }

    func cancel() async throws { cancels += 1 }
    func close() async throws { closes += 1 }

    func startCount() -> Int { starts }
    func cancelCount() -> Int { cancels }
}

private actor RecordingRustSink: LLMHostRustSink {
    private let acceptsCleanupAcknowledgement: Bool
    private var acknowledgements: [HostCommandAcknowledgement] = []
    private var closeDispositionValue: LLMBackendSessionCloseDisposition?
    private var closeConfirmations = 0
    private var submittedEvents: [LLMEventEnvelope] = []
    private var operationLog: [String] = []

    init(acceptsCleanupAcknowledgement: Bool) {
        self.acceptsCleanupAcknowledgement = acceptsCleanupAcknowledgement
    }

    func submit(
        _ envelope: LLMEventEnvelope
    ) async throws -> LLMEventSubmissionResult {
        submittedEvents.append(envelope)
        operationLog.append("event:\(envelope.kind.rawValue)")
        return .accepted
    }

    func submitCommandAcknowledgement(_ acknowledgement: HostCommandAcknowledgement) async -> Bool {
        acknowledgements.append(acknowledgement)
        operationLog.append("ack:\(acknowledgement.commandID)")
        return true
    }

    func acknowledgePreparedSessionCleanup(
        _ acknowledgement: PreparedSessionCleanupAcknowledgementDTO
    ) async -> Bool {
        acceptsCleanupAcknowledgement
    }

    func confirmPreparedSessionClosed(
        _ receipt: PreparedSessionClosedReceiptDTO
    ) async -> Bool {
        closeConfirmations += 1
        closeDispositionValue = LLMBackendSessionCloseDisposition(
            rawValue: receipt.closeDisposition
        )
        return true
    }

    func acknowledgedCommandIDs() -> [String] {
        acknowledgements.map(\.commandID)
    }

    func lastRejectionCode() -> String? {
        acknowledgements.last?.rejectionCode
    }

    func closedDisposition() -> LLMBackendSessionCloseDisposition? {
        closeDispositionValue
    }

    func confirmedCloseCount() -> Int { closeConfirmations }
    func eventKinds() -> [LLMEventKind] { submittedEvents.map(\.kind) }
    func operations() -> [String] { operationLog }
}

private actor RecordingV2ModelExecutor: ModelGenerationExecuting {
    private var requests: [HostModelRequest] = []
    private var finishedRunIDs: [String] = []

    func generate(
        _ request: HostModelRequest,
        emit: @escaping @Sendable (HostModelEvent) async throws -> Void
    ) async throws {
        requests.append(request)
        try await emit(.textDelta("done"))
    }

    func cancel(runID: String) async {}

    func finish(runID: String) async {
        finishedRunIDs.append(runID)
    }

    func requestCount() -> Int { requests.count }
    func finishedRuns() -> [String] { finishedRunIDs }
}

private actor CloseCounter {
    private var count = 0
    func increment() { count += 1 }
    func value() -> Int { count }
}

private struct TestDispatchEnvelope<Payload: Encodable>: Encodable {
    let schemaVersion = 1
    let dispatchKind: String
    let command: Payload?
    let preparedSessionCleanup: Payload?

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case dispatchKind = "dispatch_kind"
        case command
        case preparedSessionCleanup = "prepared_session_cleanup"
    }
}

private struct TestCleanupCommand: Codable {
    let cleanupCommandID: String
    let preparationID: String
    let proposedRunID: String
    let sessionHandle: String
    let hostProcessEpoch: String
    let preparationCleanupSequence: UInt64
    let reason: String
    let preparedSessionRegistrationDigest: String
    let cleanupCommandDigest: String

    private enum CodingKeys: String, CodingKey {
        case cleanupCommandID = "cleanup_command_id"
        case preparationID = "preparation_id"
        case proposedRunID = "proposed_run_id"
        case sessionHandle = "session_handle"
        case hostProcessEpoch = "host_process_epoch"
        case preparationCleanupSequence = "preparation_cleanup_sequence"
        case reason
        case preparedSessionRegistrationDigest = "prepared_session_registration_digest"
        case cleanupCommandDigest = "cleanup_command_digest"
    }
}

private func dispatch(_ command: HostCommandEnvelope) throws -> Data {
    try JSONEncoder().encode(
        TestDispatchEnvelope(
            dispatchKind: "command",
            command: command,
            preparedSessionCleanup: nil
        )
    )
}

private func cleanupDispatch(harness: HostRuntimeHarness) throws -> Data {
    let draft = TestCleanupCommand(
        cleanupCommandID: "cleanup-1",
        preparationID: harness.preparationID,
        proposedRunID: harness.runID,
        sessionHandle: harness.handle,
        hostProcessEpoch: HostRuntimeHarness.epoch.rawValue,
        preparationCleanupSequence: 1,
        reason: "preparation_failed",
        preparedSessionRegistrationDigest: harness.registrationDigest,
        cleanupCommandDigest: ""
    )
    let canonical = try JSONDecoder().decode(
        CanonicalJSONValue.self,
        from: JSONEncoder().encode(draft)
    )
    let digest = try CanonicalDigestV1.digest(
        domain: "prepared-session-cleanup-command:v1",
        document: canonical
    ).hex
    let cleanup = TestCleanupCommand(
        cleanupCommandID: draft.cleanupCommandID,
        preparationID: draft.preparationID,
        proposedRunID: draft.proposedRunID,
        sessionHandle: draft.sessionHandle,
        hostProcessEpoch: draft.hostProcessEpoch,
        preparationCleanupSequence: draft.preparationCleanupSequence,
        reason: draft.reason,
        preparedSessionRegistrationDigest: draft.preparedSessionRegistrationDigest,
        cleanupCommandDigest: digest
    )
    return try JSONEncoder().encode(
        TestDispatchEnvelope(
            dispatchKind: "prepared_session_cleanup",
            command: Optional<TestCleanupCommand>.none,
            preparedSessionCleanup: cleanup
        )
    )
}

private func loadCommandFixture() throws -> HostCommandEnvelope {
    let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let fixtureURL = repositoryRoot
        .appendingPathComponent("contracts/canonical-digest-v1/fixtures/host-command-envelope-v1.json")
    let object = try JSONSerialization.jsonObject(with: Data(contentsOf: fixtureURL)) as! [String: Any]
    let wire = try JSONSerialization.data(withJSONObject: object["wire"] as Any)
    return try JSONDecoder().decode(HostCommandEnvelope.self, from: wire)
}

private extension String {
    func paddingToBase64MultipleOfFour() -> String {
        self + String(repeating: "=", count: (4 - count % 4) % 4)
    }
}
