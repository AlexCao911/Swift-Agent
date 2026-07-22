import Foundation
import LocalAgentLLMContracts
import LocalAgentLLMCore

public protocol LocalRouteUnloading: Sendable {
    func unloadForCloudRouteSwitch() async throws
}

package struct NoopLocalRouteUnloader: LocalRouteUnloading {
    package init() {}
    package func unloadForCloudRouteSwitch() async throws {}
}

public struct CloudGenerationTurnRequest: Equatable, Sendable {
    public let input: AgentLLMInput
    public let canonicalToolSchema: CanonicalJSONValue
    public let sourceRevisionDocument: CanonicalJSONValue
    public let toolResults: [NormalizedToolResult]
    public let providerRequiredSemanticHistory: CanonicalJSONValue
    public let disclosure: GenerationDisclosure
    public let resolvedParameters: GenerationConfiguration

    public init(
        input: AgentLLMInput,
        canonicalToolSchema: CanonicalJSONValue,
        sourceRevisionDocument: CanonicalJSONValue,
        toolResults: [NormalizedToolResult],
        providerRequiredSemanticHistory: CanonicalJSONValue,
        disclosure: GenerationDisclosure,
        resolvedParameters: GenerationConfiguration
    ) {
        self.input = input
        self.canonicalToolSchema = canonicalToolSchema
        self.sourceRevisionDocument = sourceRevisionDocument
        self.toolResults = toolResults
        self.providerRequiredSemanticHistory = providerRequiredSemanticHistory
        self.disclosure = disclosure
        self.resolvedParameters = resolvedParameters
    }

    package func candidate(
        using resolver: any CloudAttachmentIdentityResolving
    ) throws -> CloudGenerationTurnCandidate {
        CloudGenerationTurnCandidate(
            input: input,
            canonicalToolSchema: canonicalToolSchema,
            sourceRevisionDocument: sourceRevisionDocument,
            resolvedAttachments: try resolver.resolveIdentities(
                for: input,
                sourceRevisionDocument: sourceRevisionDocument
            ),
            toolResults: toolResults,
            providerRequiredSemanticHistory: providerRequiredSemanticHistory,
            disclosure: disclosure,
            resolvedParameters: resolvedParameters
        )
    }
}

package struct CloudProviderAdapterRegistry: Sendable {
    private let adapters: [ProviderPresetID: any CloudProviderAdapter]

    package var presetIDs: Set<ProviderPresetID> { Set(adapters.keys) }
    package var adapterIDs: Set<String> { Set(adapters.values.map(\.adapterID)) }

    package init(adapters: [any CloudProviderAdapter]) throws {
        var indexed: [ProviderPresetID: any CloudProviderAdapter] = [:]
        for adapter in adapters {
            guard indexed[adapter.presetID] == nil else {
                throw cloudRuntimeFailure(
                    "runtime.cloud_adapter_duplicate",
                    "cloud adapter registry contains a duplicate provider preset"
                )
            }
            indexed[adapter.presetID] = adapter
        }
        self.adapters = indexed
    }

    package static func shipped() throws -> Self {
        let registry = try Self(adapters: [
            OpenAIResponsesAdapter(),
            AnthropicMessagesAdapter(),
            GeminiInteractionsAdapter(),
            XAIAdapter(),
            DeepSeekAdapter(),
            MiniMaxAdapter(),
            GLMAdapter(),
        ])
        let expected = Dictionary(uniqueKeysWithValues: ProviderPreset.shipped.map {
            ($0.id, $0.semanticAdapterID)
        })
        guard registry.presetIDs == Set(expected.keys),
              registry.adapters.allSatisfy({ expected[$0.key] == $0.value.adapterID })
        else {
            throw cloudRuntimeFailure(
                "runtime.cloud_adapter_registry_incomplete",
                "installed cloud adapters do not match the shipped provider presets"
            )
        }
        return registry
    }

    package func adapter(
        presetID: ProviderPresetID,
        expectedAdapterID: String,
        expectedVersion: String
    ) throws -> any CloudProviderAdapter {
        guard let adapter = adapters[presetID],
              adapter.adapterID == expectedAdapterID,
              adapter.adapterVersion == expectedVersion
        else {
            throw cloudRuntimeFailure(
                "runtime.cloud_adapter_unavailable",
                "the exact validated cloud adapter is not installed"
            )
        }
        return adapter
    }
}

public struct CloudSessionPreparationContext: Equatable, Sendable {
    public let preparationID: String
    public let proposedRunID: String
    public let initialTurn: CloudGenerationTurnRequest
    public let signedToolDisplayKeys: Set<String>

    public init(
        preparationID: String,
        proposedRunID: String,
        initialTurn: CloudGenerationTurnRequest,
        signedToolDisplayKeys: Set<String>
    ) {
        self.preparationID = preparationID
        self.proposedRunID = proposedRunID
        self.initialTurn = initialTurn
        self.signedToolDisplayKeys = signedToolDisplayKeys
    }
}

package enum CloudLLMRuntimeState: Equatable, Sendable {
    case idle
    case preparing
    case prepared
    case generating
    case awaitingToolResult
    case cancelling
    case terminal
    case closing
    case quarantined
}

public actor CloudLLMRuntime {
    private struct ActiveSession {
        let prepared: PreparedCloudSession
        let snapshotID: String
        let target: LLMTargetRevision
        let hostConfiguration: AgentHostConfiguration
        let profile: PublishedProviderProfileRevision
        let providerSession: any CloudProviderSession
        let initialTurn: CloudGenerationTurnRequest
        let signedToolDisplayKeys: Set<String>
        var scopeGrant: EgressScopeGrant
        var leaseRevision: UInt64
        var lifecycle: PreparedCloudSessionLifecycle
        var generationID: String?
        var generationTask: Task<Void, Never>?
        var cancelRequested: Bool
    }

    private let profileStore: ProviderProfileStore
    private let catalogStore: CloudCapabilityCatalogStore
    private let credentialStore: ProviderCredentialStore
    private let validationService: ProviderValidationService
    private let egressPolicy: ProviderEgressPolicy
    private let sessionStore: PreparedCloudSessionStore
    private let bindingSaga: AgentHostBindingSaga
    private let attachmentResolver: any CloudAttachmentIdentityResolving
    private let transport: any CloudHTTPTransport
    private let localUnloader: any LocalRouteUnloading
    private let adapters: CloudProviderAdapterRegistry
    private let hostProcessEpoch: HostProcessEpoch
    private let clock: @Sendable () -> Date
    private var active: ActiveSession?
    package private(set) var state: CloudLLMRuntimeState = .idle

    package init(
        profileStore: ProviderProfileStore,
        catalogStore: CloudCapabilityCatalogStore,
        credentialStore: ProviderCredentialStore,
        validationService: ProviderValidationService,
        egressPolicy: ProviderEgressPolicy,
        sessionStore: PreparedCloudSessionStore,
        bindingSaga: AgentHostBindingSaga,
        attachmentResolver: any CloudAttachmentIdentityResolving,
        transport: any CloudHTTPTransport,
        localUnloader: any LocalRouteUnloading,
        adapters: CloudProviderAdapterRegistry,
        hostProcessEpoch: HostProcessEpoch,
        clock: @escaping @Sendable () -> Date = Date.init
    ) {
        self.profileStore = profileStore
        self.catalogStore = catalogStore
        self.credentialStore = credentialStore
        self.validationService = validationService
        self.egressPolicy = egressPolicy
        self.sessionStore = sessionStore
        self.bindingSaga = bindingSaga
        self.attachmentResolver = attachmentResolver
        self.transport = transport
        self.localUnloader = localUnloader
        self.adapters = adapters
        self.hostProcessEpoch = hostProcessEpoch
        self.clock = clock
    }

    public func prepareSession(
        context: CloudSessionPreparationContext,
        hostConfiguration: AgentHostConfiguration,
        target: LLMTargetRevision
    ) async throws -> PreparedCloudSession {
        guard active == nil, state == .idle else {
            throw cloudRuntimeFailure(
                "runtime.cloud_session_busy",
                "close the current cloud session before preparing another"
            )
        }
        guard !context.preparationID.isEmpty, !context.proposedRunID.isEmpty else {
            throw cloudRuntimeFailure(
                "runtime.cloud_preparation_invalid",
                "cloud preparation identity is empty"
            )
        }
        state = .preparing
        do {
            let binding = try await requireBinding(
                hostConfiguration: hostConfiguration,
                target: target
            )
            let route = try await requireRoute(target: target)
            let validation = try await validationService.currentValidation(
                profileID: route.profile.revision.profileID,
                profileRevision: route.profile.revision.revision,
                modelID: target.modelID,
                adapterVersion: route.adapter.adapterVersion,
                targetID: target.targetID,
                targetRevision: target.revision
            )
            try requireValidationSource(validation, route: route)
            try CloudRuntimeCapabilityGate.require(
                validation.snapshot,
                toolSchema: context.initialTurn.canonicalToolSchema
            )
            let resolved = try resolveConfiguration(
                route: route,
                targetDefaults: target.defaultParameters,
                hostOverrides: hostConfiguration.parameterOverrides
            )
            guard context.initialTurn.resolvedParameters == resolved.semantic else {
                throw cloudRuntimeFailure(
                    "runtime.cloud_parameters_mismatch",
                    "initial turn parameters do not match the exact target and host binding"
                )
            }
            let validated = try validate(context.initialTurn)
            let lease = try await credentialStore.acquireUseLease(
                credentialRef: route.profile.revision.credentialRef,
                purpose: .preparation,
                preparationID: context.preparationID,
                hostProcessEpoch: hostProcessEpoch
            )
            guard validation.subject.credentialGeneration == lease.generation else {
                try? await credentialStore.abortPreparationLease(
                    lease.leaseID,
                    expectedRevision: lease.revision
                )
                throw cloudRuntimeFailure(
                    "runtime.cloud_validation_stale",
                    "credential generation changed after provider validation"
                )
            }
            do {
                return try await finishPreparation(
                    context: context,
                    hostConfiguration: hostConfiguration,
                    target: target,
                    binding: binding,
                    route: route,
                    validation: validation,
                    resolved: resolved,
                    validated: validated,
                    lease: lease
                )
            } catch {
                try? await credentialStore.abortPreparationLease(
                    lease.leaseID,
                    expectedRevision: lease.revision
                )
                state = .idle
                throw error
            }
        } catch {
            if state != .quarantined { state = .idle }
            throw error
        }
    }

    public func startGeneration(
        sessionID: String,
        turn: CloudGenerationTurnRequest
    ) async throws -> LLMBackendEventStream {
        guard let active,
              active.prepared.sessionID == sessionID,
              active.lifecycle == .prepared,
              active.generationTask == nil,
              state == .prepared,
              turn == active.initialTurn
        else {
            throw cloudRuntimeFailure(
                "runtime.cloud_generation_state_invalid",
                "cloud session is not ready for its frozen initial turn"
            )
        }
        let authorized = try await authorize(turn: turn, active: active)
        guard authorized.scopeGrant.grantID == active.prepared.scopeGrantID,
              authorized.authorization.authorizationID
                == active.prepared.generationAuthorizationID,
              authorized.egressSubjectDigest == active.prepared.opaqueEgressSubjectDigest,
              authorized.authorization.disclosureDigest
                == active.prepared.initialDisclosureDigest
        else {
            throw cloudRuntimeFailure(
                "runtime.cloud_initial_authorization_changed",
                "initial cloud authorization changed after preparation"
            )
        }
        let wire = try active.providerSession.encodeStart(authorized)
        return try await beginGeneration(
            active: active,
            authorized: authorized,
            wire: wire
        )
    }

    public func resumeGeneration(
        sessionID: String,
        turn: CloudGenerationTurnRequest
    ) async throws -> LLMBackendEventStream {
        guard let active,
              active.prepared.sessionID == sessionID,
              active.lifecycle == .awaitingToolResult,
              active.generationTask == nil,
              state == .awaitingToolResult,
              !turn.toolResults.isEmpty
        else {
            throw cloudRuntimeFailure(
                "runtime.cloud_resume_state_invalid",
                "cloud session is not awaiting a complete tool-result batch"
            )
        }
        let authorized = try await authorize(turn: turn, active: active)
        let wire = try active.providerSession.encodeResume(authorized)
        return try await beginGeneration(
            active: active,
            authorized: authorized,
            wire: wire
        )
    }

    public func cancel(sessionID: String) async throws {
        guard let active, active.prepared.sessionID == sessionID else {
            if try sessionStore.tombstone(sessionID) != nil { return }
            throw cloudRuntimeFailure(
                "runtime.cloud_session_not_found",
                "prepared cloud session was not found"
            )
        }
        guard let generationID = active.generationID,
              let task = active.generationTask
        else { return }
        let claimedTask = await cancelGenerationOnce(
            sessionID: sessionID,
            generationID: generationID,
            cancelPump: true
        )
        await (claimedTask ?? task).value
    }

    public func closeSession(sessionID: String) async throws {
        guard var active, active.prepared.sessionID == sessionID else {
            if try sessionStore.tombstone(sessionID) != nil { return }
            throw cloudRuntimeFailure(
                "runtime.cloud_session_not_found",
                "prepared cloud session was not found"
            )
        }
        if active.generationTask != nil {
            try await cancel(sessionID: sessionID)
            guard let refreshed = self.active else { return }
            active = refreshed
        }
        guard state != .quarantined else {
            throw cloudRuntimeFailure(
                "runtime.cloud_runtime_quarantined",
                "cloud session cleanup is incomplete"
            )
        }
        state = .closing
        await active.providerSession.close()
        do {
            let closing = try await credentialStore.beginClosingLease(
                active.prepared.credentialUseLeaseID,
                expectedRevision: active.leaseRevision
            )
            _ = try sessionStore.closePreparedSession(
                sessionID: sessionID,
                expectedLifecycle: active.lifecycle,
                closingLeaseRevision: closing.revision,
                disposition: .closed,
                now: clock()
            )
            self.active = nil
            state = .idle
        } catch {
            self.active = active
            state = .quarantined
            throw error
        }
    }

    private struct Route {
        let profile: PublishedProviderProfileRevision
        let state: ProviderProfileState
        let source: CloudModelRouteSource
        let adapter: any CloudProviderAdapter
    }

    private func requireBinding(
        hostConfiguration: AgentHostConfiguration,
        target: LLMTargetRevision
    ) async throws -> HostBindingTuple {
        do {
            return try await bindingSaga.requireActive(
                configuration: hostConfiguration,
                target: target
            )
        } catch let error as HostBindingSagaError {
            throw cloudRuntimeFailure(error.code, error.message)
        }
    }

    private func requireRoute(target: LLMTargetRevision) async throws -> Route {
        guard case let .cloud(profileID, profileRevision) = target.kind,
              profileRevision > 0,
              await profileStore.target(
                  targetID: target.targetID,
                  revision: target.revision
              ) == target,
              let profile = await profileStore.profile(
                  profileID: profileID,
                  revision: profileRevision
              ),
              profile.lifecycle == .active,
              let profileState = await profileStore.state(
                  profileID: profileID,
                  profileRevision: profileRevision
              ),
              case let .validated(evidence) = profileState.validationState,
              let preset = ProviderPreset.shipped.first(where: {
                  $0.id == profile.revision.presetID
              })
        else {
            throw cloudRuntimeFailure(
                "runtime.cloud_target_not_runnable",
                "cloud target is not pinned to an active validated provider route"
            )
        }
        let adapter = try adapters.adapter(
            presetID: preset.id,
            expectedAdapterID: evidence.adapterID,
            expectedVersion: evidence.adapterVersion
        )
        guard evidence.adapterID == preset.semanticAdapterID,
              evidence.modelID == target.modelID,
              evidence.origin == profile.origin,
              evidence.retentionMode == profile.revision.retentionMode,
              profileState.catalogRevision == evidence.catalogRevision
        else {
            throw cloudRuntimeFailure(
                "runtime.cloud_target_not_runnable",
                "cloud adapter, model, or retention identity is not current"
            )
        }
        let source: CloudModelRouteSource
        if let catalogRevision = evidence.catalogRevision {
            guard let catalog = try await catalogStore.current(),
                  catalog.catalogRevision == catalogRevision,
                  let entry = catalog.entry(
                      presetID: profile.revision.presetID,
                      modelID: target.modelID
                  ),
                  !catalog.isRevoked(entry.identity),
                  entry.adapterID == evidence.adapterID,
                  entry.supports(adapterVersion: adapter.adapterVersion),
                  entry.continuationModes.contains(profile.revision.retentionMode)
            else {
                throw cloudRuntimeFailure(
                    "runtime.cloud_target_not_runnable",
                    "catalog-backed cloud route is no longer exact or compatible"
                )
            }
            source = .catalog(entry)
        } else {
            guard profile.revision.retentionMode == .statelessRequired
            else {
                throw cloudRuntimeFailure(
                    "runtime.cloud_target_not_runnable",
                    "manual cloud routes require stateless retention"
                )
            }
            source = .manual(
                adapterID: evidence.adapterID,
                modelID: evidence.modelID
            )
        }
        return Route(
            profile: profile,
            state: profileState,
            source: source,
            adapter: adapter
        )
    }

    private func resolveConfiguration(
        route: Route,
        targetDefaults: GenerationConfiguration,
        hostOverrides: GenerationConfiguration
    ) throws -> ResolvedCloudGenerationConfiguration {
        switch route.source {
        case let .catalog(entry):
            return try CloudGenerationConfigurationResolver.resolve(
                entry: entry,
                targetDefaults: targetDefaults,
                hostOverrides: hostOverrides
            )
        case let .manual(adapterID, modelID):
            return try CloudGenerationConfigurationResolver.resolveManual(
                adapterID: adapterID,
                modelID: modelID,
                targetDefaults: targetDefaults,
                hostOverrides: hostOverrides
            )
        }
    }

    private func requireValidationSource(
        _ validation: ProviderValidationResult,
        route: Route
    ) throws {
        guard validation.subject.adapterID == route.adapter.adapterID else {
            throw cloudRuntimeFailure(
                "runtime.cloud_validation_stale",
                "validated adapter does not match the current cloud route"
            )
        }
        switch route.source {
        case let .catalog(entry):
            guard validation.subject.modelID == entry.identity.modelID,
                  validation.subject.modelRevision == entry.identity.modelRevision,
                  validation.subject.catalogRevision == route.state.catalogRevision
            else {
                throw cloudRuntimeFailure(
                    "runtime.cloud_validation_stale",
                    "catalog validation does not match the exact model route"
                )
            }
        case let .manual(adapterID, modelID):
            guard validation.subject.adapterID == adapterID,
                  validation.subject.modelID == modelID,
                  validation.subject.modelRevision == nil,
                  validation.subject.catalogRevision == nil
            else {
                throw cloudRuntimeFailure(
                    "runtime.cloud_validation_stale",
                    "manual validation was promoted or changed"
                )
            }
        }
    }

    private func finishPreparation(
        context: CloudSessionPreparationContext,
        hostConfiguration: AgentHostConfiguration,
        target: LLMTargetRevision,
        binding: HostBindingTuple,
        route: Route,
        validation: ProviderValidationResult,
        resolved: ResolvedCloudGenerationConfiguration,
        validated: ValidatedCloudGenerationTurn,
        lease: CredentialUseLease
    ) async throws -> PreparedCloudSession {
        let egressContext = CloudEgressSessionContext(
            runID: context.proposedRunID,
            targetID: target.targetID,
            targetRevision: target.revision,
            profileID: route.profile.revision.profileID,
            profileRevision: route.profile.revision.revision,
            origin: route.profile.origin,
            credentialRef: route.profile.revision.credentialRef,
            credentialGeneration: lease.generation,
            credentialUseLeaseID: lease.leaseID,
            signedToolDisplayKeys: context.signedToolDisplayKeys
        )
        let authorized = try await egressPolicy.authorizeTurn(
            validated,
            session: egressContext,
            priorGrant: nil
        )
        let currentRoute = try await requireRoute(target: target)
        guard currentRoute.profile == route.profile,
              currentRoute.state == route.state,
              currentRoute.source == route.source,
              currentRoute.adapter.adapterID == route.adapter.adapterID,
              currentRoute.adapter.adapterVersion == route.adapter.adapterVersion
        else {
            throw cloudRuntimeFailure(
                "runtime.cloud_route_changed",
                "cloud route changed during preparation approval"
            )
        }
        let currentValidation = try await validationService.currentValidation(
            profileID: route.profile.revision.profileID,
            profileRevision: route.profile.revision.revision,
            modelID: target.modelID,
            adapterVersion: route.adapter.adapterVersion,
            targetID: target.targetID,
            targetRevision: target.revision
        )
        try requireValidationSource(currentValidation, route: currentRoute)
        guard currentValidation.evidenceDigest == validation.evidenceDigest else {
            throw cloudRuntimeFailure(
                "runtime.cloud_validation_stale",
                "cloud validation changed during preparation approval"
            )
        }
        let sessionID = try PreparedCloudSession.generateSessionID()
        let snapshotID = "cloud-snapshot-\(sessionID)"
        let leaseDigest = try credentialUseLeaseDigest(lease).hex
        let disclosureDigest = try context.initialTurn.disclosure.computedDigest().hex
        let registrationDigest = try preparedRegistrationDigest(
            preparationID: context.preparationID,
            proposedRunID: context.proposedRunID,
            sessionID: sessionID,
            snapshotID: snapshotID,
            hostProcessEpoch: hostProcessEpoch,
            binding: binding,
            credentialUseLeaseDigest: leaseDigest
        )
        let attestationDigest = try cloudEgressAttestationDigest(
            preparationID: context.preparationID,
            proposedRunID: context.proposedRunID,
            sessionID: sessionID,
            snapshotID: snapshotID,
            registrationDigest: registrationDigest,
            binding: binding,
            requirementsHash: hostConfiguration.requirementsHash,
            disclosureDigest: disclosureDigest,
            capabilitySnapshotDigest: currentValidation.evidenceDigest,
            resolvedParametersDigest: resolved.digest,
            hostProcessEpoch: hostProcessEpoch,
            expiresAt: authorized.authorization.expiresAt,
            opaqueEgressSubjectDigest: authorized.egressSubjectDigest
        )
        let prepared = PreparedCloudSession(
            sessionID: sessionID,
            preparationID: context.preparationID,
            proposedRunID: context.proposedRunID,
            targetID: target.targetID,
            targetRevision: target.revision,
            bindingID: binding.bindingID,
            bindingRevision: binding.bindingRevision,
            bindingHash: binding.bindingHash,
            requirementsHash: hostConfiguration.requirementsHash,
            providerProfileID: route.profile.revision.profileID,
            providerProfileRevision: route.profile.revision.revision,
            origin: route.profile.origin,
            credentialRef: route.profile.revision.credentialRef,
            credentialGeneration: lease.generation,
            retentionMode: route.profile.revision.retentionMode,
            retentionApprovalRevision: route.state.retentionApprovalRevision,
            retentionApprovalDigest: route.state.retentionApprovalDigest,
            credentialUseLeaseID: lease.leaseID,
            credentialUseLeaseDigest: leaseDigest,
            modelID: target.modelID,
            capabilitySnapshotDigest: currentValidation.evidenceDigest,
            resolvedParametersDigest: resolved.digest,
            initialDisclosureDigest: disclosureDigest,
            scopeGrantID: authorized.scopeGrant.grantID,
            generationAuthorizationID: authorized.authorization.authorizationID,
            opaqueEgressSubjectDigest: authorized.egressSubjectDigest,
            egressAttestationDigest: attestationDigest,
            hostProcessEpoch: hostProcessEpoch,
            adapterID: route.adapter.adapterID,
            adapterVersion: route.adapter.adapterVersion
        )
        let snapshot = SanitizedCloudSessionSnapshot(
            snapshotID: snapshotID,
            sessionID: sessionID,
            runID: context.proposedRunID,
            preparationID: context.preparationID,
            hostProcessEpoch: hostProcessEpoch,
            capabilitySnapshot: currentValidation.snapshot,
            resolvedConfiguration: resolved.semantic
        )
        try sessionStore.persistPreparedSession(
            prepared,
            snapshot: snapshot,
            credentialLease: lease
        )
        var providerSession: (any CloudProviderSession)?
        do {
            try await localUnloader.unloadForCloudRouteSwitch()
            let opened = try route.adapter.makeSession(
                CloudProviderSessionContext(
                    targetID: target.targetID,
                    targetRevision: target.revision,
                    providerProfileID: route.profile.revision.profileID,
                    providerProfileRevision: route.profile.revision.revision,
                    modelID: target.modelID,
                    retentionMode: route.profile.revision.retentionMode,
                    retentionApprovalRevision: route.state.retentionApprovalRevision,
                    retentionApprovalDigest: route.state.retentionApprovalDigest,
                    hostProcessEpoch: hostProcessEpoch
                )
            )
            providerSession = opened
            let bound = try await credentialStore.bindPreparationLease(
                lease.leaseID,
                expectedRevision: lease.revision
            )
            active = ActiveSession(
                prepared: prepared,
                snapshotID: snapshotID,
                target: target,
                hostConfiguration: hostConfiguration,
                profile: route.profile,
                providerSession: opened,
                initialTurn: context.initialTurn,
                signedToolDisplayKeys: context.signedToolDisplayKeys,
                scopeGrant: authorized.scopeGrant,
                leaseRevision: bound.revision,
                lifecycle: .prepared,
                generationID: nil,
                generationTask: nil,
                cancelRequested: false
            )
            state = .prepared
            return prepared
        } catch {
            await providerSession?.close()
            do {
                try sessionStore.abortBeforeSessionBinding(
                    sessionID: sessionID,
                    expectedLeaseRevision: lease.revision
                )
            } catch {
                state = .quarantined
                throw error
            }
            throw error
        }
    }

    private func validate(
        _ request: CloudGenerationTurnRequest
    ) throws -> ValidatedCloudGenerationTurn {
        do {
            return try CloudSemanticTurnValidator().validate(
                request.candidate(using: attachmentResolver)
            )
        } catch let failure as CloudTurnValidationFailure {
            throw cloudRuntimeFailure(failure.code, failure.message)
        }
    }

    private func authorize(
        turn: CloudGenerationTurnRequest,
        active: ActiveSession
    ) async throws -> AuthorizedCloudGenerationTurn {
        let route = try await requireRoute(target: active.target)
        guard route.profile == active.profile,
              route.profile.revision.retentionMode == active.prepared.retentionMode,
              route.state.retentionApprovalRevision == active.prepared.retentionApprovalRevision,
              route.state.retentionApprovalDigest == active.prepared.retentionApprovalDigest
        else {
            throw cloudRuntimeFailure(
                "runtime.cloud_route_changed",
                "provider route or retention approval changed after preparation"
            )
        }
        let validation = try await validationService.currentValidation(
            profileID: active.prepared.providerProfileID,
            profileRevision: active.prepared.providerProfileRevision,
            modelID: active.prepared.modelID,
            adapterVersion: active.prepared.adapterVersion,
            targetID: active.prepared.targetID,
            targetRevision: active.prepared.targetRevision
        )
        try requireValidationSource(validation, route: route)
        guard validation.evidenceDigest == active.prepared.capabilitySnapshotDigest else {
            throw cloudRuntimeFailure(
                "runtime.cloud_capability_changed",
                "cloud capability snapshot changed after preparation"
            )
        }
        let resolved = try resolveConfiguration(
            route: route,
            targetDefaults: active.target.defaultParameters,
            hostOverrides: active.hostConfiguration.parameterOverrides
        )
        guard resolved.digest == active.prepared.resolvedParametersDigest,
              resolved.semantic == turn.resolvedParameters
        else {
            throw cloudRuntimeFailure(
                "runtime.cloud_parameters_changed",
                "resolved cloud parameters changed after preparation"
            )
        }
        _ = try await credentialStore.revalidatePreparationLease(
            active.prepared.credentialUseLeaseID,
            credentialRef: active.prepared.credentialRef,
            generation: active.prepared.credentialGeneration
        )
        let validated = try validate(turn)
        return try await egressPolicy.authorizeTurn(
            validated,
            session: CloudEgressSessionContext(
                runID: active.prepared.proposedRunID,
                targetID: active.prepared.targetID,
                targetRevision: active.prepared.targetRevision,
                profileID: active.prepared.providerProfileID,
                profileRevision: active.prepared.providerProfileRevision,
                origin: active.prepared.origin,
                credentialRef: active.prepared.credentialRef,
                credentialGeneration: active.prepared.credentialGeneration,
                credentialUseLeaseID: active.prepared.credentialUseLeaseID,
                signedToolDisplayKeys: active.signedToolDisplayKeys
            ),
            priorGrant: active.scopeGrant
        )
    }

    private func beginGeneration(
        active current: ActiveSession,
        authorized: AuthorizedCloudGenerationTurn,
        wire: CloudWireRequest
    ) async throws -> LLMBackendEventStream {
        let sealed = try await egressPolicy.sealGenerationRequest(
            wire,
            authorizedTurn: authorized
        )
        try sessionStore.transition(
            sessionID: current.prepared.sessionID,
            from: current.lifecycle,
            to: .generating
        )
        let streamPair = LLMBackendEventStream.makeStream(
            bufferingPolicy: .bufferingOldest(32)
        )
        let generationID = UUID().uuidString.lowercased()
        let sessionID = current.prepared.sessionID
        let providerSession = current.providerSession
        let transport = self.transport
        let task = Task { [weak self] in
            guard let self else {
                streamPair.continuation.finish(throwing: cloudRuntimeFailure(
                    "runtime.cloud_session_released",
                    "cloud runtime was released during generation"
                ))
                return
            }
            await self.pumpGeneration(
                sessionID: sessionID,
                generationID: generationID,
                request: sealed,
                providerSession: providerSession,
                transport: transport,
                continuation: streamPair.continuation
            )
        }
        var next = current
        next.scopeGrant = authorized.scopeGrant
        next.lifecycle = .generating
        next.generationID = generationID
        next.generationTask = task
        next.cancelRequested = false
        self.active = next
        state = .generating
        streamPair.continuation.onTermination = { @Sendable [weak self] termination in
            guard case .cancelled = termination else { return }
            Task {
                _ = await self?.cancelGenerationOnce(
                    sessionID: sessionID,
                    generationID: generationID,
                    cancelPump: true
                )
            }
        }
        return streamPair.stream
    }

    private func pumpGeneration(
        sessionID: String,
        generationID: String,
        request: AuthorizedCloudHTTPRequest,
        providerSession: any CloudProviderSession,
        transport: any CloudHTTPTransport,
        continuation: LLMBackendEventStream.Continuation
    ) async {
        var emittedOutput = false
        var attempts = 0
        while attempts < 2 {
            attempts += 1
            do {
                let events = try await transport.stream(request)
                var sawTerminal = false
                for try await event in providerSession.decode(events) {
                    emittedOutput = true
                    try yieldRuntimeEvent(event, to: continuation)
                    switch event {
                    case let .generationCompleted(completion):
                        sawTerminal = true
                        try finishGeneration(
                            sessionID: sessionID,
                            generationID: generationID,
                            outcome: completion.outcome
                        )
                    case .cancelled:
                        sawTerminal = true
                        try finishGeneration(
                            sessionID: sessionID,
                            generationID: generationID,
                            outcome: nil
                        )
                    default:
                        break
                    }
                }
                guard sawTerminal else {
                    throw cloudRuntimeFailure(
                        "runtime.cloud_terminal_missing",
                        "cloud generation ended without a normalized terminal event",
                        retryable: true,
                        recoveryAction: .retry
                    )
                }
                continuation.finish()
                return
            } catch is CancellationError {
                _ = await cancelGenerationOnce(
                    sessionID: sessionID,
                    generationID: generationID,
                    cancelPump: false
                )
                try? finishGeneration(
                    sessionID: sessionID,
                    generationID: generationID,
                    outcome: nil
                )
                _ = continuation.yield(.cancelled)
                continuation.finish()
                return
            } catch {
                let retryable = (error as? LLMFailure)?.retryable == true
                if !emittedOutput, attempts < 2, retryable {
                    await Task.yield()
                    continue
                }
                if (error as? LLMFailure)?.code == "runtime.cloud_consumer_backpressure" {
                    _ = await cancelGenerationOnce(
                        sessionID: sessionID,
                        generationID: generationID,
                        cancelPump: false
                    )
                }
                try? failGeneration(
                    sessionID: sessionID,
                    generationID: generationID
                )
                continuation.finish(throwing: error)
                return
            }
        }
    }

    private func cancelGenerationOnce(
        sessionID: String,
        generationID: String,
        cancelPump: Bool
    ) async -> Task<Void, Never>? {
        guard var active,
              active.prepared.sessionID == sessionID,
              active.generationID == generationID,
              let task = active.generationTask
        else { return nil }
        guard !active.cancelRequested else { return task }
        active.cancelRequested = true
        self.active = active
        state = .cancelling
        await active.providerSession.cancel()
        if cancelPump { task.cancel() }
        return task
    }

    private func finishGeneration(
        sessionID: String,
        generationID: String,
        outcome: LLMGenerationOutcome?
    ) throws {
        guard var active,
              active.prepared.sessionID == sessionID,
              active.generationID == generationID
        else { return }
        let nextLifecycle: PreparedCloudSessionLifecycle = outcome == .toolCallsReady
            ? .awaitingToolResult
            : .terminal
        try sessionStore.transition(
            sessionID: sessionID,
            from: .generating,
            to: nextLifecycle
        )
        active.lifecycle = nextLifecycle
        active.generationID = nil
        active.generationTask = nil
        self.active = active
        state = nextLifecycle == .awaitingToolResult ? .awaitingToolResult : .terminal
    }

    private func failGeneration(
        sessionID: String,
        generationID: String
    ) throws {
        try finishGeneration(
            sessionID: sessionID,
            generationID: generationID,
            outcome: nil
        )
    }

}

package enum CloudRuntimeCapabilityGate {
    package static func require(
        _ snapshot: CapabilitySnapshot,
        toolSchema: CanonicalJSONValue
    ) throws {
        guard snapshot.support(for: "text_generation") == .supported else {
            throw cloudRuntimeFailure(
                "runtime.cloud_capability_unsatisfied",
                "validated cloud route does not support text generation"
            )
        }
        guard snapshot.support(for: "streaming") == .supported else {
            throw cloudRuntimeFailure(
                "runtime.cloud_capability_unsatisfied",
                "validated cloud route does not support streaming"
            )
        }
        guard try requestedToolCount(in: toolSchema) == 0
                || snapshot.support(for: "tool_calling") == .supported
        else {
            throw cloudRuntimeFailure(
                "runtime.cloud_capability_unsatisfied",
                "validated cloud route does not support the requested tools"
            )
        }
    }

    package static func requestedToolCount(
        in schema: CanonicalJSONValue
    ) throws -> Int {
        switch schema {
        case let .array(values):
            return values.count
        case .object:
            let keys = schema.objectKeys ?? []
            if keys.isEmpty { return 0 }
            guard keys == Set(["tools"]),
                  case let .array(values)? = schema.objectValue(forKey: "tools")
            else {
                throw cloudRuntimeFailure(
                    "runtime.cloud_tool_schema_invalid",
                    "canonical tool schema has an unsupported shape"
                )
            }
            return values.count
        default:
            throw cloudRuntimeFailure(
                "runtime.cloud_tool_schema_invalid",
                "canonical tool schema has an unsupported shape"
            )
        }
    }
}

private func yieldRuntimeEvent(
    _ event: LLMBackendEvent,
    to continuation: LLMBackendEventStream.Continuation
) throws {
    switch continuation.yield(event) {
    case .enqueued:
        return
    case .dropped:
        throw cloudRuntimeFailure(
            "runtime.cloud_consumer_backpressure",
            "cloud generation consumer exceeded its bounded event buffer"
        )
    case .terminated:
        throw CancellationError()
    @unknown default:
        throw cloudRuntimeFailure(
            "runtime.cloud_consumer_backpressure",
            "cloud generation consumer state is unknown"
        )
    }
}

private func preparedRegistrationDigest(
    preparationID: String,
    proposedRunID: String,
    sessionID: String,
    snapshotID: String,
    hostProcessEpoch: HostProcessEpoch,
    binding: HostBindingTuple,
    credentialUseLeaseDigest: String
) throws -> String {
    let document = try CanonicalJSONValue.object(entries: [
        .init(name: "binding_hash", value: .string(binding.bindingHash)),
        .init(name: "binding_id", value: .string(binding.bindingID)),
        .init(name: "binding_revision", value: .string(String(binding.bindingRevision))),
        .init(name: "credential_use_lease_digest", value: .string(credentialUseLeaseDigest)),
        .init(name: "host_process_epoch", value: .string(hostProcessEpoch.rawValue)),
        .init(name: "preparation_id", value: .string(preparationID)),
        .init(name: "proposed_run_id", value: .string(proposedRunID)),
        .init(name: "schema_version", value: .string("1")),
        .init(name: "session_handle", value: .string(sessionID)),
        .init(name: "swift_snapshot_id", value: .string(snapshotID)),
    ])
    return try CanonicalDigestV1.digest(
        domain: "prepared-session-registration:v1",
        document: document
    ).hex
}

private func cloudEgressAttestationDigest(
    preparationID: String,
    proposedRunID: String,
    sessionID: String,
    snapshotID: String,
    registrationDigest: String,
    binding: HostBindingTuple,
    requirementsHash: String,
    disclosureDigest: String,
    capabilitySnapshotDigest: String,
    resolvedParametersDigest: String,
    hostProcessEpoch: HostProcessEpoch,
    expiresAt: Date,
    opaqueEgressSubjectDigest: String
) throws -> String {
    let document = try CanonicalJSONValue.object(entries: [
        .init(name: "binding_hash", value: .string(binding.bindingHash)),
        .init(name: "binding_id", value: .string(binding.bindingID)),
        .init(name: "binding_revision", value: .string(String(binding.bindingRevision))),
        .init(name: "capability_snapshot_digest", value: .string(capabilitySnapshotDigest)),
        .init(name: "disclosure_digest", value: .string(disclosureDigest)),
        .init(name: "expires_at", value: .string(try cloudRuntimeTimestamp(expiresAt))),
        .init(name: "host_process_epoch", value: .string(hostProcessEpoch.rawValue)),
        .init(name: "opaque_egress_subject_digest", value: .string(opaqueEgressSubjectDigest)),
        .init(name: "preparation_id", value: .string(preparationID)),
        .init(name: "prepared_session_registration_digest", value: .string(registrationDigest)),
        .init(name: "proposed_run_id", value: .string(proposedRunID)),
        .init(name: "requirements_hash", value: .string(requirementsHash)),
        .init(name: "resolved_parameters_digest", value: .string(resolvedParametersDigest)),
        .init(name: "schema_version", value: .string("1")),
        .init(name: "session_id", value: .string(sessionID)),
        .init(name: "swift_snapshot_id", value: .string(snapshotID)),
    ])
    return try CanonicalDigestV1.digest(
        domain: "egress-attestation:v1",
        document: document
    ).hex
}

private func cloudRuntimeTimestamp(_ date: Date) throws -> String {
    let milliseconds = date.timeIntervalSince1970 * 1_000
    guard milliseconds.isFinite,
          abs(milliseconds - milliseconds.rounded()) < 0.000_1
    else {
        throw cloudRuntimeFailure(
            "runtime.cloud_timestamp_invalid",
            "cloud attestation expiry is not millisecond-canonical"
        )
    }
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"
    return formatter.string(from: date)
}

func cloudRuntimeFailure(
    _ code: String,
    _ message: String,
    retryable: Bool = false,
    recoveryAction: LLMRecoveryAction? = nil
) -> LLMFailure {
    LLMFailure(
        code: code,
        message: message,
        retryable: retryable,
        recoveryAction: recoveryAction
    )
}
