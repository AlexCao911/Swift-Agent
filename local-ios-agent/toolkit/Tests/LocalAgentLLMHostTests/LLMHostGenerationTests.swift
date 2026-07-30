import Foundation
import LocalAgentBridge
import LocalAgentLLMContracts
import Testing
@testable import LocalAgentLLMHost

@Suite("LLM host generation")
struct LLMHostGenerationTests {
    @Test
    func acceptedCommandIsAcknowledgedBeforeApprovalAndPumpsOneLiveOperation() async throws {
        let driver = GenerationDriver()
        let sink = GenerationRustSink()
        let harness = try await GenerationHarness.make(driver: driver, sink: sink)

        #expect(harness.runtime.copy(try harness.dispatch()) == .copied)
        await eventually { await driver.authorizationCount() == 1 }
        await eventually { await sink.acknowledgementCount() == 1 }

        #expect(await sink.acknowledgementCount() == 1)
        #expect(await sink.eventKinds().isEmpty)

        await driver.approve()
        await eventually { await sink.eventKinds().count == 3 }

        #expect(await driver.launchCount() == 1)
        #expect(await sink.eventKinds() == [
            .generationStarted,
            .textDelta,
            .generationCompleted,
        ])
        #expect(await sink.events().first?.payload.commandID == "command-1")
        #expect(await sink.events().first?.payload.opaqueOperationID == "operation-1")
        #expect(await sink.events().last?.payload.completion?.outcome == "final_response")
    }

    @Test
    func operationStartTimeoutEmitsFailureWithoutGenerationStarted() async throws {
        let driver = HangingGenerationDriver()
        let sink = GenerationRustSink()
        let harness = try await GenerationHarness.make(
            driver: driver,
            sink: sink,
            operationStartTimeout: .milliseconds(5)
        )

        #expect(harness.runtime.copy(try harness.dispatch()) == .copied)
        await eventually { await sink.eventKinds().count == 1 }

        #expect(await sink.acknowledgementCount() == 1)
        #expect(await sink.eventKinds() == [.failed])
        #expect(await sink.events().only?.payload.failureCode == "generation_failed")
    }

    @Test
    func cancelAndCloseAcknowledgeClaimsBeforeBackendTerminalAndRunOnce() async throws {
        let driver = LifecycleGenerationDriver()
        let sink = GenerationRustSink()
        let harness = try await GenerationHarness.make(driver: driver, sink: sink)

        #expect(harness.runtime.copy(try harness.dispatch()) == .copied)
        await eventually { await sink.eventKinds() == [.generationStarted] }

        let cancel = try lifecycleCommand(
            from: harness.command,
            commandID: "cancel-1",
            sequence: 2,
            kind: .cancelGeneration
        )
        let cancelDispatch = try dispatch(cancel)
        #expect(harness.runtime.copy(cancelDispatch) == .copied)
        await eventually { await sink.acknowledgementCount() == 2 }
        #expect(await sink.acknowledgementCount() == 2)
        #expect(await driver.cancelCount() == 1)
        #expect(await sink.eventKinds() == [.generationStarted])

        #expect(harness.runtime.copy(cancelDispatch) == .copied)
        await driver.confirmCancel()
        await eventually { await sink.eventKinds().last == .cancelled }
        #expect(await driver.cancelCount() == 1)
        #expect(await sink.eventKinds().filter { $0 == .cancelled }.count == 1)
        #expect(await sink.events().last?.payload.commandID == "cancel-1")

        let close = try lifecycleCommand(
            from: harness.command,
            commandID: "close-1",
            sequence: 3,
            kind: .closeSession
        )
        #expect(harness.runtime.copy(try dispatch(close)) == .copied)
        await eventually { await sink.acknowledgementCount() == 3 }
        #expect(await sink.acknowledgementCount() == 3)
        await eventually { await driver.closeCount() == 1 }
        #expect(await driver.closeCount() == 1)
        #expect(await sink.eventKinds().last == .cancelled)

        await driver.confirmClose()
        await eventually { await sink.eventKinds().last == .sessionClosed }
        await eventually {
            await harness.runtime.bridgeActor.lifecycle(
                for: harness.command.sessionHandle
            ) == .closed
        }
        #expect(await driver.closeCount() == 1)
    }

    @Test
    func localResumeInputCarriesSemanticHistoryAndTheExactToolResult() throws {
        let input = AgentLLMInput(
            inputID: "turn-2",
            messages: [LLMInputMessage(role: .user, content: [.text("current")])]
        )
        let semanticHistory = [
            LLMInputMessage(role: .system, content: [.text("policy")]),
            LLMInputMessage(role: .user, content: [.text("hello")]),
        ]
        let result = NormalizedToolResult(
            callID: "call-1",
            toolName: "contacts.search",
            result: try .object(entries: [
                .init(name: "name", value: .string("Ada")),
            ]),
            isError: false,
            dataClasses: [.contacts],
            highestSensitivity: .sensitive
        )

        let resumed = try localResumeInput(
            input,
            semanticHistory: semanticHistory,
            toolResults: [result]
        )

        #expect(resumed.messages.map(\.role) == [.system, .user, .tool])
        #expect(resumed.messages.last?.role == .tool)
        guard case let .text(text)? = resumed.messages.last?.content.only else {
            Issue.record("tool result was not encoded as local model text")
            return
        }
        #expect(text == #"{"call_id":"call-1","is_error":false,"result":{"name":"Ada"},"tool_name":"contacts.search"}"#)
    }

    @Test
    func rustReActRequestUsesRustContextAndNormalizesOpenMinisTools() throws {
        let schema = try CanonicalJSONValue.object(entries: [
            .init(name: "type", value: .string("object")),
            .init(name: "properties", value: try .object(entries: [
                .init(name: "command", value: try .object(entries: [
                    .init(name: "type", value: .string("string")),
                ])),
            ])),
        ])
        let request = HostModelRequest(
            runID: "run-1",
            conversationStreamID: "conversation-1",
            systemPrompt: "system",
            orderedMessages: [
                HostModelMessage(role: "user", content: .string("inspect")),
                HostModelMessage(role: "tool", content: .string("large output")),
            ],
            attachmentReferences: [],
            orderedToolDefinitions: [
                HostToolDefinition(
                    name: "shell",
                    description: "Run a command",
                    inputSchema: schema
                ),
            ],
            orderedToolResults: [
                HostToolResult(
                    callID: "call-1",
                    toolName: "shell",
                    result: .string("done"),
                    isError: false,
                    dataClasses: ["shell_output"],
                    highestSensitivity: "public"
                ),
            ]
        )

        let input = try rustReActInput(request, includeContext: true)
        #expect(input.messages.map(\.role) == [.system, .user, .user])
        #expect(try rustReActInput(request, includeContext: false).messages.isEmpty)
        #expect(try rustReActToolSchema(request) == .object(entries: [
            .init(name: "tools", value: .array([
                try .object(entries: [
                    .init(name: "description", value: .string("Run a command")),
                    .init(name: "name", value: .string("shell")),
                    .init(name: "parameters", value: schema),
                ]),
            ])),
        ]))

        let result = try #require(rustReActToolResults(request.orderedToolResults).first)
        #expect(result.dataClasses == [.unknownData])
        #expect(result.highestSensitivity == .unknown)
    }

    @Test
    func rustReActRequestResolvesTextAndLocalImageAttachments() throws {
        let textReference = HostAttachmentReference(
            attachmentID: "attachment-text",
            displayName: "notes.txt",
            mediaType: "text/plain",
            modality: "file",
            contentDigest: String(repeating: "a", count: 64)
        )
        let imageReference = HostAttachmentReference(
            attachmentID: "attachment-image",
            displayName: "pixel.rgb",
            mediaType: "image/rgb8",
            modality: "image",
            contentDigest: String(repeating: "b", count: 64)
        )
        let request = HostModelRequest(
            runID: "run-with-attachments",
            conversationStreamID: "conversation-with-attachments",
            systemPrompt: "system",
            orderedMessages: [
                HostModelMessage(role: "user", content: .string("inspect")),
            ],
            attachmentReferences: [textReference, imageReference],
            orderedToolDefinitions: []
        )
        let resolved = [
            RustReActResolvedAttachment(
                reference: textReference,
                content: .text("hello attachment")
            ),
            RustReActResolvedAttachment(
                reference: imageReference,
                content: .imageRGB8(Data([1, 2, 3]), width: 1, height: 1)
            ),
        ]

        let input = try rustReActInput(
            request,
            includeContext: true,
            resolvedAttachments: resolved
        )

        #expect(input.messages.map(\.role) == [.system, .user, .user])
        let expectedContent: [LLMInputContent] = [
            .text("[Attachment: notes.txt (text/plain)]\nhello attachment"),
            .attachment(
                modality: .image,
                attachmentID: "attachment-image",
                mediaType: "image/rgb8"
            ),
        ]
        #expect(input.messages.last?.content == expectedContent)
    }
}

private struct GenerationHarness {
    static let epoch = HostProcessEpoch(
        rawValue: "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
    )!

    let runtime: LLMHostRuntime
    let command: HostCommandEnvelope

    static func make(
        driver: any LLMHostSessionDriver,
        sink: GenerationRustSink,
        operationStartTimeout: Duration = .seconds(10)
    ) async throws -> Self {
        let runtime = LLMHostRuntime(
            hostProcessEpoch: epoch,
            rustSink: sink,
            operationStartTimeout: operationStartTimeout
        )
        let fixture = try loadGenerationCommandFixture()
        let command = try signedCommand(from: fixture)
        let cleanupOwner = PreparedSessionCleanupOwner()
        try await runtime.bridgeActor.allocate(
            AllocatedHostSession(
                sessionHandle: command.sessionHandle,
                preparationID: "preparation-1",
                proposedRunID: command.runID,
                swiftSnapshotID: "snapshot-1",
                bindingHash: String(repeating: "a", count: 64),
                hostProcessEpoch: epoch,
                preparedSessionRegistrationDigest: String(repeating: "b", count: 64),
                cleanupOwner: cleanupOwner
            )
        )
        try await runtime.bridgeActor.beginRegistration(command.sessionHandle)
        try await runtime.bridgeActor.markRegistered(command.sessionHandle)
        try await runtime.bridgeActor.beginOpen(command.sessionHandle)
        try await runtime.bridgeActor.installOpenedDriver(
            driver,
            for: command.sessionHandle
        )
        try await runtime.bridgeActor.beginCommit(command.sessionHandle)
        try await runtime.bridgeActor.markCommitted(command.sessionHandle)
        return Self(runtime: runtime, command: command)
    }

    func dispatch() throws -> Data {
        try JSONEncoder().encode(
            GenerationDispatchEnvelope(
                schemaVersion: 1,
                dispatchKind: "command",
                command: command
            )
        )
    }

    private static func signedCommand(
        from fixture: HostCommandEnvelope
    ) throws -> HostCommandEnvelope {
        let draft = HostCommandEnvelope(
            schemaVersion: 1,
            commandID: "command-1",
            runID: "run-1",
            sessionHandle: "session-1",
            hostProcessEpoch: epoch.rawValue,
            commandSequence: 1,
            generationTurnID: fixture.generationTurnID,
            kind: .startGeneration,
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
}

private struct HangingGenerationDriver: LLMHostSessionDriver {
    func makeAuthorizedLaunch(
        for turn: HostGenerationTurn,
        mode: HostGenerationMode
    ) async throws -> AuthorizedHostGenerationLaunch {
        AuthorizedHostGenerationLaunch {
            try await Task.sleep(for: .seconds(60))
            return HostGenerationOperation(
                opaqueOperationID: "too-late",
                events: AsyncThrowingStream { $0.finish() }
            )
        }
    }

    func cancel() async throws {}
    func close() async throws {}
}

private actor LifecycleGenerationDriver: LLMHostSessionDriver {
    private var stream: AsyncThrowingStream<LLMBackendEvent, Error>.Continuation?
    private var cancelCalls = 0
    private var closeCalls = 0
    private var cancelConfirmation: CheckedContinuation<Void, Never>?
    private var closeConfirmation: CheckedContinuation<Void, Never>?

    func makeAuthorizedLaunch(
        for turn: HostGenerationTurn,
        mode: HostGenerationMode
    ) async throws -> AuthorizedHostGenerationLaunch {
        let (events, continuation) = AsyncThrowingStream<
            LLMBackendEvent,
            Error
        >.makeStream()
        stream = continuation
        return AuthorizedHostGenerationLaunch {
            return HostGenerationOperation(
                opaqueOperationID: "lifecycle-operation",
                events: events
            )
        }
    }

    func cancel() async throws {
        cancelCalls += 1
        await withCheckedContinuation { cancelConfirmation = $0 }
        stream?.yield(.cancelled)
        stream?.finish()
    }

    func close() async throws {
        closeCalls += 1
        await withCheckedContinuation { closeConfirmation = $0 }
    }

    func confirmCancel() {
        cancelConfirmation?.resume()
        cancelConfirmation = nil
    }

    func confirmClose() {
        closeConfirmation?.resume()
        closeConfirmation = nil
    }

    func cancelCount() -> Int { cancelCalls }
    func closeCount() -> Int { closeCalls }
}

private actor GenerationDriver: LLMHostSessionDriver {
    private var authorizationRequests = 0
    private var launches = 0
    private var approval: CheckedContinuation<Void, Never>?

    func makeAuthorizedLaunch(
        for turn: HostGenerationTurn,
        mode: HostGenerationMode
    ) async throws -> AuthorizedHostGenerationLaunch {
        authorizationRequests += 1
        await withCheckedContinuation { approval = $0 }
        return AuthorizedHostGenerationLaunch { [weak self] in
            await self?.recordLaunch()
            return HostGenerationOperation(
                opaqueOperationID: "operation-1",
                events: AsyncThrowingStream { continuation in
                    continuation.yield(.textDelta("answer"))
                    continuation.yield(
                        .generationCompleted(
                            LLMBackendCompletion(
                                outcome: .finalResponse,
                                orderedCallIDs: [],
                                finishReason: .stop
                            )
                        )
                    )
                    continuation.finish()
                }
            )
        }
    }

    func cancel() async throws {}
    func close() async throws {}

    func approve() {
        approval?.resume()
        approval = nil
    }

    func authorizationCount() -> Int { authorizationRequests }
    func launchCount() -> Int { launches }
    private func recordLaunch() { launches += 1 }
}

private actor GenerationRustSink: LLMHostRustSink, LLMEventSubmitting {
    private var acknowledgements: [HostCommandAcknowledgement] = []
    private var submittedEvents: [LLMEventEnvelope] = []

    func submitCommandAcknowledgement(
        _ acknowledgement: HostCommandAcknowledgement
    ) async -> Bool {
        acknowledgements.append(acknowledgement)
        return true
    }

    func acknowledgePreparedSessionCleanup(
        _ acknowledgement: PreparedSessionCleanupAcknowledgementDTO
    ) async -> Bool { true }

    func confirmPreparedSessionClosed(
        _ receipt: PreparedSessionClosedReceiptDTO
    ) async -> Bool { true }

    func submit(
        _ envelope: LLMEventEnvelope
    ) async throws -> LLMEventSubmissionResult {
        submittedEvents.append(envelope)
        return .accepted
    }

    func acknowledgementCount() -> Int { acknowledgements.count }
    func eventKinds() -> [LLMEventKind] { submittedEvents.map(\.kind) }
    func events() -> [LLMEventEnvelope] { submittedEvents }
}

private struct GenerationDispatchEnvelope: Encodable {
    let schemaVersion: UInt32
    let dispatchKind: String
    let command: HostCommandEnvelope

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case dispatchKind = "dispatch_kind"
        case command
    }
}

private func lifecycleCommand(
    from source: HostCommandEnvelope,
    commandID: String,
    sequence: UInt64,
    kind: HostCommandKind
) throws -> HostCommandEnvelope {
    let draft = HostCommandEnvelope(
        schemaVersion: 1,
        commandID: commandID,
        runID: source.runID,
        sessionHandle: source.sessionHandle,
        hostProcessEpoch: source.hostProcessEpoch,
        commandSequence: sequence,
        generationTurnID: nil,
        kind: kind,
        payloadDigest: source.payloadDigest,
        disclosureDigest: nil,
        commandEnvelopeDigest: "",
        disclosure: nil,
        payload: source.payload
    )
    return HostCommandEnvelope(
        schemaVersion: draft.schemaVersion,
        commandID: draft.commandID,
        runID: draft.runID,
        sessionHandle: draft.sessionHandle,
        hostProcessEpoch: draft.hostProcessEpoch,
        commandSequence: draft.commandSequence,
        generationTurnID: nil,
        kind: draft.kind,
        payloadDigest: draft.payloadDigest,
        disclosureDigest: nil,
        commandEnvelopeDigest: try draft.recomputedDigest().hex,
        disclosure: nil,
        payload: draft.payload
    )
}

private func dispatch(_ command: HostCommandEnvelope) throws -> Data {
    try JSONEncoder().encode(
        GenerationDispatchEnvelope(
            schemaVersion: 1,
            dispatchKind: "command",
            command: command
        )
    )
}

private func loadGenerationCommandFixture() throws -> HostCommandEnvelope {
    let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let fixtureURL = repositoryRoot.appendingPathComponent(
        "contracts/canonical-digest-v1/fixtures/host-command-envelope-v1.json"
    )
    let object = try JSONSerialization.jsonObject(
        with: Data(contentsOf: fixtureURL)
    ) as! [String: Any]
    let wire = try JSONSerialization.data(withJSONObject: object["wire"] as Any)
    return try JSONDecoder().decode(HostCommandEnvelope.self, from: wire)
}

private func eventually(
    _ predicate: @escaping @Sendable () async -> Bool
) async {
    for _ in 0..<100 where !(await predicate()) {
        try? await Task.sleep(for: .milliseconds(1))
    }
}

private extension Array {
    var only: Element? { count == 1 ? first : nil }
}
