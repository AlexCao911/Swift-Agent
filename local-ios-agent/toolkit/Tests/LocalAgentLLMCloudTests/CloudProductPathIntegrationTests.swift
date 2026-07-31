import Foundation
import LocalAgentLLMContracts
@testable import LocalAgentLLMCore
import Testing
@testable import LocalAgentLLMCloud

@Suite("Cloud product path integration", .serialized)
struct CloudProductPathIntegrationTests {
    @Test
    func presetOrCredentialModeTransitionRequiresANewCredential() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cloud-credential-transition-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let catalogFixture = try signedCloudCatalog(revision: 1)
        let subsystem = try await CloudLLMSubsystem.bootstrap(
            appSupportRoot: directory,
            hostProcessEpoch: try HostProcessEpoch.generate(),
            bundledCatalog: catalogFixture.envelope,
            trustedKeyRing: catalogFixture.keyRing,
            remoteCatalog: nil,
            vault: RuntimeCredentialVault(),
            approvalPrompt: RuntimeApprovalPrompt(),
            transportFactory: { _ in SubsystemFixtureTransport(toolLoop: false) },
            localUnloader: RuntimeLocalUnloader(order: RuntimeRouteOrder()),
            originValidator: RuntimeOriginValidator()
        )
        _ = try await subsystem.publishProviderProfileRevision(
            profileID: "profile",
            replacingRevision: nil,
            presetID: .openAI,
            displayName: "Provider",
            baseURL: URL(string: "https://chatgpt.com/backend-api/codex")!,
            retentionMode: .statelessRequired,
            credentialMode: .apiKey,
            initialSecret: SecretBytes(utf8: "openai-key")
        )

        for (presetID, mode, baseURL) in [
            (
                ProviderPresetID.anthropic,
                ProviderCredentialMode.apiKey,
                URL(string: "https://proxy.example/v1")!
            ),
            (
                ProviderPresetID.openAI,
                ProviderCredentialMode.oauth,
                URL(string: "https://chatgpt.com/backend-api/codex")!
            ),
        ] {
            await #expect(throws: CredentialFailure.self) {
                _ = try await subsystem.publishProviderProfileRevision(
                    profileID: "profile",
                    replacingRevision: 1,
                    presetID: presetID,
                    displayName: "Provider",
                    baseURL: baseURL,
                    retentionMode: .statelessRequired,
                    credentialMode: mode,
                    initialSecret: nil
                )
            }
        }

        _ = try await subsystem.publishProviderProfileRevision(
            profileID: "oauth-profile",
            replacingRevision: nil,
            presetID: .anthropic,
            displayName: "OAuth Provider",
            baseURL: URL(string: "https://api.anthropic.com/v1")!,
            retentionMode: .statelessRequired,
            credentialMode: .oauth,
            initialSecret: try OAuthTokenCredential(
                accessToken: "anthropic-access",
                refreshToken: "anthropic-refresh",
                expiresAt: Date.distantFuture
            ).secureSecret()
        )
        await #expect(throws: CredentialFailure.self) {
            _ = try await subsystem.publishProviderProfileRevision(
                profileID: "oauth-profile",
                replacingRevision: 1,
                presetID: .anthropic,
                displayName: "OAuth Provider",
                baseURL: URL(string: "https://proxy.example/v1")!,
                retentionMode: .statelessRequired,
                credentialMode: .apiKey,
                initialSecret: nil
            )
        }
    }

    @Test
    func oauthProfilePublicationRejectsASubstitutedProviderOrigin() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cloud-oauth-origin-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let catalogFixture = try signedCloudCatalog(revision: 1)
        let subsystem = try await CloudLLMSubsystem.bootstrap(
            appSupportRoot: directory,
            hostProcessEpoch: try HostProcessEpoch.generate(),
            bundledCatalog: catalogFixture.envelope,
            trustedKeyRing: catalogFixture.keyRing,
            remoteCatalog: nil,
            vault: RuntimeCredentialVault(),
            approvalPrompt: RuntimeApprovalPrompt(),
            transportFactory: { _ in SubsystemFixtureTransport(toolLoop: false) },
            localUnloader: RuntimeLocalUnloader(order: RuntimeRouteOrder()),
            originValidator: RuntimeOriginValidator()
        )

        do {
            _ = try await subsystem.publishProviderProfileRevision(
                profileID: "oauth-profile",
                replacingRevision: nil,
                presetID: .anthropic,
                displayName: "OAuth provider",
                baseURL: URL(string: "https://attacker.example/v1")!,
                retentionMode: .statelessRequired,
                credentialMode: .oauth,
                initialSecret: try OAuthTokenCredential(
                    accessToken: "access",
                    refreshToken: "refresh",
                    expiresAt: Date.distantFuture
                ).secureSecret()
            )
            Issue.record("substituted OAuth origin was published")
        } catch let failure as ProviderProfileFailure {
            #expect(failure.code == "provider_oauth.origin_mismatch")
        }
    }

    @Test
    func validationAutomaticallyRefreshesOAuthBeforeSealingItsCredentialLease() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cloud-oauth-auto-refresh-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let catalogFixture = try signedCloudCatalog(revision: 1)
        let transport = SubsystemFixtureTransport(
            toolLoop: false,
            oauthResponse: OAuthHTTPResponse(
                statusCode: 200,
                headers: [:],
                body: Data(
                    #"{"access_token":"fresh-access","refresh_token":"fresh-refresh","expires_in":7200}"#
                        .utf8
                )
            )
        )
        let subsystem = try await CloudLLMSubsystem.bootstrap(
            appSupportRoot: directory,
            hostProcessEpoch: try HostProcessEpoch.generate(),
            bundledCatalog: catalogFixture.envelope,
            trustedKeyRing: catalogFixture.keyRing,
            remoteCatalog: nil,
            vault: RuntimeCredentialVault(),
            approvalPrompt: RuntimeApprovalPrompt(),
            transportFactory: { _ in transport },
            localUnloader: RuntimeLocalUnloader(order: RuntimeRouteOrder()),
            originValidator: RuntimeOriginValidator()
        )
        let published = try await subsystem.publishProviderProfileRevision(
            profileID: "oauth-profile",
            replacingRevision: nil,
            presetID: .openAI,
            displayName: "OAuth provider",
            baseURL: URL(string: "https://chatgpt.com/backend-api/codex")!,
            retentionMode: .statelessRequired,
            credentialMode: .oauth,
            initialSecret: try OAuthTokenCredential(
                accessToken: "stale-access",
                refreshToken: "stale-refresh",
                expiresAt: Date().addingTimeInterval(30)
            ).secureSecret()
        )

        let validation = try await subsystem.validation.validate(
            profileID: "oauth-profile",
            profileRevision: 1,
            modelID: "fixture-model",
            adapterVersion: "1"
        )

        #expect(await transport.oauthRequestCount == 1)
        #expect(validation.subject.credentialGeneration == 2)
        #expect(
            try await subsystem.credentials.slot(
                published.revision.credentialRef
            )?.currentGeneration == 2
        )
    }

    @Test
    func oauthLogoutDisconnectsSecretWithoutArchivingProviderConfiguration() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cloud-oauth-disconnect-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let catalogFixture = try signedCloudCatalog(revision: 1)
        let subsystem = try await CloudLLMSubsystem.bootstrap(
            appSupportRoot: directory,
            hostProcessEpoch: try HostProcessEpoch.generate(),
            bundledCatalog: catalogFixture.envelope,
            trustedKeyRing: catalogFixture.keyRing,
            remoteCatalog: nil,
            vault: RuntimeCredentialVault(),
            approvalPrompt: RuntimeApprovalPrompt(),
            transportFactory: { _ in SubsystemFixtureTransport(toolLoop: false) },
            localUnloader: RuntimeLocalUnloader(order: RuntimeRouteOrder()),
            originValidator: RuntimeOriginValidator()
        )
        _ = try await subsystem.publishProviderProfileRevision(
            profileID: "oauth-profile",
            replacingRevision: nil,
            presetID: .openAI,
            displayName: "OAuth provider",
            baseURL: URL(string: "https://chatgpt.com/backend-api/codex")!,
            retentionMode: .statelessRequired,
            credentialMode: .oauth,
            initialSecret: try OAuthTokenCredential(
                accessToken: "access",
                refreshToken: "refresh",
                expiresAt: Date.distantFuture
            ).secureSecret()
        )

        try await subsystem.disconnectProviderOAuthCredential(
            profileID: "oauth-profile",
            profileRevision: 1
        )

        let inventory = try await subsystem.providerInventory()
        #expect(inventory.count == 1)
        #expect(inventory[0].profileID == "oauth-profile")
        #expect(!inventory[0].hasStoredCredential)
        #expect(
            await subsystem.profiles.profile(
                profileID: "oauth-profile",
                revision: 1
            )?.lifecycle == .active
        )
    }

    @Test
    func manualModelCompletesRoutineTextPath() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cloud-manual-product-path-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let catalogFixture = try signedCloudCatalog(revision: 1)
        let transport = SubsystemFixtureTransport(toolLoop: false)
        let epoch = try HostProcessEpoch.generate()
        let llmStore = try LLMStore(
            fileURL: directory.appending(path: "LocalAgent/LLM/llm-state.sqlite")
        )
        let subsystem = try await CloudLLMSubsystem.bootstrap(
            appSupportRoot: directory,
            hostProcessEpoch: epoch,
            bundledCatalog: catalogFixture.envelope,
            trustedKeyRing: catalogFixture.keyRing,
            remoteCatalog: nil,
            vault: RuntimeCredentialVault(),
            approvalPrompt: RuntimeApprovalPrompt(),
            transportFactory: { _ in transport },
            localUnloader: RuntimeLocalUnloader(order: RuntimeRouteOrder()),
            originValidator: RuntimeOriginValidator(),
            llmStore: llmStore
        )
        #expect(subsystem.bindingStore === llmStore)

        let published = try await subsystem.createProviderProfile(
            ProviderProfileRevision(
            profileID: "manual-integration-profile",
            revision: 1,
            presetID: .openAI,
            displayName: "Manual integration provider",
            baseURL: URL(string: "https://api.example.com/v1")!,
            credentialRef: "manual-integration-key",
            retentionMode: .statelessRequired
            ),
            initialSecret: SecretBytes(utf8: "fixture-secret"),
            proposedOperationID: "manual-integration-create-key"
        )
        #expect(published.lifecycle == .active)
        let target = LLMTargetRevision(
            targetID: LLMTargetID(rawValue: "manual-integration-target"),
            revision: 1,
            kind: .cloud(
                providerProfileID: "manual-integration-profile",
                providerProfileRevision: 1
            ),
            modelID: "manual-openai-model",
            defaultParameters: GenerationConfiguration()
        )
        try await subsystem.bindingStore.publishTarget(target)
        let validation = try await subsystem.validation.validate(
            profileID: "manual-integration-profile",
            profileRevision: 1,
            modelID: target.modelID,
            adapterVersion: "1"
        )
        #expect(validation.subject.catalogRevision == nil)
        #expect(validation.snapshot.support(for: "text_generation") == .supported)
        #expect(validation.snapshot.support(for: "streaming") == .supported)
        #expect(validation.snapshot.support(for: "tool_calling") == .unknown)

        let configuration = AgentHostConfiguration(
            bindingID: "manual-integration-binding",
            revision: 1,
            agentProfileID: "manual-integration-agent",
            agentProfileRevision: 1,
            llmSlotID: "assistant",
            requirementsHash: String(repeating: "d", count: 64),
            llmTargetID: target.targetID,
            llmTargetRevision: target.revision,
            parameterOverrides: GenerationConfiguration()
        )
        let saga = AgentHostBindingSaga(store: subsystem.bindingStore)
        let binding = try await saga.stageHostBinding(HostBindingStageRequest(
            operationToken: "manual-integration-binding-token",
            tokenDigest: "manual-integration-binding-token-digest",
            llmSlotID: configuration.llmSlotID,
            requirementsHash: configuration.requirementsHash,
            configuration: configuration
        ))
        try await saga.activateHostBinding(
            operationToken: "manual-integration-binding-token",
            binding: binding.binding
        )
        let resolved = try CloudGenerationConfigurationResolver.resolveManual(
            adapterID: "openai.responses",
            modelID: target.modelID
        )
        let initial = try runtimeTurn(
            resolvedParameters: resolved.semantic,
            generationTurnID: "manual-integration-turn",
            inputID: "manual-integration-input",
            text: "hello manual model",
            semanticHistory: .array([]),
            toolResults: [],
            dataClasses: [.text],
            sensitivity: .routine,
            sourceKinds: [.conversation],
            triggeringToolDisplayKeys: [],
            toolSchema: .array([])
        )
        let prepared = try await subsystem.runtime.prepareSession(
            context: .init(
                preparationID: "manual-integration-preparation",
                proposedRunID: "manual-integration-run",
                initialTurn: initial,
                signedToolDisplayKeys: []
            ),
            hostConfiguration: configuration,
            target: target
        )
        let events = try await collect(try await subsystem.runtime.startGeneration(
            sessionID: prepared.sessionID,
            turn: initial
        ))
        #expect(events.contains(.textDelta("Done")))
        #expect(events.last == .generationCompleted(.init(
            outcome: .finalResponse,
            orderedCallIDs: [],
            finishReason: .stop
        )))
        try await subsystem.runtime.closeSession(sessionID: prepared.sessionID)
        #expect(await transport.validationRequestCount == 3)
        #expect(await transport.generationRequestCount == 1)
    }

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
        try await subsystem.bindingStore.publishTarget(target)
        let validation = try await subsystem.validation.validate(
            profileID: "integration-profile",
            profileRevision: 1,
            modelID: "fixture-model",
            adapterVersion: "1"
        )
        #expect(validation.snapshot.support(for: "tool_calling") == .supported)
        let providers = try await subsystem.providerInventory()
        #expect(providers.count == 1)
        #expect(providers[0].displayOrigin == "https://api.example.com:443")
        #expect(!String(describing: providers).contains("fixture-secret"))
        #expect(!String(describing: providers).contains("credentialGeneration"))
        let models = try await subsystem.modelInventory(
            profileID: "integration-profile",
            profileRevision: 1
        )
        let productModel = try #require(models.first {
            $0.modelID == "fixture-model"
        })
        #expect(productModel.capabilities.support(for: "tool_calling") == .supported)
        #expect(productModel.parameterSchema.definitions.isEmpty == false)
        #expect(productModel.validation.isCurrent)

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
    private let toolLoop: Bool
    private let oauthResponse: OAuthHTTPResponse?
    private(set) var validationRequestCount = 0
    private(set) var generationRequestCount = 0
    private(set) var oauthRequestCount = 0

    init(
        toolLoop: Bool = true,
        oauthResponse: OAuthHTTPResponse? = nil
    ) {
        self.toolLoop = toolLoop
        self.oauthResponse = oauthResponse
    }

    func oauth(
        _ request: OAuthHTTPRequest
    ) async throws -> OAuthHTTPResponse {
        oauthRequestCount += 1
        guard let oauthResponse else {
            throw OAuthHTTPFailure(code: "oauth.transport_unavailable")
        }
        return oauthResponse
    }

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
            events = toolLoop && generationRequestCount == 1
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
