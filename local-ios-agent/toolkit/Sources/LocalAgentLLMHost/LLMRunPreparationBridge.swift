import Foundation
import LocalAgentBridge

package protocol LLMRunPreparationRustClient: Sendable {
    func previewRun(
        _ request: PreviewRunPreparationRequestDTO
    ) async throws -> RunPreparationPreviewDTO

    func registerPreparedSession(
        _ request: RegisterPreparedSessionRequestDTO
    ) async throws

    func renewPreparation(
        _ request: RenewRunPreparationRequestDTO
    ) async throws -> RunPreparationPreviewDTO

    func commitPreparedStart(
        _ request: CommitPreparedStartRequestDTO
    ) async throws -> HostRunHandleDTO

    func reconcilePreparation(
        _ request: ReconcilePreparationRequestDTO
    ) async throws -> PreparationReconciliationDTO

    func beginAbortPreparation(
        _ request: BeginAbortPreparationRequestDTO
    ) async throws

    func isAuthoritativeRejection(_ error: Error) -> Bool
    func isPreparationAlreadyCommitted(_ error: Error) -> Bool
}

package extension LLMRunPreparationRustClient {
    func isPreparationAlreadyCommitted(_ error: Error) -> Bool { false }
}

package struct RustGatewayRunPreparationClient: LLMRunPreparationRustClient {
    private let gateway: any RustAgentOSBridgeGateway

    package init(gateway: any RustAgentOSBridgeGateway) {
        self.gateway = gateway
    }

    package func previewRun(
        _ request: PreviewRunPreparationRequestDTO
    ) async throws -> RunPreparationPreviewDTO {
        try await gateway.request(
            .previewRunPreparation,
            request,
            as: RunPreparationPreviewDTO.self
        )
    }

    package func registerPreparedSession(
        _ request: RegisterPreparedSessionRequestDTO
    ) async throws {
        _ = try await gateway.request(
            .registerPreparedSession,
            request,
            as: RunPreparationRecordDTO.self
        )
    }

    package func renewPreparation(
        _ request: RenewRunPreparationRequestDTO
    ) async throws -> RunPreparationPreviewDTO {
        try await gateway.request(
            .renewRunPreparation,
            request,
            as: RunPreparationPreviewDTO.self
        )
    }

    package func commitPreparedStart(
        _ request: CommitPreparedStartRequestDTO
    ) async throws -> HostRunHandleDTO {
        try await gateway.request(
            .commitPreparedStart,
            request,
            as: HostRunHandleDTO.self
        )
    }

    package func reconcilePreparation(
        _ request: ReconcilePreparationRequestDTO
    ) async throws -> PreparationReconciliationDTO {
        try await gateway.request(
            .reconcilePreparation,
            request,
            as: PreparationReconciliationDTO.self
        )
    }

    package func beginAbortPreparation(
        _ request: BeginAbortPreparationRequestDTO
    ) async throws {
        _ = try await gateway.request(
            .beginAbortPreparation,
            request,
            as: RunPreparationRecordDTO.self
        )
    }

    package func isAuthoritativeRejection(_ error: Error) -> Bool {
        guard let error = error as? RuntimeBridgeError else { return false }
        return error.kind.hasPrefix("preparation.")
    }

    package func isPreparationAlreadyCommitted(_ error: Error) -> Bool {
        (error as? RuntimeBridgeError)?.kind == "preparation.already_committed"
    }
}

package struct LLMRunPreparationBridge: Sendable {
    private let rust: any LLMRunPreparationRustClient
    private let registry: LLMBridgeActor
    private let reserver: any LLMHostSessionReserving
    private let nowMillis: @Sendable () -> UInt64

    package init(
        rust: any LLMRunPreparationRustClient,
        registry: LLMBridgeActor,
        reserver: any LLMHostSessionReserving,
        nowMillis: @escaping @Sendable () -> UInt64
    ) {
        self.rust = rust
        self.registry = registry
        self.reserver = reserver
        self.nowMillis = nowMillis
    }

    package func prepareAndCommit(
        startRequest: PreviewRunPreparationRequestDTO
    ) async throws -> HostRunHandleDTO {
        var preview = try await rust.previewRun(startRequest)
        let reserved = try await reserver.reserve(preview: preview)
        preview = try await renewIfNeeded(preview)
        let handle = reserved.allocation.sessionHandle

        try await registry.allocate(reserved.allocation)
        try await registry.beginRegistration(handle)
        do {
            try await rust.registerPreparedSession(RegisterPreparedSessionRequestDTO(
                token: preview.token,
                registration: reserved.registration,
                nowMillis: nowMillis()
            ))
            try await registry.markRegistered(handle)
        } catch {
            try? await abort(preview, reason: .preparationFailed)
            throw error
        }

        let opened: OpenedHostSession
        do {
            try await registry.beginOpen(handle)
            opened = try await reserved.open()
            try await registry.installOpenedDriver(opened.driver, for: handle)
            preview = try await renewIfNeeded(preview)
        } catch {
            try? await abort(preview, reason: .preparationFailed)
            throw error
        }

        let attestation = HostAttestationDTO(
            document: opened.prepared.hostAttestation,
            preparationBindingDigest: preview.bindingDigest,
            egressAttestationDigest: opened.prepared.egressAttestationDigest,
            disclosureGrantId: opened.prepared.disclosureGrantID,
            dataClasses: opened.prepared.dataClasses,
            highestSensitivity: opened.prepared.highestSensitivity,
            capabilityAttestation: opened.prepared.publicCapabilityAttestation
        )
        try await registry.beginCommit(handle)

        do {
            let run = try await rust.commitPreparedStart(CommitPreparedStartRequestDTO(
                token: preview.token,
                attestation: attestation,
                nowMillis: nowMillis()
            ))
            try await registry.markCommitted(handle)
            return run
        } catch {
            if rust.isAuthoritativeRejection(error) {
                try? await abort(preview, reason: .commitRejected)
                throw error
            }
            try await registry.markCommitOutcomeUnknown(handle)
            return try await reconcileUnknownCommit(
                preview: preview,
                handle: handle,
                originalError: error
            )
        }
    }

    private func reconcileUnknownCommit(
        preview: RunPreparationPreviewDTO,
        handle: String,
        originalError: Error
    ) async throws -> HostRunHandleDTO {
        let request = ReconcilePreparationRequestDTO(
            preparationID: preview.preparationId,
            proposedRunID: preview.proposedRunId,
            tokenDigest: preview.tokenDigest
        )
        let outcome: PreparationReconciliationDTO
        do {
            outcome = try await rust.reconcilePreparation(request)
        } catch {
            throw LLMHostFailure(
                code: "execution.commit_outcome_unknown",
                message: "commit outcome could not be reconciled"
            )
        }

        switch outcome.status {
        case .committed:
            guard let run = outcome.handle else {
                throw invalidReconciliation()
            }
            try await registry.applyReconciliation(outcome, to: handle)
            return run

        case .pending:
            try await registry.applyReconciliation(outcome, to: handle)
            do {
                try await abort(preview, reason: .commitRejected)
            } catch where rust.isPreparationAlreadyCommitted(error) {
                let committed = try await rust.reconcilePreparation(request)
                guard committed.status == .committed, let run = committed.handle else {
                    throw invalidReconciliation()
                }
                try await registry.applyReconciliation(committed, to: handle)
                return run
            }
            throw originalError

        case .aborting:
            try await registry.applyReconciliation(outcome, to: handle)
            throw originalError
        }
    }

    private func abort(
        _ preview: RunPreparationPreviewDTO,
        reason: PreparationAbortReasonDTO
    ) async throws {
        try await rust.beginAbortPreparation(BeginAbortPreparationRequestDTO(
            preparationId: preview.preparationId,
            token: preview.token,
            idempotencyKey: "abort:\(preview.preparationId):\(reason.rawValue)",
            reason: reason
        ))
    }

    private func renewIfNeeded(
        _ preview: RunPreparationPreviewDTO
    ) async throws -> RunPreparationPreviewDTO {
        let now = nowMillis()
        guard now.saturatingAdding(30_000) >= preview.expirationMillis else {
            return preview
        }
        return try await rust.renewPreparation(RenewRunPreparationRequestDTO(
            token: preview.token,
            bindingDigest: preview.bindingDigest,
            idempotencyKey: "renew:\(preview.preparationId):\(preview.tokenGeneration)",
            nowMillis: now
        ))
    }

    private func invalidReconciliation() -> LLMHostFailure {
        LLMHostFailure(
            code: "preparation.reconciliation_payload_invalid",
            message: "reconciliation payload does not match its declared status"
        )
    }
}

private extension UInt64 {
    func saturatingAdding(_ value: UInt64) -> UInt64 {
        let (sum, overflow) = addingReportingOverflow(value)
        return overflow ? .max : sum
    }
}
