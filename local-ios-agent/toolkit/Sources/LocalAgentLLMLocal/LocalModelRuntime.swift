import Foundation
import LocalAgentLLMContracts
import LocalAgentLLMCore

package enum LocalModelRuntimeState: Equatable, Sendable {
    case idle
    case reserved
    case loading
    case ready
    case prepared
    case generating
    case awaitingToolResult
    case cancelling
    case sessionTerminal
    case unloading
    case quarantined
}

public struct LocalSessionPreparationContext: Equatable, Sendable {
    public let preparationID: String
    public let proposedRunID: String
    public let initialDisclosureDigest: String
    public let capabilityAttestationDigest: String
    public let attestationExpiresAt: String

    public init(
        preparationID: String,
        proposedRunID: String,
        initialDisclosureDigest: String,
        capabilityAttestationDigest: String,
        attestationExpiresAt: String
    ) {
        self.preparationID = preparationID
        self.proposedRunID = proposedRunID
        self.initialDisclosureDigest = initialDisclosureDigest
        self.capabilityAttestationDigest = capabilityAttestationDigest
        self.attestationExpiresAt = attestationExpiresAt
    }
}

public struct ReservedLocalSession: Codable, Equatable, Sendable {
    public let sessionID: String
    public let snapshotID: String
    public let preparationID: String
    public let proposedRunID: String
    public let targetID: LLMTargetID
    public let targetRevision: UInt64
    public let binding: HostBindingTuple
    public let requirementsHash: String
    public let capabilitySnapshot: CapabilitySnapshot
    public let capabilitySnapshotDigest: String
    public let resolvedConfiguration: GenerationConfiguration
    public let resolvedParametersDigest: String
    public let registrationDigest: String
    public let hostAttestation: HostAttestationV1Document
    public let egressSubjectDigest: String
    public let hostProcessEpoch: HostProcessEpoch
}

public actor LocalModelRuntime {
    private struct LoadedModel {
        let installationID: String
        let leaseID: String
        let manifest: LocalModelRevisionManifest
        let descriptor: CppEngineDescriptor
        let native: any CppLoadedModelAPI
    }

    private struct ActiveGeneration {
        let id: String
        let native: any CppGenerationAPI
    }

    private struct ActiveSession {
        let prepared: PreparedLocalSession
        let concreteOptions: [String: CanonicalJSONValue]
        var storeState: PreparedLocalSessionState
        var generation: ActiveGeneration?
        var pendingToolCalls: [NormalizedToolCall]
    }

    private struct Reservation {
        let publicValue: ReservedLocalSession
        let installation: LocalInstallationRecord
        let manifest: LocalModelRevisionManifest
        let descriptor: CppEngineDescriptor
        let concreteOptions: [String: CanonicalJSONValue]
    }

    private let store: LocalModelStore
    private let paths: LocalModelPaths
    private let bindingSaga: AgentHostBindingSaga
    private let inference: any CppInferenceAPI
    private let hostProcessEpoch: HostProcessEpoch
    private let appBuild: String
    private let devicePolicy: LocalDeviceGenerationPolicy
    private var catalog: AcceptedLocalModelCatalog
    private var loaded: LoadedModel?
    private var reservation: Reservation?
    private var active: ActiveSession?
    package private(set) var state: LocalModelRuntimeState = .idle

    package init(
        store: LocalModelStore,
        paths: LocalModelPaths,
        catalog: AcceptedLocalModelCatalog,
        bindingSaga: AgentHostBindingSaga,
        inference: any CppInferenceAPI,
        hostProcessEpoch: HostProcessEpoch,
        appBuild: String,
        devicePolicy: LocalDeviceGenerationPolicy = LocalDeviceGenerationPolicy()
    ) {
        self.store = store
        self.paths = paths
        self.catalog = catalog
        self.bindingSaga = bindingSaga
        self.inference = inference
        self.hostProcessEpoch = hostProcessEpoch
        self.appBuild = appBuild
        self.devicePolicy = devicePolicy
    }

    public func prepareSession(
        hostConfiguration: AgentHostConfiguration,
        target: LLMTargetRevision
    ) async throws -> PreparedLocalSession {
        let identity = try PreparedLocalSession.generateSessionID()
        let reserved = try await reserveSession(
            context: LocalSessionPreparationContext(
                preparationID: "legacy-\(identity)",
                proposedRunID: "legacy-run-\(identity)",
                initialDisclosureDigest: String(repeating: "0", count: 64),
                capabilityAttestationDigest: String(repeating: "0", count: 64),
                attestationExpiresAt: "2100-01-01T00:00:00.000Z"
            ),
            hostConfiguration: hostConfiguration,
            target: target
        )
        return try await openReservedSession(reserved)
    }

    public func reserveSession(
        context: LocalSessionPreparationContext,
        hostConfiguration: AgentHostConfiguration,
        target: LLMTargetRevision
    ) async throws -> ReservedLocalSession {
        guard active == nil, reservation == nil else {
            throw failure("runtime.local_session_busy", "close the current local session before preparing another")
        }
        guard state != .quarantined else {
            throw failure("runtime.local_runtime_quarantined", "local runtime cleanup is incomplete")
        }
        guard !context.preparationID.isEmpty, !context.proposedRunID.isEmpty else {
            throw failure("runtime.local_preparation_invalid", "local preparation identity is empty")
        }
        let binding: HostBindingTuple
        do {
            binding = try await bindingSaga.requireActive(
                configuration: hostConfiguration,
                target: target
            )
        } catch let error as HostBindingSagaError {
            throw failure(error.code, error.message)
        }
        guard case let .local(installationID) = target.kind else {
            throw failure("runtime.local_target_required", "local runtime requires a local target")
        }
        guard let installation = try store.installationRecord(installationID: installationID),
              installation.state == .installed,
              installation.modelRevision.modelID == target.modelID,
              catalog.verified.disposition(for: installation.modelRevision) == .available,
              let manifest = catalog.verified.models[installation.modelRevision],
              manifest.id.modelID == target.modelID
        else {
            throw failure(
                "runtime.local_target_not_runnable",
                "local target is not pinned to an installed active catalog revision"
            )
        }
        let descriptor = try requiredDescriptor(for: manifest)
        let subject = CapabilitySubject(
            engineID: descriptor.engineID,
            llmTargetID: target.targetID,
            llmTargetRevision: target.revision,
            modelID: manifest.id.modelID,
            modelRevision: String(manifest.id.revision),
            catalogRevision: catalog.verified.catalogRevision
        )
        let now = Date()
        let modelObservations = try LocalCapabilityObservationFactory.observations(
            for: manifest.id,
            in: catalog.verified,
            engineVersion: descriptor.engineVersion,
            appBuild: appBuild,
            observedAt: now,
            targetID: target.targetID,
            targetRevision: target.revision
        )
        let engineObservations = try LocalCapabilityObservationFactory.engineObservations(
            descriptor: descriptor,
            manifest: manifest,
            subject: subject,
            appBuild: appBuild,
            observedAt: now
        )
        let capabilitySnapshot = CapabilityMatrix.resolve(
            observations: modelObservations + engineObservations,
            subject: subject,
            policy: .local,
            now: now
        )
        guard manifest.declaredCapabilities.allSatisfy({
            capabilitySnapshot.support(for: $0.capabilityID) == .supported
        }) else {
            throw failure(
                "runtime.local_capability_unverified",
                "signed model and compiled engine capabilities do not intersect"
            )
        }
        let resolved = try LocalGenerationConfigurationResolver.resolve(
            catalogDefaults: manifest.parameterDefaults,
            targetDefaults: target.defaultParameters,
            hostOverrides: hostConfiguration.parameterOverrides,
            schema: manifest.parameterSchema,
            engineParameters: descriptor.capabilities.backendParameters,
            devicePolicy: devicePolicy
        )
        let sessionID = try PreparedLocalSession.generateSessionID()
        let snapshotID = "local-snapshot-\(sessionID)"
        let capabilityDigest = try capabilitySnapshotDigest(capabilitySnapshot)
        let parametersDigest = try resolvedParametersDigest(
            semantic: resolved.semantic,
            concrete: resolved.concreteOptions,
            descriptor: descriptor
        )
        let registrationDigest = try PreparedSessionRegistrationV1Document(
            preparationID: context.preparationID,
            proposedRunID: context.proposedRunID,
            sessionHandle: sessionID,
            swiftSnapshotID: snapshotID,
            hostProcessEpoch: hostProcessEpoch.rawValue,
            bindingID: binding.bindingID,
            bindingRevision: binding.bindingRevision,
            bindingHash: binding.bindingHash
        ).computedDigest().hex
        let egressSubjectDigest = try LocalEgressSubjectV1.notApplicableDigest().hex
        let hostAttestation = HostAttestationV1Document(
            preparationID: context.preparationID,
            proposedRunID: context.proposedRunID,
            sessionID: sessionID,
            swiftSnapshotID: snapshotID,
            preparedSessionRegistrationDigest: registrationDigest,
            bindingID: binding.bindingID,
            bindingRevision: String(binding.bindingRevision),
            bindingHash: binding.bindingHash,
            requirementsHash: hostConfiguration.requirementsHash,
            disclosureDigest: context.initialDisclosureDigest,
            capabilitySnapshotDigest: context.capabilityAttestationDigest,
            resolvedParametersDigest: parametersDigest,
            hostProcessEpoch: hostProcessEpoch.rawValue,
            expiresAt: context.attestationExpiresAt,
            opaqueEgressSubjectDigest: egressSubjectDigest
        )
        let reserved = ReservedLocalSession(
            sessionID: sessionID,
            snapshotID: snapshotID,
            preparationID: context.preparationID,
            proposedRunID: context.proposedRunID,
            targetID: target.targetID,
            targetRevision: target.revision,
            binding: binding,
            requirementsHash: hostConfiguration.requirementsHash,
            capabilitySnapshot: capabilitySnapshot,
            capabilitySnapshotDigest: capabilityDigest,
            resolvedConfiguration: resolved.semantic,
            resolvedParametersDigest: parametersDigest,
            registrationDigest: registrationDigest,
            hostAttestation: hostAttestation,
            egressSubjectDigest: egressSubjectDigest,
            hostProcessEpoch: hostProcessEpoch
        )
        let pending = Reservation(
            publicValue: reserved,
            installation: installation,
            manifest: manifest,
            descriptor: descriptor,
            concreteOptions: resolved.concreteOptions
        )
        try store.persistReservedLocalSession(reserved)
        reservation = pending
        state = .reserved
        return reserved
    }

    public func openReservedSession(
        _ expected: ReservedLocalSession
    ) async throws -> PreparedLocalSession {
        guard let reservation,
              reservation.publicValue == expected,
              active == nil,
              state == .reserved
        else {
            throw failure(
                "runtime.local_reservation_changed",
                "local reservation is missing or changed"
            )
        }
        let installation = reservation.installation
        let installationID = installation.installationID
        let manifest = reservation.manifest
        let descriptor = reservation.descriptor
        var loadedDuringPreparation = false
        if let loaded, loaded.installationID != installationID {
            try unloadLoadedModel()
        }
        if loaded == nil {
            state = .loading
            let leaseID = "loaded-\(try PreparedLocalSession.generateSessionID())"
            let lease = LocalModelUseLease(
                leaseID: leaseID,
                installationID: installationID,
                purpose: .loaded,
                hostProcessEpoch: hostProcessEpoch,
                state: .active,
                leaseRevision: 1
            )
            try store.acquireModelUseLease(lease)
            do {
                let native = try inference.load(try loadRequest(manifest: manifest, installationID: installationID))
                loaded = LoadedModel(
                    installationID: installationID,
                    leaseID: leaseID,
                    manifest: manifest,
                    descriptor: descriptor,
                    native: native
                )
                loadedDuringPreparation = true
                state = .ready
            } catch {
                try? store.releaseModelUseLease(leaseID: leaseID)
                loaded = nil
                state = .idle
                throw error
            }
        }
        guard let loaded else {
            throw failure("runtime.local_load_failed", "local model was not retained after loading")
        }

        let sessionID = expected.sessionID
        let activeLeaseID = "session-\(try PreparedLocalSession.generateSessionID())"
        let prepared = PreparedLocalSession(
            sessionID: sessionID,
            targetID: expected.targetID,
            targetRevision: expected.targetRevision,
            binding: expected.binding,
            requirementsHash: expected.requirementsHash,
            installationID: installationID,
            installationStateRevision: installation.stateRevision,
            modelRevision: manifest.id,
            catalogRevision: catalog.verified.catalogRevision,
            capabilitySnapshot: expected.capabilitySnapshot,
            capabilitySnapshotDigest: expected.capabilitySnapshotDigest,
            resolvedConfiguration: expected.resolvedConfiguration,
            resolvedParametersDigest: expected.resolvedParametersDigest,
            template: manifest.chatTemplate,
            toolCallCodecID: manifest.toolCallCodecID,
            hostProcessEpoch: hostProcessEpoch,
            loadedModelLeaseID: loaded.leaseID,
            activeSessionLeaseID: activeLeaseID
        )
        let activeLease = LocalModelUseLease(
            leaseID: activeLeaseID,
            installationID: installationID,
            purpose: .activeSession,
            hostProcessEpoch: hostProcessEpoch,
            state: .active,
            leaseRevision: 1
        )
        do {
            try store.persistPreparedLocalSession(
                prepared,
                activeSessionLease: activeLease,
                consumesReservation: true
            )
        } catch {
            if loadedDuringPreparation {
                do {
                    try loaded.native.unload()
                    try store.releaseModelUseLease(leaseID: loaded.leaseID)
                    self.loaded = nil
                    state = .idle
                } catch {
                    state = .quarantined
                }
            }
            throw error
        }
        active = ActiveSession(
            prepared: prepared,
            concreteOptions: reservation.concreteOptions,
            storeState: .prepared,
            generation: nil,
            pendingToolCalls: []
        )
        self.reservation = nil
        state = .prepared
        return prepared
    }

    public func abortReservedSession(_ expected: ReservedLocalSession) async {
        guard reservation?.publicValue == expected else { return }
        try? store.deleteReservedLocalSession(sessionID: expected.sessionID)
        reservation = nil
        state = loaded == nil ? .idle : .ready
    }

    public func cleanupReservedOrOpenedSession(
        _ expected: ReservedLocalSession
    ) async {
        if reservation?.publicValue == expected {
            await abortReservedSession(expected)
        } else if active?.prepared.sessionID == expected.sessionID {
            try? await closeSession(sessionID: expected.sessionID)
        }
    }

    public func startGeneration(
        sessionID: String,
        input: AgentLLMInput,
        attachments: [LocalResolvedAttachment],
        toolSchema: CanonicalJSONValue?
    ) async throws -> LLMBackendEventSequence {
        guard let active,
              active.prepared.sessionID == sessionID,
              active.storeState == .prepared,
              active.generation == nil,
              state == .prepared
        else {
            throw failure("runtime.local_generation_state_invalid", "local session is not ready to start")
        }
        return try beginGeneration(
            session: active,
            input: input,
            attachments: attachments,
            toolSchema: toolSchema
        )
    }

    public func resumeGeneration(
        sessionID: String,
        input: AgentLLMInput,
        attachments: [LocalResolvedAttachment],
        toolSchema: CanonicalJSONValue?
    ) async throws -> LLMBackendEventSequence {
        guard var active,
              active.prepared.sessionID == sessionID,
              active.storeState == .awaitingToolResult,
              active.generation == nil,
              state == .awaitingToolResult
        else {
            throw failure("runtime.local_resume_state_invalid", "local session is not awaiting tool results")
        }
        let continuation = try localContinuationInput(
            input,
            pendingToolCalls: active.pendingToolCalls
        )
        active.pendingToolCalls = []
        return try beginGeneration(
            session: active,
            input: continuation,
            attachments: attachments,
            toolSchema: toolSchema
        )
    }

    public func cancel(sessionID: String) async throws {
        guard var active, active.prepared.sessionID == sessionID else {
            throw failure("runtime.local_session_not_found", "prepared local session was not found")
        }
        guard let generation = active.generation else { return }
        state = .cancelling
        do {
            try generation.native.cancel()
            try generation.native.release()
            active.generation = nil
            try transitionToTerminal(&active)
            self.active = active
            state = .sessionTerminal
        } catch {
            self.active = active
            state = .quarantined
            throw error
        }
    }

    public func closeSession(sessionID: String) async throws {
        guard let current = active, current.prepared.sessionID == sessionID else {
            throw failure("runtime.local_session_not_found", "prepared local session was not found")
        }
        if current.generation != nil {
            try await cancel(sessionID: sessionID)
        }
        guard state != .quarantined else {
            throw failure("runtime.local_runtime_quarantined", "native session cleanup is uncertain")
        }
        try store.closePreparedLocalSession(sessionID: sessionID)
        active = nil
        state = loaded == nil ? .idle : .ready
    }

    public func unload() async throws {
        guard active == nil else {
            throw failure("runtime.local_session_busy", "close the local session before unloading")
        }
        try unloadLoadedModel()
    }

    public func unloadForRouteSwitch() async throws {
        if let sessionID = active?.prepared.sessionID {
            try await closeSession(sessionID: sessionID)
        }
        try unloadLoadedModel()
    }

    public func handleCriticalMemoryPressure() async {
        do { try await unloadForRouteSwitch() } catch { state = .quarantined }
    }

    package func replaceCatalog(_ catalog: AcceptedLocalModelCatalog) async throws {
        self.catalog = catalog
        guard let active,
              catalog.verified.disposition(for: active.prepared.modelRevision) == .revoked
        else { return }
        if active.generation != nil {
            try await cancel(sessionID: active.prepared.sessionID)
        } else {
            var terminal = active
            try transitionToTerminal(&terminal)
            self.active = terminal
            state = .sessionTerminal
        }
    }

    private func beginGeneration(
        session: ActiveSession,
        input: AgentLLMInput,
        attachments: [LocalResolvedAttachment],
        toolSchema: CanonicalJSONValue?
    ) throws -> LLMBackendEventSequence {
        guard catalog.verified.disposition(for: session.prepared.modelRevision) == .available,
              let loaded,
              loaded.installationID == session.prepared.installationID
        else {
            var terminal = session
            try transitionToTerminal(&terminal)
            active = terminal
            state = .sessionTerminal
            throw failure("runtime.local_catalog_revision_unavailable", "pinned local model revision is no longer runnable")
        }
        guard attachments.isEmpty
            || session.prepared.capabilitySnapshot.support(for: "image_input") == .supported
        else {
            throw failure(
                "runtime.local_image_input_unsupported",
                "the selected local model does not support image input"
            )
        }
        let request = CppGenerationRequest(
            input: input,
            attachments: attachments,
            canonicalToolSchema: toolSchema,
            template: session.prepared.template,
            toolCallCodecID: toolSchema == nil ? nil : session.prepared.toolCallCodecID,
            concreteOptions: session.concreteOptions
        )
        do {
            try loaded.native.validateGeneration(request)
            let native = try loaded.native.start(request)
            let generationID = UUID().uuidString.lowercased()
            var next = session
            next.generation = ActiveGeneration(id: generationID, native: native)
            active = next
            state = .generating
            let sessionID = session.prepared.sessionID
            return LLMBackendEventSequence(
                native: native.events,
                toolCallCodecID: request.toolCallCodecID,
                terminal: { [weak self] terminal in
                    guard let self else { return }
                    try await self.finishGeneration(
                        sessionID: sessionID,
                        generationID: generationID,
                        terminal: terminal
                    )
                }
            )
        } catch {
            var terminal = session
            try? transitionToTerminal(&terminal)
            active = terminal
            state = .sessionTerminal
            throw error
        }
    }

    private func finishGeneration(
        sessionID: String,
        generationID: String,
        terminal: LocalGenerationTerminal
    ) throws {
        guard var active,
              active.prepared.sessionID == sessionID,
              let generation = active.generation,
              generation.id == generationID
        else { return }
        do {
            try generation.native.release()
            active.generation = nil
            switch terminal {
            case let .completed(.toolCallsReady, toolCalls):
                if active.storeState == .prepared {
                    try store.transitionPreparedLocalSession(
                        sessionID: sessionID,
                        from: .prepared,
                        to: .awaitingToolResult
                    )
                }
                active.storeState = .awaitingToolResult
                active.pendingToolCalls = toolCalls
                state = .awaitingToolResult
            case .completed(.finalResponse, _), .cancelled, .failed:
                try transitionToTerminal(&active)
                state = .sessionTerminal
            }
            self.active = active
        } catch {
            self.active = active
            state = .quarantined
            throw error
        }
    }

    private func transitionToTerminal(_ session: inout ActiveSession) throws {
        guard session.storeState != .terminal else { return }
        try store.transitionPreparedLocalSession(
            sessionID: session.prepared.sessionID,
            from: session.storeState,
            to: .terminal
        )
        session.storeState = .terminal
    }

    private func unloadLoadedModel() throws {
        guard let loaded else {
            state = .idle
            return
        }
        state = .unloading
        do {
            try loaded.native.unload()
            try store.releaseModelUseLease(leaseID: loaded.leaseID)
            self.loaded = nil
            state = .idle
        } catch {
            state = .quarantined
            throw error
        }
    }

    private func requiredDescriptor(
        for manifest: LocalModelRevisionManifest
    ) throws -> CppEngineDescriptor {
        guard let descriptor = try inference.listEngines().first(where: {
            $0.engineID == manifest.engineID && !$0.testOnly
        }),
            descriptor.abiVersion == "2",
            descriptor.capabilities.supportedModelFormats.contains(manifest.modelFormat),
            descriptor.capabilities.maxContextTokens.map({ $0 >= manifest.loadTemplate.contextTokens }) ?? true
        else {
            throw failure("runtime.local_engine_incompatible", "compiled engine cannot load the signed model revision")
        }
        return descriptor
    }

    private func loadRequest(
        manifest: LocalModelRevisionManifest,
        installationID: String
    ) throws -> CppModelLoadRequest {
        var artifacts: [String: String] = [:]
        for artifact in manifest.artifacts {
            artifacts[artifact.role.rawValue] = try paths.installedArtifact(
                installationID: installationID,
                relativePath: artifact.relativePath
            ).path
        }
        return CppModelLoadRequest(
            engineID: manifest.engineID,
            modelID: manifest.id.modelID,
            modelFormat: manifest.modelFormat,
            artifactPathsByRole: artifacts,
            contextTokens: manifest.loadTemplate.contextTokens,
            manifestLoadOptions: manifest.loadTemplate.manifestControlledOptions,
            template: manifest.chatTemplate,
            toolCallCodecID: manifest.toolCallCodecID
        )
    }
}

private func capabilitySnapshotDigest(_ snapshot: CapabilitySnapshot) throws -> String {
    let capabilities = try CanonicalJSONValue.object(entries: snapshot.capabilities.map {
        .init(name: $0.key, value: try .object(entries: [
            .init(name: "support", value: .string($0.value.support.rawValue)),
            .init(
                name: "verified_upper_bound",
                value: $0.value.verifiedUpperBound.map { .string(String($0)) } ?? .null
            ),
        ]))
    })
    let subject = snapshot.subject
    let subjectDocument = try CanonicalJSONValue.object(entries: [
        .init(name: "adapter_id", value: optional(subject.adapterID)),
        .init(name: "engine_id", value: optional(subject.engineID)),
        .init(name: "provider_profile_id", value: optional(subject.providerProfileID)),
        .init(name: "provider_profile_revision", value: optional(subject.providerProfileRevision)),
        .init(name: "credential_generation", value: optional(subject.credentialGeneration)),
        .init(name: "llm_target_id", value: optional(subject.llmTargetID?.rawValue)),
        .init(name: "llm_target_revision", value: optional(subject.llmTargetRevision)),
        .init(name: "model_id", value: optional(subject.modelID)),
        .init(name: "model_revision", value: optional(subject.modelRevision)),
        .init(name: "catalog_revision", value: optional(subject.catalogRevision)),
    ])
    let document = try CanonicalJSONValue.object(entries: [
        .init(name: "schema_version", value: .string("1")),
        .init(name: "subject", value: subjectDocument),
        .init(name: "capabilities", value: capabilities),
        .init(
            name: "contributing_observation_digests",
            value: .array(snapshot.contributingObservationDigests.map(CanonicalJSONValue.string))
        ),
        .init(
            name: "nearest_expiry",
            value: snapshot.nearestExpiry.map { .string(iso8601($0)) } ?? .null
        ),
    ])
    return try CanonicalDigestV1.digest(
        domain: "capability-snapshot:v1",
        document: document
    ).hex
}

private func resolvedParametersDigest(
    semantic: GenerationConfiguration,
    concrete: [String: CanonicalJSONValue],
    descriptor: CppEngineDescriptor
) throws -> String {
    let semanticValue = try CanonicalJSONValue.object(entries: semantic.parameters.map {
        .init(name: $0.key, value: try parameterDocument($0.value))
    })
    return try CanonicalDigestV1.digest(
        domain: "resolved-parameters:v1",
        document: .object(entries: [
            .init(name: "schema_version", value: .string("1")),
            .init(name: "semantic", value: semanticValue),
            .init(name: "concrete", value: try .object(entries: concrete.map {
                .init(name: $0.key, value: $0.value)
            })),
            .init(name: "engine_id", value: .string(descriptor.engineID)),
            .init(name: "engine_version", value: .string(descriptor.engineVersion)),
        ])
    ).hex
}

private func parameterDocument(_ value: LLMParameterValue) throws -> CanonicalJSONValue {
    switch value {
    case let .decimal(number):
        return try .object(entries: [
            .init(name: "type", value: .string("decimal")),
            .init(name: "value", value: .number(number)),
        ])
    case let .integer(number):
        return try .object(entries: [
            .init(name: "type", value: .string("integer")),
            .init(name: "value", value: .string(String(number))),
        ])
    case let .text(text):
        return try .object(entries: [
            .init(name: "type", value: .string("text")),
            .init(name: "value", value: .string(text)),
        ])
    case let .boolean(flag):
        return try .object(entries: [
            .init(name: "type", value: .string("boolean")),
            .init(name: "value", value: .bool(flag)),
        ])
    case let .textList(values):
        return try .object(entries: [
            .init(name: "type", value: .string("text_list")),
            .init(name: "value", value: .array(values.map(CanonicalJSONValue.string))),
        ])
    }
}

private func optional(_ value: String?) -> CanonicalJSONValue {
    value.map(CanonicalJSONValue.string) ?? .null
}

private func optional(_ value: UInt64?) -> CanonicalJSONValue {
    value.map { .string(String($0)) } ?? .null
}

private func iso8601(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    return formatter.string(from: date)
}

private func failure(_ code: String, _ message: String) -> LLMFailure {
    LLMFailure(code: code, message: message, retryable: false)
}
