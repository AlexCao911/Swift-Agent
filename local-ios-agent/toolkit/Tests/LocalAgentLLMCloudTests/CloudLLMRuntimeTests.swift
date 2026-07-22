import CryptoKit
import Foundation
import LocalAgentLLMContracts
@testable import LocalAgentLLMCore
import Testing
@testable import LocalAgentLLMCloud

@Suite("Direct Swift cloud runtime", .serialized)
struct CloudLLMRuntimeTests {
    @Test
    func shippedRuntimeRegistryContainsEveryReleaseProviderExactlyOnce() throws {
        let registry = try CloudProviderAdapterRegistry.shipped()

        #expect(registry.presetIDs == Set(ProviderPreset.shipped.map(\.id)))
        #expect(registry.adapterIDs == Set(ProviderPreset.shipped.map(\.semanticAdapterID)))
        #expect(registry.adapterIDs.count == 7)
    }

    @Test
    func probedManualModelRunsOnlyConservativeStatelessText() async throws {
        let transport = RuntimeGenerationTransport(scripts: [runtimeFinalEvents()])
        let harness = try await CloudRuntimeHarness.make(
            generationTransport: transport,
            localUnloader: RuntimeLocalUnloader(order: RuntimeRouteOrder()),
            modelID: "manual-openai-model",
            toolSchema: .array([])
        )
        defer { harness.cleanup() }

        let prepared = try await harness.runtime.prepareSession(
            context: .init(
                preparationID: "manual-preparation",
                proposedRunID: "manual-run",
                initialTurn: harness.initialTurn,
                signedToolDisplayKeys: []
            ),
            hostConfiguration: harness.hostConfiguration,
            target: harness.target
        )
        let events = try await collect(try await harness.runtime.startGeneration(
            sessionID: prepared.sessionID,
            turn: harness.initialTurn
        ))
        #expect(events.contains(.textDelta("Done")))
        #expect(events.last == .generationCompleted(.init(
            outcome: .finalResponse,
            orderedCallIDs: [],
            finishReason: .stop
        )))
        try await harness.runtime.closeSession(sessionID: prepared.sessionID)

        let toolHarness = try await CloudRuntimeHarness.make(
            generationTransport: RuntimeGenerationTransport(scripts: []),
            localUnloader: RuntimeLocalUnloader(order: RuntimeRouteOrder()),
            modelID: "manual-openai-model"
        )
        defer { toolHarness.cleanup() }
        await expectRuntimeFailure("runtime.cloud_capability_unsatisfied") {
            _ = try await toolHarness.runtime.prepareSession(
                context: .init(
                    preparationID: "manual-tools-preparation",
                    proposedRunID: "manual-tools-run",
                    initialTurn: toolHarness.initialTurn,
                    signedToolDisplayKeys: ["contacts.search"]
                ),
                hostConfiguration: toolHarness.hostConfiguration,
                target: toolHarness.target
            )
        }

        let targetParameterHarness = try await CloudRuntimeHarness.make(
            generationTransport: RuntimeGenerationTransport(scripts: []),
            localUnloader: RuntimeLocalUnloader(order: RuntimeRouteOrder()),
            modelID: "manual-openai-model",
            targetDefaults: GenerationConfiguration()
                .setting(.samplingTemperature, to: .decimal(0.2)),
            toolSchema: .array([])
        )
        defer { targetParameterHarness.cleanup() }
        await expectRuntimeFailure("cloud_parameters.manual_parameter_unsupported") {
            _ = try await targetParameterHarness.runtime.prepareSession(
                context: .init(
                    preparationID: "manual-target-parameter-preparation",
                    proposedRunID: "manual-target-parameter-run",
                    initialTurn: targetParameterHarness.initialTurn,
                    signedToolDisplayKeys: []
                ),
                hostConfiguration: targetParameterHarness.hostConfiguration,
                target: targetParameterHarness.target
            )
        }

        let hostParameterHarness = try await CloudRuntimeHarness.make(
            generationTransport: RuntimeGenerationTransport(scripts: []),
            localUnloader: RuntimeLocalUnloader(order: RuntimeRouteOrder()),
            modelID: "manual-openai-model",
            hostOverrides: GenerationConfiguration()
                .setting(.generationMaxOutputTokens, to: .integer(64)),
            toolSchema: .array([])
        )
        defer { hostParameterHarness.cleanup() }
        await expectRuntimeFailure("cloud_parameters.manual_parameter_unsupported") {
            _ = try await hostParameterHarness.runtime.prepareSession(
                context: .init(
                    preparationID: "manual-host-parameter-preparation",
                    proposedRunID: "manual-host-parameter-run",
                    initialTurn: hostParameterHarness.initialTurn,
                    signedToolDisplayKeys: []
                ),
                hostConfiguration: hostParameterHarness.hostConfiguration,
                target: hostParameterHarness.target
            )
        }

        let statefulHarness = try await CloudRuntimeHarness.make(
            generationTransport: RuntimeGenerationTransport(scripts: []),
            localUnloader: RuntimeLocalUnloader(order: RuntimeRouteOrder()),
            modelID: "manual-openai-model",
            retentionMode: .providerStateApproved,
            toolSchema: .array([])
        )
        defer { statefulHarness.cleanup() }
        await expectRuntimeFailure("runtime.cloud_target_not_runnable") {
            _ = try await statefulHarness.runtime.prepareSession(
                context: .init(
                    preparationID: "manual-stateful-preparation",
                    proposedRunID: "manual-stateful-run",
                    initialTurn: statefulHarness.initialTurn,
                    signedToolDisplayKeys: []
                ),
                hostConfiguration: statefulHarness.hostConfiguration,
                target: statefulHarness.target
            )
        }
    }

    @Test
    func turnRequestUsesAuthoritativeAttachmentResolverBeforeSemanticValidation() throws {
        let input = AgentLLMInput(
            inputID: "input-1",
            messages: [LLMInputMessage(role: .user, content: [.text("hello")])]
        )
        let request = CloudGenerationTurnRequest(
            input: input,
            canonicalToolSchema: .array([]),
            sourceRevisionDocument: try .object(entries: []),
            toolResults: [],
            providerRequiredSemanticHistory: .array([]),
            disclosure: GenerationDisclosure(
                schemaVersion: "1",
                generationTurnID: "turn-1",
                contentDigest: String(repeating: "0", count: 64),
                sourceRevisionDigest: String(repeating: "0", count: 64),
                dataClasses: [.text],
                highestSensitivity: .routine,
                safeDisplaySummary: SafeDisplaySummary(
                    sourceKinds: [.conversation],
                    addedItemCounts: [.init(dataClass: .text, count: 1)],
                    approximateAddedSize: .lessThanOneKiB,
                    triggeringToolDisplayKeys: []
                )
            ),
            resolvedParameters: GenerationConfiguration()
        )
        let resolver = EmptyCloudAttachmentResolver()

        let candidate = try request.candidate(using: resolver)

        #expect(candidate.input == input)
        #expect(candidate.resolvedAttachments.isEmpty)
        #expect(resolver.calls == 1)
    }

    @Test
    func exactPreparationToolBatchResumeAndCloseUseOneSealedCloudSession() async throws {
        let order = RuntimeRouteOrder()
        let transport = RuntimeGenerationTransport(scripts: [
            runtimeToolBatchEvents(), runtimeFinalEvents(),
        ], order: order)
        let harness = try await CloudRuntimeHarness.make(
            generationTransport: transport,
            localUnloader: RuntimeLocalUnloader(order: order)
        )
        defer { harness.cleanup() }

        let prepared = try await harness.runtime.prepareSession(
            context: CloudSessionPreparationContext(
                preparationID: "preparation-1",
                proposedRunID: "run-1",
                initialTurn: harness.initialTurn,
                signedToolDisplayKeys: ["contacts.search"]
            ),
            hostConfiguration: harness.hostConfiguration,
            target: harness.target
        )

        #expect(await order.unloadCount == 1)
        #expect(await transport.requests.isEmpty)
        #expect(prepared.targetID == harness.target.targetID)
        #expect(prepared.bindingID == harness.hostConfiguration.bindingID)
        #expect(prepared.credentialGeneration == 1)
        #expect(prepared.adapterID == "openai.responses")
        #expect(await harness.runtime.state == .prepared)
        await expectRuntimeFailure("runtime.cloud_session_busy") {
            _ = try await harness.runtime.prepareSession(
                context: .init(
                    preparationID: "preparation-2",
                    proposedRunID: "run-2",
                    initialTurn: harness.initialTurn,
                    signedToolDisplayKeys: []
                ),
                hostConfiguration: harness.hostConfiguration,
                target: harness.target
            )
        }

        let first = try await harness.runtime.startGeneration(
            sessionID: prepared.sessionID,
            turn: harness.initialTurn
        )
        let firstEvents = try await collect(first)
        #expect(firstEvents.first == .textDelta("I will check. "))
        #expect(firstEvents.contains(.toolCallCompleted(.init(
            callID: "call-1",
            name: "contacts.search",
            argumentsJSON: "{}"
        ))))
        #expect(firstEvents.last == .generationCompleted(.init(
            outcome: .toolCallsReady,
            orderedCallIDs: ["call-1"],
            finishReason: .toolCalls
        )))
        #expect(await harness.runtime.state == .awaitingToolResult)

        let resume = try runtimeTurn(
            resolvedParameters: harness.resolvedParameters,
            generationTurnID: "turn-2",
            inputID: "input-2",
            text: "tool result follows",
            semanticHistory: .array([.string("complete-normalized-history")]),
            toolResults: [NormalizedToolResult(
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
        let second = try await harness.runtime.resumeGeneration(
            sessionID: prepared.sessionID,
            turn: resume
        )
        let secondEvents = try await collect(second)
        #expect(secondEvents.contains(.textDelta("Done")))
        #expect(secondEvents.last == .generationCompleted(.init(
            outcome: .finalResponse,
            orderedCallIDs: [],
            finishReason: .stop
        )))
        #expect(await harness.runtime.state == .terminal)

        let requests = await transport.requests
        #expect(requests.count == 2)
        #expect(requests.allSatisfy {
            if case .generation = $0.authorization { return true }
            return false
        })
        #expect(await order.transportCount == 2)
        #expect(await order.transportBeforeUnload == 0)

        try await harness.runtime.closeSession(sessionID: prepared.sessionID)
        try await harness.runtime.closeSession(sessionID: prepared.sessionID)
        #expect(await harness.runtime.state == .idle)
        #expect(try await harness.credentials.lease(prepared.credentialUseLeaseID) == nil)
        #expect(try harness.sessionStore.tombstone(prepared.sessionID)?.disposition == .closed)
    }

    @Test
    func startRejectsAnyMutationOfTheFrozenInitialDisclosureBeforeTransport() async throws {
        let transport = RuntimeGenerationTransport(scripts: [runtimeFinalEvents()])
        let harness = try await CloudRuntimeHarness.make(
            generationTransport: transport,
            localUnloader: RuntimeLocalUnloader(order: RuntimeRouteOrder())
        )
        defer { harness.cleanup() }
        let prepared = try await harness.runtime.prepareSession(
            context: .init(
                preparationID: "preparation-frozen",
                proposedRunID: "run-frozen",
                initialTurn: harness.initialTurn,
                signedToolDisplayKeys: ["contacts.search"]
            ),
            hostConfiguration: harness.hostConfiguration,
            target: harness.target
        )
        let changed = CloudGenerationTurnRequest(
            input: AgentLLMInput(
                inputID: harness.initialTurn.input.inputID,
                messages: [.init(role: .user, content: [.text("changed after approval")])]
            ),
            canonicalToolSchema: harness.initialTurn.canonicalToolSchema,
            sourceRevisionDocument: harness.initialTurn.sourceRevisionDocument,
            toolResults: harness.initialTurn.toolResults,
            providerRequiredSemanticHistory: harness.initialTurn.providerRequiredSemanticHistory,
            disclosure: harness.initialTurn.disclosure,
            resolvedParameters: harness.initialTurn.resolvedParameters
        )

        await expectRuntimeFailure("runtime.cloud_generation_state_invalid") {
            _ = try await harness.runtime.startGeneration(
                sessionID: prepared.sessionID,
                turn: changed
            )
        }
        #expect(await transport.requests.isEmpty)
        try await harness.runtime.closeSession(sessionID: prepared.sessionID)
    }

    @Test
    func resumeRehashesEverySemanticFieldAndRejectsAttachmentsBeforeEgress() async throws {
        let transport = RuntimeGenerationTransport(scripts: [runtimeToolBatchEvents()])
        let harness = try await CloudRuntimeHarness.make(
            generationTransport: transport,
            localUnloader: RuntimeLocalUnloader(order: RuntimeRouteOrder())
        )
        defer { harness.cleanup() }
        let prepared = try await harness.runtime.prepareSession(
            context: .init(
                preparationID: "preparation-rehash",
                proposedRunID: "run-rehash",
                initialTurn: harness.initialTurn,
                signedToolDisplayKeys: ["contacts.search"]
            ),
            hostConfiguration: harness.hostConfiguration,
            target: harness.target
        )
        _ = try await collect(try await harness.runtime.startGeneration(
            sessionID: prepared.sessionID,
            turn: harness.initialTurn
        ))
        let valid = try runtimeTurn(
            resolvedParameters: harness.resolvedParameters,
            generationTurnID: "turn-rehash-2",
            inputID: "input-rehash-2",
            text: "resume",
            semanticHistory: .array([.string("complete-history")]),
            toolResults: [.init(
                callID: "call-1",
                toolName: "contacts.search",
                result: .string("result"),
                isError: false,
                dataClasses: [.contacts, .toolResult],
                highestSensitivity: .sensitive
            )],
            dataClasses: [.text, .contacts, .toolResult],
            sensitivity: .sensitive,
            sourceKinds: [.conversation, .contacts, .toolResult],
            triggeringToolDisplayKeys: ["contacts.search"]
        )
        let mutations: [(String, CloudGenerationTurnRequest)] = [
            ("cloud_turn.content_digest_mismatch", valid.replacing(
                input: AgentLLMInput(
                    inputID: valid.input.inputID,
                    messages: [.init(role: .user, content: [.text("changed")])]
                )
            )),
            ("cloud_turn.content_digest_mismatch", valid.replacing(
                toolSchema: try .object(entries: [])
            )),
            ("cloud_turn.source_revision_digest_mismatch", valid.replacing(
                sourceDocument: try .object(entries: [
                    .init(name: "sources", value: .array([])),
                ])
            )),
            ("cloud_turn.content_digest_mismatch", valid.replacing(
                toolResults: [.init(
                    callID: "call-1",
                    toolName: "contacts.search",
                    result: .string("changed"),
                    isError: false,
                    dataClasses: [.contacts, .toolResult],
                    highestSensitivity: .sensitive
                )]
            )),
            ("cloud_turn.content_digest_mismatch", valid.replacing(
                semanticHistory: .array([.string("changed-history")])
            )),
            ("capability.cloud_attachment_path_unavailable", valid.replacing(
                input: AgentLLMInput(
                    inputID: valid.input.inputID,
                    messages: [.init(role: .user, content: [
                        .text("resume"),
                        .attachment(
                            modality: .image,
                            attachmentID: "attachment-1",
                            mediaType: "image/png"
                        ),
                    ])]
                )
            )),
        ]
        for (code, mutation) in mutations {
            await expectRuntimeFailure(code) {
                _ = try await harness.runtime.resumeGeneration(
                    sessionID: prepared.sessionID,
                    turn: mutation
                )
            }
        }
        #expect(await transport.requests.count == 1)
        try await harness.runtime.closeSession(sessionID: prepared.sessionID)
    }

    @Test
    func retriesOnceBeforeOutputButNeverAfterAnyNormalizedOutput() async throws {
        let retrying = RuntimeFaultTransport(steps: [
            .failBeforeStream,
            .events(runtimeFinalEvents()),
        ])
        let firstHarness = try await CloudRuntimeHarness.make(
            generationTransport: retrying,
            localUnloader: RuntimeLocalUnloader(order: RuntimeRouteOrder())
        )
        defer { firstHarness.cleanup() }
        let firstPrepared = try await firstHarness.runtime.prepareSession(
            context: .init(
                preparationID: "preparation-retry",
                proposedRunID: "run-retry",
                initialTurn: firstHarness.initialTurn,
                signedToolDisplayKeys: []
            ),
            hostConfiguration: firstHarness.hostConfiguration,
            target: firstHarness.target
        )
        let retried = try await collect(try await firstHarness.runtime.startGeneration(
            sessionID: firstPrepared.sessionID,
            turn: firstHarness.initialTurn
        ))
        #expect(retried.contains(.textDelta("Done")))
        #expect(await retrying.requestCount == 2)
        try await firstHarness.runtime.closeSession(sessionID: firstPrepared.sessionID)

        let interrupted = RuntimeFaultTransport(steps: [
            .eventsThenFail(Array(runtimeFinalEvents().prefix(2))),
        ])
        let secondHarness = try await CloudRuntimeHarness.make(
            generationTransport: interrupted,
            localUnloader: RuntimeLocalUnloader(order: RuntimeRouteOrder())
        )
        defer { secondHarness.cleanup() }
        let secondPrepared = try await secondHarness.runtime.prepareSession(
            context: .init(
                preparationID: "preparation-interrupted",
                proposedRunID: "run-interrupted",
                initialTurn: secondHarness.initialTurn,
                signedToolDisplayKeys: []
            ),
            hostConfiguration: secondHarness.hostConfiguration,
            target: secondHarness.target
        )
        do {
            _ = try await collect(try await secondHarness.runtime.startGeneration(
                sessionID: secondPrepared.sessionID,
                turn: secondHarness.initialTurn
            ))
            Issue.record("expected interrupted stream failure")
        } catch let failure as LLMFailure {
            #expect(failure.code == "test.retryable_interruption")
        }
        #expect(await interrupted.requestCount == 1)
        #expect(await secondHarness.runtime.state == .terminal)
        try await secondHarness.runtime.closeSession(sessionID: secondPrepared.sessionID)
    }

    @Test
    func cancelAndCloseReachTheProviderSessionExactlyOnce() async throws {
        let providerSession = RuntimeSpyProviderSession()
        let registry = try CloudProviderAdapterRegistry(adapters: [
            RuntimeSpyAdapter(session: providerSession),
        ])
        let harness = try await CloudRuntimeHarness.make(
            generationTransport: RuntimeGenerationTransport(scripts: [[]]),
            localUnloader: RuntimeLocalUnloader(order: RuntimeRouteOrder()),
            adapters: registry
        )
        defer { harness.cleanup() }
        let prepared = try await harness.runtime.prepareSession(
            context: .init(
                preparationID: "preparation-cancel",
                proposedRunID: "run-cancel",
                initialTurn: harness.initialTurn,
                signedToolDisplayKeys: []
            ),
            hostConfiguration: harness.hostConfiguration,
            target: harness.target
        )
        let stream = try await harness.runtime.startGeneration(
            sessionID: prepared.sessionID,
            turn: harness.initialTurn
        )
        for _ in 0..<1_000 where providerSession.decodeCount == 0 {
            await Task.yield()
        }
        #expect(providerSession.decodeCount == 1)

        try await harness.runtime.cancel(sessionID: prepared.sessionID)
        try await harness.runtime.cancel(sessionID: prepared.sessionID)
        let events = try await collect(stream)
        #expect(events.contains(.cancelled))
        #expect(providerSession.cancelCount == 1)
        #expect(await harness.runtime.state == .terminal)

        try await harness.runtime.closeSession(sessionID: prepared.sessionID)
        try await harness.runtime.closeSession(sessionID: prepared.sessionID)
        #expect(providerSession.closeCount == 1)
    }

    @Test
    func outerBufferOverflowFailsInsteadOfDroppingTerminal() async throws {
        let providerSession = RuntimeSpyProviderSession(scriptedEvents:
            (0..<40).map { .textDelta("chunk-\($0)") } + [
                .generationCompleted(.init(
                    outcome: .finalResponse,
                    orderedCallIDs: [],
                    finishReason: .stop
                )),
            ]
        )
        let harness = try await CloudRuntimeHarness.make(
            generationTransport: RuntimeGenerationTransport(scripts: [[]]),
            localUnloader: RuntimeLocalUnloader(order: RuntimeRouteOrder()),
            adapters: try CloudProviderAdapterRegistry(adapters: [
                RuntimeSpyAdapter(session: providerSession),
            ])
        )
        defer { harness.cleanup() }
        let prepared = try await harness.runtime.prepareSession(
            context: .init(
                preparationID: "preparation-overflow",
                proposedRunID: "run-overflow",
                initialTurn: harness.initialTurn,
                signedToolDisplayKeys: []
            ),
            hostConfiguration: harness.hostConfiguration,
            target: harness.target
        )

        let stream = try await harness.runtime.startGeneration(
            sessionID: prepared.sessionID,
            turn: harness.initialTurn
        )
        for _ in 0..<1_000 where await harness.runtime.state != .terminal {
            await Task.yield()
        }

        await expectRuntimeFailure("runtime.cloud_consumer_backpressure") {
            _ = try await collect(stream)
        }
        #expect(await harness.runtime.state == .terminal)
        try await harness.runtime.closeSession(sessionID: prepared.sessionID)
    }

    @Test
    func consumerTerminationCancelsProviderExactlyOnce() async throws {
        let providerSession = RuntimeSpyProviderSession()
        let harness = try await CloudRuntimeHarness.make(
            generationTransport: RuntimeGenerationTransport(scripts: [[]]),
            localUnloader: RuntimeLocalUnloader(order: RuntimeRouteOrder()),
            adapters: try CloudProviderAdapterRegistry(adapters: [
                RuntimeSpyAdapter(session: providerSession),
            ])
        )
        defer { harness.cleanup() }
        let prepared = try await harness.runtime.prepareSession(
            context: .init(
                preparationID: "preparation-consumer-cancel",
                proposedRunID: "run-consumer-cancel",
                initialTurn: harness.initialTurn,
                signedToolDisplayKeys: []
            ),
            hostConfiguration: harness.hostConfiguration,
            target: harness.target
        )
        let stream = try await harness.runtime.startGeneration(
            sessionID: prepared.sessionID,
            turn: harness.initialTurn
        )
        let consumer = Task { try await collect(stream) }
        for _ in 0..<1_000 where providerSession.decodeCount == 0 {
            await Task.yield()
        }

        consumer.cancel()
        _ = await consumer.result
        for _ in 0..<1_000 where providerSession.cancelCount == 0 {
            await Task.yield()
        }

        #expect(providerSession.cancelCount == 1)
        #expect(await harness.runtime.state == .terminal)
        try await harness.runtime.closeSession(sessionID: prepared.sessionID)
        #expect(providerSession.closeCount == 1)
    }

    @Test
    func consumerTerminationAndExplicitCancelShareOneProviderCancel() async throws {
        let providerSession = RuntimeSpyProviderSession()
        let harness = try await CloudRuntimeHarness.make(
            generationTransport: RuntimeGenerationTransport(scripts: [[]]),
            localUnloader: RuntimeLocalUnloader(order: RuntimeRouteOrder()),
            adapters: try CloudProviderAdapterRegistry(adapters: [
                RuntimeSpyAdapter(session: providerSession),
            ])
        )
        defer { harness.cleanup() }
        let prepared = try await harness.runtime.prepareSession(
            context: .init(
                preparationID: "preparation-cancel-race",
                proposedRunID: "run-cancel-race",
                initialTurn: harness.initialTurn,
                signedToolDisplayKeys: []
            ),
            hostConfiguration: harness.hostConfiguration,
            target: harness.target
        )
        let stream = try await harness.runtime.startGeneration(
            sessionID: prepared.sessionID,
            turn: harness.initialTurn
        )
        let consumer = Task { try await collect(stream) }
        for _ in 0..<1_000 where providerSession.decodeCount == 0 {
            await Task.yield()
        }

        consumer.cancel()
        try await harness.runtime.cancel(sessionID: prepared.sessionID)
        _ = await consumer.result

        #expect(providerSession.cancelCount == 1)
        try await harness.runtime.closeSession(sessionID: prepared.sessionID)
        #expect(providerSession.closeCount == 1)
    }

    @Test
    func normalCompletionDoesNotCancelProvider() async throws {
        let providerSession = RuntimeSpyProviderSession(scriptedEvents: [
            .textDelta("done"),
            .generationCompleted(.init(
                outcome: .finalResponse,
                orderedCallIDs: [],
                finishReason: .stop
            )),
        ])
        let harness = try await CloudRuntimeHarness.make(
            generationTransport: RuntimeGenerationTransport(scripts: [[]]),
            localUnloader: RuntimeLocalUnloader(order: RuntimeRouteOrder()),
            adapters: try CloudProviderAdapterRegistry(adapters: [
                RuntimeSpyAdapter(session: providerSession),
            ])
        )
        defer { harness.cleanup() }
        let prepared = try await harness.runtime.prepareSession(
            context: .init(
                preparationID: "preparation-normal-terminal",
                proposedRunID: "run-normal-terminal",
                initialTurn: harness.initialTurn,
                signedToolDisplayKeys: []
            ),
            hostConfiguration: harness.hostConfiguration,
            target: harness.target
        )

        let events = try await collect(try await harness.runtime.startGeneration(
            sessionID: prepared.sessionID,
            turn: harness.initialTurn
        ))

        #expect(events.last == .generationCompleted(.init(
            outcome: .finalResponse,
            orderedCallIDs: [],
            finishReason: .stop
        )))
        #expect(providerSession.cancelCount == 0)
        try await harness.runtime.closeSession(sessionID: prepared.sessionID)
        #expect(providerSession.closeCount == 1)
    }

    @Test
    func generationRechecksCredentialSlotAndRetentionIdentityBeforeTransport() async throws {
        let transport = RuntimeGenerationTransport(scripts: [runtimeFinalEvents()])
        let harness = try await CloudRuntimeHarness.make(
            generationTransport: transport,
            localUnloader: RuntimeLocalUnloader(order: RuntimeRouteOrder())
        )
        defer { harness.cleanup() }
        let prepared = try await harness.runtime.prepareSession(
            context: .init(
                preparationID: "preparation-recheck",
                proposedRunID: "run-recheck",
                initialTurn: harness.initialTurn,
                signedToolDisplayKeys: []
            ),
            hostConfiguration: harness.hostConfiguration,
            target: harness.target
        )
        try await harness.credentials.replaceSlotLifecycleForTesting(
            credentialRef: prepared.credentialRef,
            lifecycle: .rotating(
                operationID: "test-rotation",
                expectedGeneration: 1,
                nextGeneration: 2
            )
        )
        await expectRuntimeFailure("provider_validation.current_unavailable") {
            _ = try await harness.runtime.startGeneration(
                sessionID: prepared.sessionID,
                turn: harness.initialTurn
            )
        }
        try await harness.credentials.replaceSlotLifecycleForTesting(
            credentialRef: prepared.credentialRef,
            lifecycle: .active
        )
        let state = try #require(await harness.profiles.state(
            profileID: prepared.providerProfileID,
            profileRevision: prepared.providerProfileRevision
        ))
        _ = try await harness.profiles.updateState(
            profileID: prepared.providerProfileID,
            profileRevision: prepared.providerProfileRevision,
            expectedStateRevision: state.stateRevision
        ) { value in
            value.retentionApprovalRevision = 1
            value.retentionApprovalDigest = String(repeating: "c", count: 64)
        }
        await expectRuntimeFailure("runtime.cloud_route_changed") {
            _ = try await harness.runtime.startGeneration(
                sessionID: prepared.sessionID,
                turn: harness.initialTurn
            )
        }
        #expect(await transport.requests.isEmpty)
        try await harness.runtime.closeSession(sessionID: prepared.sessionID)
    }

    @Test
    func newProcessEpochInterruptsPersistedSessionAndLeaseBeforeReuse() async throws {
        let harness = try await CloudRuntimeHarness.make(
            generationTransport: RuntimeGenerationTransport(scripts: []),
            localUnloader: RuntimeLocalUnloader(order: RuntimeRouteOrder())
        )
        defer { harness.cleanup() }
        let prepared = try await harness.runtime.prepareSession(
            context: .init(
                preparationID: "preparation-old-epoch",
                proposedRunID: "run-old-epoch",
                initialTurn: harness.initialTurn,
                signedToolDisplayKeys: []
            ),
            hostConfiguration: harness.hostConfiguration,
            target: harness.target
        )

        let reopened = try PreparedCloudSessionStore(fileURL: harness.databaseURL)
        #expect(try reopened.recoverOldEpoch(try HostProcessEpoch.generate()) == 1)
        #expect(try reopened.tombstone(prepared.sessionID)?.disposition == .epochEnded)
        #expect(try await harness.credentials.lease(prepared.credentialUseLeaseID) == nil)
    }
}

private final class EmptyCloudAttachmentResolver: CloudAttachmentIdentityResolving, @unchecked Sendable {
    private(set) var calls = 0

    func resolveIdentities(
        for input: AgentLLMInput,
        sourceRevisionDocument: CanonicalJSONValue
    ) throws -> [CloudResolvedAttachmentIdentity] {
        calls += 1
        return []
    }
}

private struct CloudRuntimeHarness: Sendable {
    let directory: URL
    let databaseURL: URL
    let profiles: ProviderProfileStore
    let credentials: ProviderCredentialStore
    let sessionStore: PreparedCloudSessionStore
    let runtime: CloudLLMRuntime
    let hostConfiguration: AgentHostConfiguration
    let target: LLMTargetRevision
    let initialTurn: CloudGenerationTurnRequest
    let resolvedParameters: GenerationConfiguration

    static func make(
        generationTransport: any CloudHTTPTransport,
        localUnloader: any LocalRouteUnloading,
        adapters: CloudProviderAdapterRegistry? = nil,
        modelID: String = "fixture-model",
        retentionMode: ProviderRetentionMode = .statelessRequired,
        targetDefaults: GenerationConfiguration = GenerationConfiguration(),
        hostOverrides: GenerationConfiguration = GenerationConfiguration(),
        toolSchema: CanonicalJSONValue? = nil
    ) async throws -> Self {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cloud-runtime-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let databaseURL = directory.appendingPathComponent("llm-state.sqlite")
        let profiles = try ProviderProfileStore(
            fileURL: databaseURL,
            originValidator: RuntimeOriginValidator()
        )
        let catalogFixture = try signedCloudCatalog(
            revision: 1,
            continuationModes: retentionMode == .providerStateApproved
                ? [.statelessRequired, .providerStateApproved]
                : [.statelessRequired]
        )
        let catalog = try CloudCapabilityCatalogStore(
            fileURL: databaseURL,
            trustedKeyRing: catalogFixture.keyRing
        )
        _ = try await catalog.accept(envelope: catalogFixture.envelope)
        let credentials = try ProviderCredentialStore(
            fileURL: databaseURL,
            vault: RuntimeCredentialVault()
        )
        try await credentials.createSlot(
            credentialRef: "credential-main",
            initialSecret: SecretBytes(utf8: "runtime-test-key"),
            operationID: "create-runtime-key"
        )
        _ = try await profiles.publish(ProviderProfileRevision(
            profileID: "profile-main",
            revision: 1,
            presetID: .openAI,
            displayName: "Runtime fixture provider",
            baseURL: URL(string: "https://api.example.com/v1")!,
            credentialRef: "credential-main",
            retentionMode: retentionMode
        ))
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let prompt = RuntimeApprovalPrompt()
        let retention = try ProviderRetentionPolicy(fileURL: databaseURL, prompt: prompt)
        if retentionMode == .providerStateApproved {
            _ = try await retention.approveProviderState(
                profileID: "profile-main",
                profileRevision: 1,
                disclosure: ProviderRetentionDisclosure(
                    behavior: .serverSideConversationState,
                    windowClass: .thirtyOneToSixtyDays
                )
            )
        }
        let egress = try ProviderEgressPolicy(
            fileURL: databaseURL,
            credentialStore: credentials,
            retentionPolicy: retention,
            prompt: prompt,
            clock: { now },
            idGenerator: { UUID().uuidString.lowercased() }
        )
        let epoch = try HostProcessEpoch.generate()
        let validation = try ProviderValidationService(
            fileURL: databaseURL,
            profileStore: profiles,
            catalogStore: catalog,
            credentialStore: credentials,
            egressPolicy: egress,
            transport: RuntimeValidationTransport(),
            hostProcessEpoch: epoch,
            clock: { now },
            idGenerator: { "runtime-validation" }
        )
        _ = try await validation.validate(
            profileID: "profile-main",
            profileRevision: 1,
            modelID: modelID,
            adapterVersion: "1"
        )
        let target = LLMTargetRevision(
            targetID: LLMTargetID(rawValue: "target-cloud"),
            revision: 1,
            kind: .cloud(providerProfileID: "profile-main", providerProfileRevision: 1),
            modelID: modelID,
            defaultParameters: targetDefaults
        )
        try await profiles.publishTarget(target)
        let hostConfiguration = AgentHostConfiguration(
            bindingID: "binding-cloud",
            revision: 1,
            agentProfileID: "agent-profile",
            agentProfileRevision: 1,
            llmSlotID: "assistant",
            requirementsHash: String(repeating: "b", count: 64),
            llmTargetID: target.targetID,
            llmTargetRevision: target.revision,
            parameterOverrides: hostOverrides
        )
        let bindingStore = try LLMStore(fileURL: databaseURL)
        let bindingSaga = AgentHostBindingSaga(store: bindingStore)
        let receipt = try await bindingSaga.stageHostBinding(HostBindingStageRequest(
            operationToken: "runtime-binding-token",
            tokenDigest: "runtime-binding-token-digest",
            llmSlotID: hostConfiguration.llmSlotID,
            requirementsHash: hostConfiguration.requirementsHash,
            configuration: hostConfiguration
        ))
        try await bindingSaga.activateHostBinding(
            operationToken: "runtime-binding-token",
            binding: receipt.binding
        )
        let verifiedCatalog = try #require(try await catalog.current())
        let resolved: ResolvedCloudGenerationConfiguration
        if let entry = verifiedCatalog.entry(presetID: .openAI, modelID: target.modelID) {
            resolved = try CloudGenerationConfigurationResolver.resolve(
                entry: entry,
                targetDefaults: targetDefaults,
                hostOverrides: hostOverrides
            )
        } else {
            resolved = try CloudGenerationConfigurationResolver.resolveManual(
                adapterID: "openai.responses",
                modelID: target.modelID
            )
        }
        let initialTurn = try runtimeTurn(
            resolvedParameters: resolved.semantic,
            generationTurnID: "turn-1",
            inputID: "input-1",
            text: "hello",
            semanticHistory: .array([]),
            toolResults: [],
            dataClasses: [.text],
            sensitivity: .routine,
            sourceKinds: [.conversation],
            triggeringToolDisplayKeys: [],
            toolSchema: toolSchema
        )
        let sessionStore = try PreparedCloudSessionStore(fileURL: databaseURL)
        let runtime = CloudLLMRuntime(
            profileStore: profiles,
            catalogStore: catalog,
            credentialStore: credentials,
            validationService: validation,
            egressPolicy: egress,
            sessionStore: sessionStore,
            bindingSaga: bindingSaga,
            attachmentResolver: EmptyCloudAttachmentResolver(),
            transport: generationTransport,
            localUnloader: localUnloader,
            adapters: try adapters ?? .shipped(),
            hostProcessEpoch: epoch,
            clock: { now }
        )
        return Self(
            directory: directory,
            databaseURL: databaseURL,
            profiles: profiles,
            credentials: credentials,
            sessionStore: sessionStore,
            runtime: runtime,
            hostConfiguration: hostConfiguration,
            target: target,
            initialTurn: initialTurn,
            resolvedParameters: resolved.semantic
        )
    }

    func cleanup() { try? FileManager.default.removeItem(at: directory) }
}

private struct RuntimeSpyAdapter: CloudProviderAdapter {
    let session: RuntimeSpyProviderSession
    let presetID: ProviderPresetID = .openAI
    let adapterID = "openai.responses"
    let adapterVersion = "1"

    func makeDiscoveryRequest() throws -> CloudWireRequest {
        try OpenAIResponsesAdapter().makeDiscoveryRequest()
    }

    func makeAccountValidationRequest() throws -> CloudWireRequest {
        try OpenAIResponsesAdapter().makeAccountValidationRequest()
    }

    func makeModelValidationRequest(modelID: String) throws -> CloudWireRequest {
        try OpenAIResponsesAdapter().makeModelValidationRequest(modelID: modelID)
    }

    func makeSession(
        _ context: CloudProviderSessionContext
    ) throws -> any CloudProviderSession {
        session
    }
}

private final class RuntimeSpyProviderSession: CloudProviderSession, @unchecked Sendable {
    private let lock = NSLock()
    private let scriptedEvents: [LLMBackendEvent]?
    private var continuation: LLMBackendEventStream.Continuation?
    private var storedDecodeCount = 0
    private var storedCancelCount = 0
    private var storedCloseCount = 0

    init(scriptedEvents: [LLMBackendEvent]? = nil) {
        self.scriptedEvents = scriptedEvents
    }

    var decodeCount: Int { lock.withLock { storedDecodeCount } }
    var cancelCount: Int { lock.withLock { storedCancelCount } }
    var closeCount: Int { lock.withLock { storedCloseCount } }

    func encodeStart(_ turn: AuthorizedCloudGenerationTurn) throws -> CloudWireRequest {
        try wire()
    }

    func encodeResume(_ turn: AuthorizedCloudGenerationTurn) throws -> CloudWireRequest {
        try wire()
    }

    func decode(
        _ events: AsyncThrowingStream<SSEEvent, Error>
    ) -> LLMBackendEventStream {
        if let scriptedEvents {
            let pair = LLMBackendEventStream.makeStream(bufferingPolicy: .unbounded)
            lock.withLock { storedDecodeCount += 1 }
            for event in scriptedEvents { pair.continuation.yield(event) }
            pair.continuation.finish()
            return pair.stream
        }
        let pair = LLMBackendEventStream.makeStream(bufferingPolicy: .bufferingOldest(2))
        lock.withLock {
            storedDecodeCount += 1
            continuation = pair.continuation
        }
        return pair.stream
    }

    func cancel() async {
        let output = lock.withLock { () -> LLMBackendEventStream.Continuation? in
            storedCancelCount += 1
            let output = continuation
            continuation = nil
            return output
        }
        _ = output?.yield(.cancelled)
        output?.finish()
    }

    func close() async {
        let output = lock.withLock { () -> LLMBackendEventStream.Continuation? in
            storedCloseCount += 1
            let output = continuation
            continuation = nil
            return output
        }
        output?.finish()
    }

    private func wire() throws -> CloudWireRequest {
        try CloudWireRequest(
            method: "POST",
            path: "/responses",
            queryItems: [],
            headers: ["content-type": "application/json"],
            body: Data(#"{"stream":true}"#.utf8),
            dataProvenance: .generation
        )
    }
}

actor RuntimeRouteOrder {
    private(set) var unloadCount = 0
    private(set) var transportCount = 0
    private(set) var transportBeforeUnload = 0

    func unloaded() { unloadCount += 1 }
    func transported() {
        transportCount += 1
        if unloadCount == 0 { transportBeforeUnload += 1 }
    }
}

struct RuntimeLocalUnloader: LocalRouteUnloading {
    let order: RuntimeRouteOrder
    func unloadForCloudRouteSwitch() async throws { await order.unloaded() }
}

private actor RuntimeGenerationTransport: CloudHTTPTransport {
    private var scripts: [[SSEEvent]]
    private(set) var requests: [AuthorizedCloudHTTPRequest] = []
    private let order: RuntimeRouteOrder?

    init(scripts: [[SSEEvent]], order: RuntimeRouteOrder? = nil) {
        self.scripts = scripts
        self.order = order
    }

    func stream(
        _ request: AuthorizedCloudHTTPRequest
    ) async throws -> AsyncThrowingStream<SSEEvent, Error> {
        requests.append(request)
        await order?.transported()
        guard !scripts.isEmpty else {
            throw LLMFailure(code: "test.transport_exhausted", message: "no script", retryable: false)
        }
        let events = scripts.removeFirst()
        return AsyncThrowingStream { continuation in
            for event in events { continuation.yield(event) }
            continuation.finish()
        }
    }

    func json(_ request: AuthorizedCloudHTTPRequest) async throws -> Data {
        throw LLMFailure(code: "test.json_forbidden", message: "generation used JSON", retryable: false)
    }
}

private enum RuntimeFaultStep: Sendable {
    case failBeforeStream
    case events([SSEEvent])
    case eventsThenFail([SSEEvent])
}

private actor RuntimeFaultTransport: CloudHTTPTransport {
    private var steps: [RuntimeFaultStep]
    private(set) var requestCount = 0

    init(steps: [RuntimeFaultStep]) { self.steps = steps }

    func stream(
        _ request: AuthorizedCloudHTTPRequest
    ) async throws -> AsyncThrowingStream<SSEEvent, Error> {
        requestCount += 1
        guard !steps.isEmpty else {
            throw LLMFailure(code: "test.exhausted", message: "exhausted", retryable: false)
        }
        switch steps.removeFirst() {
        case .failBeforeStream:
            throw LLMFailure(
                code: "test.retryable_connect",
                message: "retryable connect failure",
                retryable: true,
                recoveryAction: .retry
            )
        case let .events(events):
            return AsyncThrowingStream { continuation in
                for event in events { continuation.yield(event) }
                continuation.finish()
            }
        case let .eventsThenFail(events):
            return AsyncThrowingStream { continuation in
                for event in events { continuation.yield(event) }
                continuation.finish(throwing: LLMFailure(
                    code: "test.retryable_interruption",
                    message: "retryable interruption",
                    retryable: true,
                    recoveryAction: .retry
                ))
            }
        }
    }

    func json(_ request: AuthorizedCloudHTTPRequest) async throws -> Data {
        throw LLMFailure(code: "test.json_forbidden", message: "forbidden", retryable: false)
    }
}

private actor RuntimeValidationTransport: CloudHTTPTransport {
    func json(_ request: AuthorizedCloudHTTPRequest) async throws -> Data {
        Data(#"{"data":[{"id":"fixture-model"}]}"#.utf8)
    }

    func stream(
        _ request: AuthorizedCloudHTTPRequest
    ) async throws -> AsyncThrowingStream<SSEEvent, Error> {
        AsyncThrowingStream { continuation in
            for event in runtimeFinalEvents(text: "OK", responseID: "validation-response") {
                continuation.yield(event)
            }
            continuation.finish()
        }
    }
}

actor RuntimeApprovalPrompt: CloudLLMApprovalPrompting {
    func requestOriginApproval(_ origin: EgressOrigin, profileName: String) async -> EgressDecision { .allow }
    func requestScopeApproval(origin: EgressOrigin, summary: EgressApprovalDisplaySummary) async -> EgressDecision { .allow }
    func requestProviderStateApproval(
        profileName: String,
        origin: EgressOrigin,
        disclosure: ProviderRetentionDisclosure
    ) async -> EgressDecision { .allow }
}

struct RuntimeOriginValidator: ProviderOriginValidating {
    func validate(_ baseURL: URL) async throws -> EgressOrigin {
        EgressOrigin(scheme: "https", host: baseURL.host ?? "invalid", port: 443)
    }
}

actor RuntimeCredentialVault: CredentialVault {
    private var values: [String: Data] = [:]

    func writeStaged(
        credentialRef: String,
        generation: UInt64,
        operationID: String,
        secret: SecretBytes
    ) async throws {
        values[CredentialVaultAccount.staged(
            credentialRef: credentialRef,
            generation: generation,
            operationID: operationID
        )] = secret.dataCopyForVault()
    }

    func promoteStaged(credentialRef: String, generation: UInt64, operationID: String) async throws {
        let staged = CredentialVaultAccount.staged(
            credentialRef: credentialRef,
            generation: generation,
            operationID: operationID
        )
        values[CredentialVaultAccount.final(
            credentialRef: credentialRef,
            generation: generation
        )] = values.removeValue(forKey: staged)
    }

    func finalExists(credentialRef: String, generation: UInt64) async throws -> Bool {
        values[CredentialVaultAccount.final(
            credentialRef: credentialRef,
            generation: generation
        )] != nil
    }

    func loadFinal(credentialRef: String, generation: UInt64) async throws -> SecretBytes {
        guard let data = values[CredentialVaultAccount.final(
            credentialRef: credentialRef,
            generation: generation
        )] else { throw CredentialFailure(code: "credential.missing", message: "missing") }
        return SecretBytes(bytes: data)
    }

    func deleteStaged(credentialRef: String, generation: UInt64, operationID: String) async throws {
        values.removeValue(forKey: CredentialVaultAccount.staged(
            credentialRef: credentialRef,
            generation: generation,
            operationID: operationID
        ))
    }

    func deleteFinal(credentialRef: String, generation: UInt64) async throws {
        values.removeValue(forKey: CredentialVaultAccount.final(
            credentialRef: credentialRef,
            generation: generation
        ))
    }
}

func runtimeTurn(
    resolvedParameters: GenerationConfiguration,
    generationTurnID: String,
    inputID: String,
    text: String,
    semanticHistory: CanonicalJSONValue,
    toolResults: [NormalizedToolResult],
    dataClasses: Set<EgressDataClass>,
    sensitivity: DataSensitivity,
    sourceKinds: Set<EgressSourceKind>,
    triggeringToolDisplayKeys: Set<String>,
    toolSchema requestedToolSchema: CanonicalJSONValue? = nil
) throws -> CloudGenerationTurnRequest {
    let input = AgentLLMInput(
        inputID: inputID,
        messages: [.init(role: .user, content: [.text(text)])]
    )
    let defaultToolSchema = try CanonicalJSONValue.object(entries: [
        .init(name: "tools", value: .array([.string("contacts.search")])),
    ])
    let toolSchema = requestedToolSchema ?? defaultToolSchema
    let sourceDocument = try CanonicalJSONValue.object(entries: [])
    let placeholder = GenerationDisclosure(
        schemaVersion: "1",
        generationTurnID: generationTurnID,
        contentDigest: String(repeating: "0", count: 64),
        sourceRevisionDigest: String(repeating: "0", count: 64),
        dataClasses: dataClasses,
        highestSensitivity: sensitivity,
        safeDisplaySummary: SafeDisplaySummary(
            sourceKinds: sourceKinds,
            addedItemCounts: dataClasses.sorted(by: { $0.rawValue < $1.rawValue }).map {
                .init(dataClass: $0, count: 1)
            },
            approximateAddedSize: .lessThanOneKiB,
            triggeringToolDisplayKeys: triggeringToolDisplayKeys
        )
    )
    let candidate = CloudGenerationTurnCandidate(
        input: input,
        canonicalToolSchema: toolSchema,
        sourceRevisionDocument: sourceDocument,
        resolvedAttachments: [],
        toolResults: toolResults,
        providerRequiredSemanticHistory: semanticHistory,
        disclosure: placeholder,
        resolvedParameters: resolvedParameters
    )
    let disclosure = GenerationDisclosure(
        schemaVersion: "1",
        generationTurnID: generationTurnID,
        contentDigest: try CanonicalDigestV1.digest(
            domain: "agent-input:v1",
            document: try runtimeSemanticDocument(candidate)
        ).hex,
        sourceRevisionDigest: try CanonicalDigestV1.digest(
            domain: "source-revisions:v1",
            document: try runtimeSourceDocument(candidate)
        ).hex,
        dataClasses: dataClasses,
        highestSensitivity: sensitivity,
        safeDisplaySummary: placeholder.safeDisplaySummary
    )
    return CloudGenerationTurnRequest(
        input: input,
        canonicalToolSchema: toolSchema,
        sourceRevisionDocument: sourceDocument,
        toolResults: toolResults,
        providerRequiredSemanticHistory: semanticHistory,
        disclosure: disclosure,
        resolvedParameters: resolvedParameters
    )
}

private func runtimeSemanticDocument(
    _ candidate: CloudGenerationTurnCandidate
) throws -> CanonicalJSONValue {
    try .object(entries: [
        .init(name: "canonical_tool_schema", value: candidate.canonicalToolSchema),
        .init(name: "input_id", value: .string(candidate.input.inputID)),
        .init(name: "messages", value: .array(try candidate.input.messages.map { message in
            try .object(entries: [
                .init(name: "content", value: .array(try message.content.map { content in
                    guard case let .text(text) = content else {
                        throw LLMFailure(code: "test.attachment_unexpected", message: "attachment", retryable: false)
                    }
                    return try .object(entries: [
                        .init(name: "text", value: .string(text)),
                        .init(name: "type", value: .string("text")),
                    ])
                })),
                .init(name: "role", value: .string(message.role.rawValue)),
            ])
        })),
        .init(name: "provider_required_semantic_history", value: candidate.providerRequiredSemanticHistory),
        .init(name: "resolved_attachments", value: .array([])),
        .init(name: "schema_version", value: .string("1")),
        .init(name: "tool_results", value: .array(try candidate.toolResults.map { result in
            try .object(entries: [
                .init(name: "call_id", value: .string(result.callID)),
                .init(name: "data_classes", value: .array(
                    result.dataClasses.map(\.rawValue).sorted().map(CanonicalJSONValue.string)
                )),
                .init(name: "highest_sensitivity", value: .string(result.highestSensitivity.rawValue)),
                .init(name: "is_error", value: .bool(result.isError)),
                .init(name: "result", value: result.result),
                .init(name: "tool_name", value: .string(result.toolName)),
            ])
        })),
    ])
}

private func runtimeSourceDocument(
    _ candidate: CloudGenerationTurnCandidate
) throws -> CanonicalJSONValue {
    try .object(entries: [
        .init(name: "resolved_attachments", value: .array([])),
        .init(name: "schema_version", value: .string("1")),
        .init(name: "source_revision_document", value: candidate.sourceRevisionDocument),
    ])
}

func runtimeToolBatchEvents() -> [SSEEvent] {
    [
        runtimeSSE("response.created", #"{"response":{"id":"response-tools","status":"in_progress"}}"#),
        runtimeSSE("response.output_text.delta", #"{"delta":"I will check. "}"#),
        runtimeSSE("response.output_item.added", #"{"item":{"id":"item-1","type":"function_call","call_id":"call-1","name":"contacts.search","arguments":"{}"}}"#),
        runtimeSSE("response.output_item.done", #"{"item":{"id":"item-1","type":"function_call","call_id":"call-1","name":"contacts.search","arguments":"{}"}}"#),
        runtimeSSE("response.completed", #"{"response":{"id":"response-tools","status":"completed","usage":{"input_tokens":9,"output_tokens":3}}}"#),
    ]
}

func runtimeFinalEvents(
    text: String = "Done",
    responseID: String = "response-final"
) -> [SSEEvent] {
    [
        runtimeSSE("response.created", "{\"response\":{\"id\":\"\(responseID)\",\"status\":\"in_progress\"}}"),
        runtimeSSE("response.output_text.delta", "{\"delta\":\"\(text)\"}"),
        runtimeSSE("response.completed", "{\"response\":{\"id\":\"\(responseID)\",\"status\":\"completed\",\"usage\":{\"input_tokens\":4,\"output_tokens\":1}}}"),
    ]
}

private func runtimeSSE(_ event: String, _ json: String) -> SSEEvent {
    SSEEvent(event: event, id: nil, retryMilliseconds: nil, data: Data(json.utf8))
}

func collect(_ stream: LLMBackendEventStream) async throws -> [LLMBackendEvent] {
    var result: [LLMBackendEvent] = []
    for try await event in stream { result.append(event) }
    return result
}

private func expectRuntimeFailure(
    _ code: String,
    operation: () async throws -> Void
) async {
    do {
        try await operation()
        Issue.record("expected runtime failure \(code)")
    } catch let failure as LLMFailure {
        #expect(failure.code == code)
    } catch {
        Issue.record("unexpected error: \(error)")
    }
}

private extension CloudGenerationTurnRequest {
    func replacing(
        input: AgentLLMInput? = nil,
        toolSchema: CanonicalJSONValue? = nil,
        sourceDocument: CanonicalJSONValue? = nil,
        toolResults: [NormalizedToolResult]? = nil,
        semanticHistory: CanonicalJSONValue? = nil
    ) -> Self {
        Self(
            input: input ?? self.input,
            canonicalToolSchema: toolSchema ?? canonicalToolSchema,
            sourceRevisionDocument: sourceDocument ?? sourceRevisionDocument,
            toolResults: toolResults ?? self.toolResults,
            providerRequiredSemanticHistory: semanticHistory ?? providerRequiredSemanticHistory,
            disclosure: disclosure,
            resolvedParameters: resolvedParameters
        )
    }
}
