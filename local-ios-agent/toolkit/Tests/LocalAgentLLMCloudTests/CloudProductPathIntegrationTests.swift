import Foundation
import LocalAgentLLMContracts
@testable import LocalAgentLLMCore
import Testing
@testable import LocalAgentLLMCloud

@Suite("Cloud product path integration", .serialized)
struct CloudProductPathIntegrationTests {
    @Test
    func subsystemRunsValidatedToolLoopThenRotationRequiresRevalidation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cloud-product-path-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let catalogFixture = try signedCloudCatalog(revision: 1)
        let transport = SubsystemFixtureTransport()
        let prompt = RuntimeApprovalPrompt()
        let epoch = try HostProcessEpoch.generate()
        let subsystem = try await CloudLLMSubsystem.bootstrap(
            appSupportRoot: directory,
            hostProcessEpoch: epoch,
            bundledCatalog: catalogFixture.envelope,
            trustedKeyRing: catalogFixture.keyRing,
            remoteCatalog: nil,
            vault: RuntimeCredentialVault(),
            approvalPrompt: prompt,
            transportFactory: { _ in transport },
            localUnloader: RuntimeLocalUnloader(order: RuntimeRouteOrder()),
            originValidator: RuntimeOriginValidator()
        )

        try await subsystem.credentials.createSlot(
            credentialRef: "integration-key",
            initialSecret: SecretBytes(utf8: "fixture-secret"),
            operationID: "integration-create-key"
        )
        _ = try await subsystem.profiles.publish(ProviderProfileRevision(
            profileID: "integration-profile",
            revision: 1,
            presetID: .openAI,
            displayName: "Integration provider",
            baseURL: URL(string: "https://api.example.com/v1")!,
            credentialRef: "integration-key",
            retentionMode: .statelessRequired
        ))
        let target = LLMTargetRevision(
            targetID: LLMTargetID(rawValue: "integration-target"),
            revision: 1,
            kind: .cloud(
                providerProfileID: "integration-profile",
                providerProfileRevision: 1
            ),
            modelID: "fixture-model",
            defaultParameters: GenerationConfiguration()
        )
        try await subsystem.profiles.publishTarget(target)
        let validation = try await subsystem.validation.validate(
            profileID: "integration-profile",
            profileRevision: 1,
            modelID: "fixture-model",
            adapterVersion: "1"
        )
        #expect(validation.snapshot.support(for: "tool_calling") == .supported)

        let configuration = AgentHostConfiguration(
            bindingID: "integration-binding",
            revision: 1,
            agentProfileID: "integration-agent",
            agentProfileRevision: 1,
            llmSlotID: "assistant",
            requirementsHash: String(repeating: "a", count: 64),
            llmTargetID: target.targetID,
            llmTargetRevision: target.revision,
            parameterOverrides: GenerationConfiguration()
        )
        let saga = AgentHostBindingSaga(store: subsystem.bindingStore)
        let binding = try await saga.stageHostBinding(HostBindingStageRequest(
            operationToken: "integration-binding-token",
            tokenDigest: "integration-binding-token-digest",
            llmSlotID: configuration.llmSlotID,
            requirementsHash: configuration.requirementsHash,
            configuration: configuration
        ))
        try await saga.activateHostBinding(
            operationToken: "integration-binding-token",
            binding: binding.binding
        )
        let catalog = try #require(try await subsystem.catalog.current())
        let entry = try #require(catalog.entry(presetID: .openAI, modelID: target.modelID))
        let resolved = try CloudGenerationConfigurationResolver.resolve(entry: entry)
        let initial = try runtimeTurn(
            resolvedParameters: resolved.semantic,
            generationTurnID: "integration-turn-1",
            inputID: "integration-input-1",
            text: "find contacts",
            semanticHistory: .array([]),
            toolResults: [],
            dataClasses: [.text],
            sensitivity: .routine,
            sourceKinds: [.conversation],
            triggeringToolDisplayKeys: []
        )
        let prepared = try await subsystem.runtime.prepareSession(
            context: .init(
                preparationID: "integration-preparation",
                proposedRunID: "integration-run",
                initialTurn: initial,
                signedToolDisplayKeys: ["contacts.search"]
            ),
            hostConfiguration: configuration,
            target: target
        )
        let toolEvents = try await collect(try await subsystem.runtime.startGeneration(
            sessionID: prepared.sessionID,
            turn: initial
        ))
        #expect(toolEvents.last == .generationCompleted(.init(
            outcome: .toolCallsReady,
            orderedCallIDs: ["call-1"],
            finishReason: .toolCalls
        )))
        let resume = try runtimeTurn(
            resolvedParameters: resolved.semantic,
            generationTurnID: "integration-turn-2",
            inputID: "integration-input-2",
            text: "normalized tool result",
            semanticHistory: .array([.string("complete-history")]),
            toolResults: [.init(
                callID: "call-1",
                toolName: "contacts.search",
                result: .string("two contacts"),
                isError: false,
                dataClasses: [.contacts, .toolResult],
                highestSensitivity: .sensitive
            )],
            dataClasses: [.text, .contacts, .toolResult],
            sensitivity: .sensitive,
            sourceKinds: [.conversation, .contacts, .toolResult],
            triggeringToolDisplayKeys: ["contacts.search"]
        )
        let finalEvents = try await collect(try await subsystem.runtime.resumeGeneration(
            sessionID: prepared.sessionID,
            turn: resume
        ))
        #expect(finalEvents.contains(.textDelta("Done")))
        #expect(finalEvents.last == .generationCompleted(.init(
            outcome: .finalResponse,
            orderedCallIDs: [],
            finishReason: .stop
        )))
        try await subsystem.runtime.closeSession(sessionID: prepared.sessionID)
        #expect(try await subsystem.credentials.lease(prepared.credentialUseLeaseID) == nil)

        try await subsystem.credentials.rotateCredential(
            credentialRef: "integration-key",
            expectedGeneration: 1,
            replacement: SecretBytes(utf8: "replacement-secret"),
            operationID: "integration-rotate"
        )
        #expect(try await subsystem.credentials.slot("integration-key")?.currentGeneration == 2)
        let state = try #require(await subsystem.profiles.state(
            profileID: "integration-profile",
            profileRevision: 1
        ))
        #expect(state.validationState == .invalidated(reasonCode: "credential.rotated"))
        #expect(await transport.validationRequestCount == 3)
        #expect(await transport.generationRequestCount == 2)
    }
}

private actor SubsystemFixtureTransport: CloudHTTPTransport {
    private(set) var validationRequestCount = 0
    private(set) var generationRequestCount = 0

    func json(_ request: AuthorizedCloudHTTPRequest) async throws -> Data {
        validationRequestCount += 1
        return Data(#"{"data":[{"id":"fixture-model"}]}"#.utf8)
    }

    func stream(
        _ request: AuthorizedCloudHTTPRequest
    ) async throws -> AsyncThrowingStream<SSEEvent, Error> {
        let events: [SSEEvent]
        switch request.authorization {
        case .validation:
            validationRequestCount += 1
            events = runtimeFinalEvents(text: "OK", responseID: "integration-validation")
        case .generation:
            generationRequestCount += 1
            events = generationRequestCount == 1
                ? runtimeToolBatchEvents()
                : runtimeFinalEvents()
        case .discovery:
            throw LLMFailure(
                code: "test.discovery_stream_invalid",
                message: "discovery must use JSON",
                retryable: false
            )
        }
        return AsyncThrowingStream { continuation in
            for event in events { continuation.yield(event) }
            continuation.finish()
        }
    }
}
