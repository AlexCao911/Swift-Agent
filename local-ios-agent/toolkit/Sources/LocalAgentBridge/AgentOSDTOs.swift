import Foundation
import LocalAgentLLMContracts

public struct ProfilePublishPreparationDTO: Codable, Equatable, Sendable {
    public let idempotencyKey: String
    public let agentProfileId: String
    public let agentProfileRevision: UInt64
    public let llmSlotId: String
    public let requirementsHash: String
    public init(idempotencyKey: String, agentProfileId: String, agentProfileRevision: UInt64, llmSlotId: String, requirementsHash: String) {
        self.idempotencyKey = idempotencyKey; self.agentProfileId = agentProfileId
        self.agentProfileRevision = agentProfileRevision; self.llmSlotId = llmSlotId; self.requirementsHash = requirementsHash
    }
    private enum CodingKeys: String, CodingKey { case idempotencyKey = "idempotency_key", agentProfileId = "agent_profile_id", agentProfileRevision = "agent_profile_revision", llmSlotId = "llm_slot_id", requirementsHash = "requirements_hash" }
}

public struct PackageBindingPreparationDTO: Codable, Equatable, Sendable {
    public let idempotencyKey: String; public let installationId: String; public let agentProfileId: String
    public let agentProfileRevision: UInt64; public let llmSlotId: String; public let requirementsHash: String
    public init(idempotencyKey: String, installationId: String, agentProfileId: String, agentProfileRevision: UInt64, llmSlotId: String, requirementsHash: String) {
        self.idempotencyKey = idempotencyKey; self.installationId = installationId; self.agentProfileId = agentProfileId
        self.agentProfileRevision = agentProfileRevision; self.llmSlotId = llmSlotId; self.requirementsHash = requirementsHash
    }
    private enum CodingKeys: String, CodingKey { case idempotencyKey = "idempotency_key", installationId = "installation_id", agentProfileId = "agent_profile_id", agentProfileRevision = "agent_profile_revision", llmSlotId = "llm_slot_id", requirementsHash = "requirements_hash" }
}

public struct HostBindingTupleDTO: Codable, Equatable, Sendable {
    public let bindingId: String; public let bindingRevision: UInt64; public let bindingHash: String
    public init(bindingId: String, bindingRevision: UInt64, bindingHash: String) { self.bindingId = bindingId; self.bindingRevision = bindingRevision; self.bindingHash = bindingHash }
    private enum CodingKeys: String, CodingKey { case bindingId = "binding_id", bindingRevision = "binding_revision", bindingHash = "binding_hash" }
}

public struct HostBindingStagingReceiptDTO: Codable, Equatable, Sendable {
    public let tokenDigest: String; public let llmSlotId: String; public let requirementsHash: String
    public let binding: HostBindingTupleDTO; public let receiptDigest: String
    public init(tokenDigest: String, llmSlotId: String, requirementsHash: String, binding: HostBindingTupleDTO, receiptDigest: String) {
        self.tokenDigest = tokenDigest; self.llmSlotId = llmSlotId; self.requirementsHash = requirementsHash; self.binding = binding; self.receiptDigest = receiptDigest
    }
    private enum CodingKeys: String, CodingKey { case tokenDigest = "token_digest", llmSlotId = "llm_slot_id", requirementsHash = "requirements_hash", binding, receiptDigest = "receipt_digest" }
}

public struct HostBindingCommitDTO: Codable, Equatable, Sendable {
    public let token: String; public let binding: HostBindingTupleDTO; public let receipt: HostBindingStagingReceiptDTO
    public init(token: String, binding: HostBindingTupleDTO, receipt: HostBindingStagingReceiptDTO) { self.token = token; self.binding = binding; self.receipt = receipt }
}

public struct HostBindingActivationConfirmationDTO: Codable, Equatable, Sendable {
    public let agentProfileId: String
    public let agentProfileRevision: UInt64
    public let llmSlotId: String
    public let requirementsHash: String
    public let binding: HostBindingTupleDTO
    public let stagingReceiptDigest: String
    public init(agentProfileId: String, agentProfileRevision: UInt64, llmSlotId: String, requirementsHash: String, binding: HostBindingTupleDTO, stagingReceiptDigest: String) {
        self.agentProfileId = agentProfileId; self.agentProfileRevision = agentProfileRevision
        self.llmSlotId = llmSlotId; self.requirementsHash = requirementsHash
        self.binding = binding; self.stagingReceiptDigest = stagingReceiptDigest
    }
    private enum CodingKeys: String, CodingKey {
        case agentProfileId = "agent_profile_id", agentProfileRevision = "agent_profile_revision"
        case llmSlotId = "llm_slot_id", requirementsHash = "requirements_hash", binding
        case stagingReceiptDigest = "staging_receipt_digest"
    }
}

public struct HostBindingOperationDTO: Codable, Equatable, Sendable {
    public let kind: String; public let idempotencyKey: String; public let token: String; public let tokenDigest: String
    public let subjectId: String; public let agentProfileId: String; public let agentProfileRevision: UInt64
    public let llmSlotId: String; public let requirementsHash: String; public let state: String
    private enum CodingKeys: String, CodingKey { case kind, idempotencyKey = "idempotency_key", token, tokenDigest = "token_digest", subjectId = "subject_id", agentProfileId = "agent_profile_id", agentProfileRevision = "agent_profile_revision", llmSlotId = "llm_slot_id", requirementsHash = "requirements_hash", state }
}

public struct HostBindingCrossLinkDTO: Codable, Equatable, Sendable {
    public let operationToken: String; public let tokenDigest: String; public let kind: String
    public let llmSlotId: String; public let requirementsHash: String; public let binding: HostBindingTupleDTO
    public let stagingReceiptDigest: String; public let state: String
    private enum CodingKeys: String, CodingKey { case operationToken = "operation_token", tokenDigest = "token_digest", kind, llmSlotId = "llm_slot_id", requirementsHash = "requirements_hash", binding, stagingReceiptDigest = "staging_receipt_digest", state }
}

public struct AgentLLMRequirementsDTO: Codable, Equatable, Sendable {
    public let slotId: String
    public let capabilities: [String]
    public let inputModalities: [String]
    public let contextBudget: String
    public let streamingRequired: Bool
    public let toolCallingMode: String
    private enum CodingKeys: String, CodingKey {
        case slotId = "slot_id", capabilities, inputModalities = "input_modalities"
        case contextBudget = "context_budget", streamingRequired = "streaming_required"
        case toolCallingMode = "tool_calling_mode"
    }
}

public struct PreparationBindingDTO: Codable, Equatable, Sendable {
    public let agentProfileId: String; public let agentProfileRevision: UInt64
    public let conversationFrameDigest: String; public let executionPlanDigest: String
    public let requirementsHash: String; public let toolSchemaDigest: String
    public let modelInputId: String; public let modelInputDigest: String
    public let sourceRevisionsDigest: String; public let initialDisclosureDigest: String
    public let requirements: AgentLLMRequirementsDTO?
    public let initialDataClasses: [String]?
    public let initialHighestSensitivity: String?
    public init(agentProfileId: String, agentProfileRevision: UInt64, conversationFrameDigest: String, executionPlanDigest: String, requirementsHash: String, toolSchemaDigest: String, modelInputId: String, modelInputDigest: String, sourceRevisionsDigest: String, initialDisclosureDigest: String, requirements: AgentLLMRequirementsDTO? = nil, initialDataClasses: [String]? = nil, initialHighestSensitivity: String? = nil) {
        self.agentProfileId = agentProfileId; self.agentProfileRevision = agentProfileRevision
        self.conversationFrameDigest = conversationFrameDigest; self.executionPlanDigest = executionPlanDigest
        self.requirementsHash = requirementsHash; self.toolSchemaDigest = toolSchemaDigest
        self.modelInputId = modelInputId; self.modelInputDigest = modelInputDigest
        self.sourceRevisionsDigest = sourceRevisionsDigest; self.initialDisclosureDigest = initialDisclosureDigest
        self.requirements = requirements; self.initialDataClasses = initialDataClasses
        self.initialHighestSensitivity = initialHighestSensitivity
    }
    private enum CodingKeys: String, CodingKey { case agentProfileId = "agent_profile_id", agentProfileRevision = "agent_profile_revision", conversationFrameDigest = "conversation_frame_digest", executionPlanDigest = "execution_plan_digest", requirementsHash = "requirements_hash", toolSchemaDigest = "tool_schema_digest", modelInputId = "model_input_id", modelInputDigest = "model_input_digest", sourceRevisionsDigest = "source_revisions_digest", initialDisclosureDigest = "initial_disclosure_digest", requirements, initialDataClasses = "initial_data_classes", initialHighestSensitivity = "initial_highest_sensitivity" }
}

public struct AuthoritativePreparationStartRequestDTO: Codable, Equatable, Sendable {
    public let agentProfileId: String
    public let profileRevisionId: UInt64
    public let userIntent: String
    public let conversationRunFrameRef: ConversationRunFrameRefDTO
    public init(agentProfileId: String, profileRevisionId: UInt64, userIntent: String, conversationRunFrameRef: ConversationRunFrameRefDTO) {
        self.agentProfileId = agentProfileId
        self.profileRevisionId = profileRevisionId
        self.userIntent = userIntent
        self.conversationRunFrameRef = conversationRunFrameRef
    }
    private enum CodingKeys: String, CodingKey {
        case agentProfileId = "agent_profile_id"
        case profileRevisionId = "profile_revision_id"
        case userIntent = "user_intent"
        case conversationRunFrameRef = "conversation_run_frame_ref"
    }
}

public struct PreviewRunPreparationRequestDTO: Codable, Equatable, Sendable {
    public let idempotencyKey: String
    public let preparationId: String
    public let proposedRunId: String
    public let startRequest: AuthoritativePreparationStartRequestDTO
    public let nowMillis: UInt64
    public init(idempotencyKey: String, preparationId: String, proposedRunId: String, startRequest: AuthoritativePreparationStartRequestDTO, nowMillis: UInt64) {
        self.idempotencyKey = idempotencyKey
        self.preparationId = preparationId
        self.proposedRunId = proposedRunId
        self.startRequest = startRequest
        self.nowMillis = nowMillis
    }
    private enum CodingKeys: String, CodingKey {
        case idempotencyKey = "idempotency_key"
        case preparationId = "preparation_id"
        case proposedRunId = "proposed_run_id"
        case startRequest = "start_request"
        case nowMillis = "now_millis"
    }
}

public struct RunPreparationPreviewDTO: Codable, Equatable, Sendable {
    public let preparationId: String; public let proposedRunId: String; public let token: String; public let tokenDigest: String
    public let tokenGeneration: UInt64; public let binding: PreparationBindingDTO; public let bindingDigest: String
    public let hostProcessEpoch: String; public let leaseGeneration: UInt64; public let expirationMillis: UInt64; public let totalDeadlineMillis: UInt64
    public init(preparationId: String, proposedRunId: String, token: String, tokenDigest: String, tokenGeneration: UInt64, binding: PreparationBindingDTO, bindingDigest: String, hostProcessEpoch: String, leaseGeneration: UInt64, expirationMillis: UInt64, totalDeadlineMillis: UInt64) {
        self.preparationId = preparationId; self.proposedRunId = proposedRunId
        self.token = token; self.tokenDigest = tokenDigest; self.tokenGeneration = tokenGeneration
        self.binding = binding; self.bindingDigest = bindingDigest; self.hostProcessEpoch = hostProcessEpoch
        self.leaseGeneration = leaseGeneration; self.expirationMillis = expirationMillis
        self.totalDeadlineMillis = totalDeadlineMillis
    }
    private enum CodingKeys: String, CodingKey { case preparationId = "preparation_id", proposedRunId = "proposed_run_id", token, tokenDigest = "token_digest", tokenGeneration = "token_generation", binding, bindingDigest = "binding_digest", hostProcessEpoch = "host_process_epoch", leaseGeneration = "lease_generation", expirationMillis = "expiration_millis", totalDeadlineMillis = "total_deadline_millis" }
}

public struct RenewRunPreparationRequestDTO: Codable, Equatable, Sendable {
    public let token: String; public let bindingDigest: String; public let idempotencyKey: String; public let nowMillis: UInt64
    public init(token: String, bindingDigest: String, idempotencyKey: String, nowMillis: UInt64) { self.token = token; self.bindingDigest = bindingDigest; self.idempotencyKey = idempotencyKey; self.nowMillis = nowMillis }
    private enum CodingKeys: String, CodingKey { case token, bindingDigest = "binding_digest", idempotencyKey = "idempotency_key", nowMillis = "now_millis" }
}

public struct PreparedSessionRegistrationDTO: Codable, Equatable, Sendable {
    public let idempotencyKey: String; public let preparationId: String; public let proposedRunId: String
    public let sessionHandle: String; public let swiftSnapshotId: String; public let hostProcessEpoch: String
    public let bindingId: String; public let bindingRevision: UInt64
    public let bindingHash: String; public let registrationDigest: String
    public init(idempotencyKey: String, preparationId: String, proposedRunId: String, sessionHandle: String, swiftSnapshotId: String, hostProcessEpoch: String, bindingId: String, bindingRevision: UInt64, bindingHash: String, registrationDigest: String) {
        self.idempotencyKey = idempotencyKey; self.preparationId = preparationId; self.proposedRunId = proposedRunId
        self.sessionHandle = sessionHandle; self.swiftSnapshotId = swiftSnapshotId; self.hostProcessEpoch = hostProcessEpoch
        self.bindingId = bindingId; self.bindingRevision = bindingRevision
        self.bindingHash = bindingHash; self.registrationDigest = registrationDigest
    }
    private enum CodingKeys: String, CodingKey { case idempotencyKey = "idempotency_key", preparationId = "preparation_id", proposedRunId = "proposed_run_id", sessionHandle = "session_handle", swiftSnapshotId = "swift_snapshot_id", hostProcessEpoch = "host_process_epoch", bindingId = "binding_id", bindingRevision = "binding_revision", bindingHash = "binding_hash", registrationDigest = "registration_digest" }
}

public struct RegisterPreparedSessionRequestDTO: Codable, Equatable, Sendable {
    public let token: String; public let registration: PreparedSessionRegistrationDTO; public let nowMillis: UInt64
    public init(token: String, registration: PreparedSessionRegistrationDTO, nowMillis: UInt64) { self.token = token; self.registration = registration; self.nowMillis = nowMillis }
    private enum CodingKeys: String, CodingKey { case token, registration, nowMillis = "now_millis" }
}

public enum PreparationAbortReasonDTO: String, Codable, Equatable, Sendable { case userDenied = "user_denied", preparationFailed = "preparation_failed", tokenExpired = "token_expired", commitRejected = "commit_rejected", commitConflict = "commit_conflict", hostShutdown = "host_shutdown" }

public struct BeginAbortPreparationRequestDTO: Codable, Equatable, Sendable {
    public let preparationId: String; public let token: String?; public let idempotencyKey: String; public let reason: PreparationAbortReasonDTO
    public init(preparationId: String, token: String?, idempotencyKey: String, reason: PreparationAbortReasonDTO) { self.preparationId = preparationId; self.token = token; self.idempotencyKey = idempotencyKey; self.reason = reason }
    private enum CodingKeys: String, CodingKey { case preparationId = "preparation_id", token, idempotencyKey = "idempotency_key", reason }
}

public struct PreparedSessionCleanupEnvelopeDTO: Codable, Equatable, Sendable {
    public let cleanupCommandId: String; public let preparationId: String; public let proposedRunId: String
    public let sessionHandle: String; public let hostProcessEpoch: String; public let preparationCleanupSequence: UInt64
    public let reason: PreparationAbortReasonDTO; public let preparedSessionRegistrationDigest: String; public let cleanupCommandDigest: String
    private enum CodingKeys: String, CodingKey { case cleanupCommandId = "cleanup_command_id", preparationId = "preparation_id", proposedRunId = "proposed_run_id", sessionHandle = "session_handle", hostProcessEpoch = "host_process_epoch", preparationCleanupSequence = "preparation_cleanup_sequence", reason, preparedSessionRegistrationDigest = "prepared_session_registration_digest", cleanupCommandDigest = "cleanup_command_digest" }
}

public struct PreparedSessionCleanupAcknowledgementDTO: Codable, Equatable, Sendable {
    public let cleanupCommandId: String
    public let preparationId: String
    public let preparationCleanupSequence: UInt64
    public let cleanupCommandDigest: String
    public init(cleanupCommandId: String, preparationId: String, preparationCleanupSequence: UInt64, cleanupCommandDigest: String) {
        self.cleanupCommandId = cleanupCommandId
        self.preparationId = preparationId
        self.preparationCleanupSequence = preparationCleanupSequence
        self.cleanupCommandDigest = cleanupCommandDigest
    }
    private enum CodingKeys: String, CodingKey {
        case cleanupCommandId = "cleanup_command_id"
        case preparationId = "preparation_id"
        case preparationCleanupSequence = "preparation_cleanup_sequence"
        case cleanupCommandDigest = "cleanup_command_digest"
    }
}

public struct PreparedSessionClosedReceiptDTO: Codable, Equatable, Sendable {
    public let cleanupCommandId: String; public let preparationId: String; public let proposedRunId: String
    public let sessionHandle: String; public let hostProcessEpoch: String; public let preparationCleanupSequence: UInt64
    public let closeDisposition: String; public let receiptDigest: String
    public init(cleanupCommandId: String, preparationId: String, proposedRunId: String, sessionHandle: String, hostProcessEpoch: String, preparationCleanupSequence: UInt64, closeDisposition: String, receiptDigest: String) {
        self.cleanupCommandId = cleanupCommandId; self.preparationId = preparationId; self.proposedRunId = proposedRunId
        self.sessionHandle = sessionHandle; self.hostProcessEpoch = hostProcessEpoch; self.preparationCleanupSequence = preparationCleanupSequence
        self.closeDisposition = closeDisposition; self.receiptDigest = receiptDigest
    }
    private enum CodingKeys: String, CodingKey { case cleanupCommandId = "cleanup_command_id", preparationId = "preparation_id", proposedRunId = "proposed_run_id", sessionHandle = "session_handle", hostProcessEpoch = "host_process_epoch", preparationCleanupSequence = "preparation_cleanup_sequence", closeDisposition = "close_disposition", receiptDigest = "receipt_digest" }
}

public struct RunPreparationRecordDTO: Codable, Equatable, Sendable {
    public let preview: RunPreparationPreviewDTO; public let state: String
    public let registration: PreparedSessionRegistrationDTO?; public let cleanup: PreparedSessionCleanupEnvelopeDTO?
    public let closedReceipt: PreparedSessionClosedReceiptDTO?
    private enum CodingKeys: String, CodingKey { case preview, state, registration, cleanup, closedReceipt = "closed_receipt" }
}

public struct PreparedCapabilityAttestationDTO: Codable, Equatable, Sendable {
    public let supportedCapabilities: [String]
    public let inputModalities: [String]
    public let contextLength: String
    public let streaming: Bool
    public let toolCalling: Bool
    public let expirationMillis: UInt64
    public let attestationDigest: String
    public init(supportedCapabilities: [String], inputModalities: [String], contextLength: String, streaming: Bool, toolCalling: Bool, expirationMillis: UInt64, attestationDigest: String) {
        self.supportedCapabilities = supportedCapabilities; self.inputModalities = inputModalities
        self.contextLength = contextLength; self.streaming = streaming; self.toolCalling = toolCalling
        self.expirationMillis = expirationMillis; self.attestationDigest = attestationDigest
    }
    private enum CodingKeys: String, CodingKey {
        case supportedCapabilities = "supported_capabilities", inputModalities = "input_modalities"
        case contextLength = "context_length", streaming, toolCalling = "tool_calling"
        case expirationMillis = "expiration_millis", attestationDigest = "attestation_digest"
    }
}

public struct HostAttestationDTO: Codable, Equatable, Sendable {
    public let document: HostAttestationV1Document
    public let preparationBindingDigest: String
    public let egressAttestationDigest: String
    public let disclosureGrantId: String
    public let dataClasses: [String: Bool]
    public let highestSensitivity: String
    public let capabilityAttestation: PreparedCapabilityAttestationDTO
    public init(document: HostAttestationV1Document, preparationBindingDigest: String, egressAttestationDigest: String, disclosureGrantId: String, dataClasses: [String: Bool], highestSensitivity: String, capabilityAttestation: PreparedCapabilityAttestationDTO) {
        self.document = document; self.preparationBindingDigest = preparationBindingDigest
        self.egressAttestationDigest = egressAttestationDigest
        self.disclosureGrantId = disclosureGrantId; self.dataClasses = dataClasses
        self.highestSensitivity = highestSensitivity; self.capabilityAttestation = capabilityAttestation
    }

    public init(from decoder: Decoder) throws {
        let dynamic = try decoder.container(keyedBy: HostAttestationDynamicCodingKey.self)
        let unknownKeys = Set(dynamic.allKeys.map(\.stringValue)).subtracting(CodingKeys.allCases.map(\.rawValue))
        guard unknownKeys.isEmpty else {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: decoder.codingPath,
                    debugDescription: "host attestation contains unknown fields: \(unknownKeys.sorted().joined(separator: ", "))"
                )
            )
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        document = try container.decode(HostAttestationV1Document.self, forKey: .document)
        preparationBindingDigest = try container.decode(String.self, forKey: .preparationBindingDigest)
        egressAttestationDigest = try container.decode(String.self, forKey: .egressAttestationDigest)
        disclosureGrantId = try container.decode(String.self, forKey: .disclosureGrantId)
        dataClasses = try container.decode([String: Bool].self, forKey: .dataClasses)
        highestSensitivity = try container.decode(String.self, forKey: .highestSensitivity)
        capabilityAttestation = try container.decode(PreparedCapabilityAttestationDTO.self, forKey: .capabilityAttestation)
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case document, preparationBindingDigest = "preparation_binding_digest"
        case egressAttestationDigest = "egress_attestation_digest"
        case disclosureGrantId = "disclosure_grant_id", dataClasses = "data_classes"
        case highestSensitivity = "highest_sensitivity", capabilityAttestation = "capability_attestation"
    }
}

private struct HostAttestationDynamicCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

public struct HostRunHandleDTO: Codable, Equatable, Sendable {
    public let runID: String
    public let sessionHandle: String
    public let firstCommandID: String
    public init(runID: String, sessionHandle: String, firstCommandID: String) {
        self.runID = runID; self.sessionHandle = sessionHandle; self.firstCommandID = firstCommandID
    }
    private enum CodingKeys: String, CodingKey {
        case runID = "run_id", sessionHandle = "session_handle", firstCommandID = "first_command_id"
    }
}

public struct PreparedSessionCleanupIdentityDTO: Codable, Equatable, Sendable {
    public let cleanupCommandID: String; public let cleanupCommandSequence: UInt64
    public let preparationID: String; public let proposedRunID: String; public let sessionHandle: String
    public let registrationDigest: String; public let hostProcessEpoch: String
    private enum CodingKeys: String, CodingKey {
        case cleanupCommandID = "cleanup_command_id", cleanupCommandSequence = "cleanup_command_sequence"
        case preparationID = "preparation_id", proposedRunID = "proposed_run_id"
        case sessionHandle = "session_handle", registrationDigest = "registration_digest"
        case hostProcessEpoch = "host_process_epoch"
    }
}

public enum PreparationReconciliationStatusDTO: String, Codable, Sendable { case committed, pending, aborting }

public struct ReconcilePreparationRequestDTO: Codable, Equatable, Sendable {
    public let preparationID: String
    public let proposedRunID: String
    public let tokenDigest: String

    public init(preparationID: String, proposedRunID: String, tokenDigest: String) {
        self.preparationID = preparationID
        self.proposedRunID = proposedRunID
        self.tokenDigest = tokenDigest
    }

    private enum CodingKeys: String, CodingKey {
        case preparationID = "preparation_id"
        case proposedRunID = "proposed_run_id"
        case tokenDigest = "token_digest"
    }
}

public struct PreparationReconciliationDTO: Codable, Equatable, Sendable {
    public let status: PreparationReconciliationStatusDTO
    public let handle: HostRunHandleDTO?
    public let cleanupIdentity: PreparedSessionCleanupIdentityDTO?

    public init(
        status: PreparationReconciliationStatusDTO,
        handle: HostRunHandleDTO?,
        cleanupIdentity: PreparedSessionCleanupIdentityDTO?
    ) throws {
        self.status = status
        self.handle = handle
        self.cleanupIdentity = cleanupIdentity
        guard Self.valid(status, handle: handle, cleanupIdentity: cleanupIdentity) else {
            throw RuntimeBridgeError(
                kind: "preparation.reconciliation_payload_invalid",
                message: "reconciliation payload does not match status"
            )
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        status = try container.decode(PreparationReconciliationStatusDTO.self, forKey: .status)
        handle = try container.decodeIfPresent(HostRunHandleDTO.self, forKey: .handle)
        cleanupIdentity = try container.decodeIfPresent(PreparedSessionCleanupIdentityDTO.self, forKey: .cleanupIdentity)
        guard Self.valid(status, handle: handle, cleanupIdentity: cleanupIdentity) else {
            throw DecodingError.dataCorruptedError(forKey: .status, in: container, debugDescription: "reconciliation payload does not match status")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(status, forKey: .status)
        try container.encodeIfPresent(handle, forKey: .handle)
        try container.encodeIfPresent(cleanupIdentity, forKey: .cleanupIdentity)
    }

    private enum CodingKeys: String, CodingKey { case status, handle, cleanupIdentity = "cleanup_identity" }

    private static func valid(
        _ status: PreparationReconciliationStatusDTO,
        handle: HostRunHandleDTO?,
        cleanupIdentity: PreparedSessionCleanupIdentityDTO?
    ) -> Bool {
        switch status {
        case .committed: handle != nil && cleanupIdentity == nil
        case .pending: handle == nil && cleanupIdentity == nil
        case .aborting: handle == nil && cleanupIdentity != nil
        }
    }
}

public struct CommitPreparedStartRequestDTO: Codable, Equatable, Sendable {
    public let token: String; public let attestation: HostAttestationDTO; public let nowMillis: UInt64
    public init(token: String, attestation: HostAttestationDTO, nowMillis: UInt64) { self.token = token; self.attestation = attestation; self.nowMillis = nowMillis }
    private enum CodingKeys: String, CodingKey { case token, attestation, nowMillis = "now_millis" }
}

@available(*, deprecated, message: "Use StartExecutionRequestDTO with ConversationRunFrameRefDTO")
public struct StartRunRequestDTO: Codable, Equatable, Sendable {
    public var agentProfileId: String
    public var userIntent: String

    public init(agentProfileId: String, userIntent: String) {
        self.agentProfileId = agentProfileId
        self.userIntent = userIntent
    }

    private enum CodingKeys: String, CodingKey {
        case agentProfileId = "agent_profile_id"
        case userIntent = "user_intent"
    }
}

public struct RunHandleDTO: Codable, Equatable, Sendable {
    public var runId: String
    public var replayFromSequence: UInt64

    public init(runId: String, replayFromSequence: UInt64 = 0) {
        self.runId = runId
        self.replayFromSequence = replayFromSequence
    }

    private enum CodingKeys: String, CodingKey {
        case runId = "run_id"
        case replayFromSequence = "replay_from_sequence"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.runId = try container.decode(String.self, forKey: .runId)
        self.replayFromSequence = try container.decodeIfPresent(
            UInt64.self,
            forKey: .replayFromSequence
        ) ?? 0
    }
}

public struct ConversationRunFrameRefDTO: Codable, Equatable, Sendable {
    public var frameId: String
    public var sessionId: String
    public var branchHeadId: String
    public var userTurnId: String

    public init(
        frameId: String,
        sessionId: String,
        branchHeadId: String,
        userTurnId: String
    ) {
        self.frameId = frameId
        self.sessionId = sessionId
        self.branchHeadId = branchHeadId
        self.userTurnId = userTurnId
    }

    private enum CodingKeys: String, CodingKey {
        case frameId = "frame_id"
        case sessionId = "session_id"
        case branchHeadId = "branch_head_id"
        case userTurnId = "user_turn_id"
    }
}

public struct ConversationRunFrameDTO: Codable, Equatable, Sendable {
    public var frameRef: ConversationRunFrameRefDTO
    public var messages: [ConversationFrameMessageDTO]
    public var attachmentRefs: [String]

    public init(
        frameRef: ConversationRunFrameRefDTO,
        messages: [ConversationFrameMessageDTO],
        attachmentRefs: [String] = []
    ) {
        self.frameRef = frameRef
        self.messages = messages
        self.attachmentRefs = attachmentRefs
    }

    private enum CodingKeys: String, CodingKey {
        case frameRef = "frame_ref"
        case messages
        case attachmentRefs = "attachment_refs"
    }
}

public struct ConversationFrameMessageDTO: Codable, Equatable, Sendable {
    public var eventId: String
    public var role: String
    public var content: String

    public init(eventId: String, role: String, content: String) {
        self.eventId = eventId
        self.role = role
        self.content = content
    }

    private enum CodingKeys: String, CodingKey {
        case eventId = "event_id"
        case role
        case content
    }
}

public struct PrepareUserTurnRequestDTO: Codable, Equatable, Sendable {
    public var sessionId: String?
    public var parentEventId: String?
    public var text: String
    public var blobRefs: [String]

    public init(
        sessionId: String?,
        parentEventId: String?,
        text: String,
        blobRefs: [String] = []
    ) {
        self.sessionId = sessionId
        self.parentEventId = parentEventId
        self.text = text
        self.blobRefs = blobRefs
    }

    private enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case parentEventId = "parent_event_id"
        case text
        case blobRefs = "blob_refs"
    }
}

public struct PreparedUserTurnDTO: Codable, Equatable, Sendable {
    public var sessionId: String
    public var userMessageId: String
    public var conversationRunFrameRef: ConversationRunFrameRefDTO
    public var framePreview: ConversationRunFrameDTO?

    public init(
        sessionId: String,
        userMessageId: String,
        conversationRunFrameRef: ConversationRunFrameRefDTO,
        framePreview: ConversationRunFrameDTO? = nil
    ) {
        self.sessionId = sessionId
        self.userMessageId = userMessageId
        self.conversationRunFrameRef = conversationRunFrameRef
        self.framePreview = framePreview
    }

    private enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case userMessageId = "user_message_id"
        case conversationRunFrameRef = "conversation_run_frame_ref"
        case framePreview = "frame_preview"
    }
}

public struct CommitAssistantResultRequestDTO: Codable, Equatable, Sendable {
    public var runId: String
    public var finalMessageId: String
    public var conversationRunFrameRef: ConversationRunFrameRefDTO

    public init(
        runId: String,
        finalMessageId: String,
        conversationRunFrameRef: ConversationRunFrameRefDTO
    ) {
        self.runId = runId
        self.finalMessageId = finalMessageId
        self.conversationRunFrameRef = conversationRunFrameRef
    }

    private enum CodingKeys: String, CodingKey {
        case runId = "run_id"
        case finalMessageId = "final_message_id"
        case conversationRunFrameRef = "conversation_run_frame_ref"
    }
}

public struct ConversationCommitResultDTO: Codable, Equatable, Sendable {
    public var committedMessageId: String
    public var alreadyCommitted: Bool

    public init(committedMessageId: String, alreadyCommitted: Bool) {
        self.committedMessageId = committedMessageId
        self.alreadyCommitted = alreadyCommitted
    }

    private enum CodingKeys: String, CodingKey {
        case committedMessageId = "committed_message_id"
        case alreadyCommitted = "already_committed"
    }
}

public struct ExecutionOptionsDTO: Codable, Equatable, Sendable {
    public var modelId: String?
    public var temperature: Double?
    public var topP: Double?

    public init(
        modelId: String? = nil,
        temperature: Double? = nil,
        topP: Double? = nil
    ) {
        self.modelId = modelId
        self.temperature = temperature
        self.topP = topP
    }

    private enum CodingKeys: String, CodingKey {
        case modelId = "model_id"
        case temperature
        case topP = "top_p"
    }
}

public struct StartExecutionRequestDTO: Codable, Equatable, Sendable {
    public var agentProfileId: String
    public var profileRevisionId: UInt64
    public var userIntent: String
    public var conversationRunFrameRef: ConversationRunFrameRefDTO
    public var options: ExecutionOptionsDTO

    public init(
        agentProfileId: String,
        profileRevisionId: UInt64,
        userIntent: String,
        conversationRunFrameRef: ConversationRunFrameRefDTO,
        options: ExecutionOptionsDTO = ExecutionOptionsDTO()
    ) {
        self.agentProfileId = agentProfileId
        self.profileRevisionId = profileRevisionId
        self.userIntent = userIntent
        self.conversationRunFrameRef = conversationRunFrameRef
        self.options = options
    }

    private enum CodingKeys: String, CodingKey {
        case agentProfileId = "agent_profile_id"
        case profileRevisionId = "profile_revision_id"
        case userIntent = "user_intent"
        case conversationRunFrameRef = "conversation_run_frame_ref"
        case options
    }
}

public struct ObserveExecutionEventsRequestDTO: Codable, Equatable, Sendable {
    public var runId: String
    public var fromSequence: UInt64

    public init(runId: String, fromSequence: UInt64) {
        self.runId = runId
        self.fromSequence = fromSequence
    }

    private enum CodingKeys: String, CodingKey {
        case runId = "run_id"
        case fromSequence = "from_sequence"
    }
}

public struct BuildAgentRequestDTO: Codable, Equatable, Sendable {
    public var profileId: String?
    public var templateId: String
    public var displayName: String?
    public var systemPrompt: String?
    public var persona: String?
    public var responseStyle: String?
    public var selectedToolIds: [String]
    public var contextStepIds: [String]

    public init(
        profileId: String? = nil,
        templateId: String,
        displayName: String? = nil,
        systemPrompt: String? = nil,
        persona: String? = nil,
        responseStyle: String? = nil,
        selectedToolIds: [String] = [],
        contextStepIds: [String] = []
    ) {
        self.profileId = profileId
        self.templateId = templateId
        self.displayName = displayName
        self.systemPrompt = systemPrompt
        self.persona = persona
        self.responseStyle = responseStyle
        self.selectedToolIds = selectedToolIds
        self.contextStepIds = contextStepIds
    }

    private enum CodingKeys: String, CodingKey {
        case profileId = "profile_id"
        case templateId = "template_id"
        case displayName = "display_name"
        case systemPrompt = "system_prompt"
        case persona
        case responseStyle = "response_style"
        case selectedToolIds = "selected_tool_ids"
        case contextStepIds = "context_step_ids"
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(profileId, forKey: .profileId)
        try container.encode(templateId, forKey: .templateId)
        try container.encodeIfPresent(displayName, forKey: .displayName)
        try container.encodeIfPresent(systemPrompt, forKey: .systemPrompt)
        try container.encodeIfPresent(persona, forKey: .persona)
        try container.encodeIfPresent(responseStyle, forKey: .responseStyle)
        if !selectedToolIds.isEmpty {
            try container.encode(selectedToolIds, forKey: .selectedToolIds)
        }
        if !contextStepIds.isEmpty {
            try container.encode(contextStepIds, forKey: .contextStepIds)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.profileId = try container.decodeIfPresent(String.self, forKey: .profileId)
        self.templateId = try container.decode(String.self, forKey: .templateId)
        self.displayName = try container.decodeIfPresent(String.self, forKey: .displayName)
        self.systemPrompt = try container.decodeIfPresent(String.self, forKey: .systemPrompt)
        self.persona = try container.decodeIfPresent(String.self, forKey: .persona)
        self.responseStyle = try container.decodeIfPresent(String.self, forKey: .responseStyle)
        self.selectedToolIds = try container.decodeIfPresent([String].self, forKey: .selectedToolIds) ?? []
        self.contextStepIds = try container.decodeIfPresent([String].self, forKey: .contextStepIds) ?? []
    }
}

public struct BuilderContextPreviewRequestDTO: Codable, Equatable, Sendable {
    public var draft: AgentBuilderDraftDTO
    public var sampleUserMessage: String

    public init(draft: AgentBuilderDraftDTO, sampleUserMessage: String) {
        self.draft = draft
        self.sampleUserMessage = sampleUserMessage
    }

    private enum CodingKeys: String, CodingKey {
        case draft
        case sampleUserMessage = "sample_user_message"
    }
}

public struct BuilderContextPreviewResponseDTO: Codable, Equatable, Sendable {
    public var isPreviewOnly: Bool
    public var segments: [BuilderContextPreviewSegmentDTO]
    public var tokenEstimate: Int
    public var warnings: [String]
    public var missingInputs: [String]

    public init(
        isPreviewOnly: Bool,
        segments: [BuilderContextPreviewSegmentDTO],
        tokenEstimate: Int,
        warnings: [String] = [],
        missingInputs: [String] = []
    ) {
        self.isPreviewOnly = isPreviewOnly
        self.segments = segments
        self.tokenEstimate = tokenEstimate
        self.warnings = warnings
        self.missingInputs = missingInputs
    }

    private enum CodingKeys: String, CodingKey {
        case isPreviewOnly = "is_preview_only"
        case segments
        case tokenEstimate = "token_estimate"
        case warnings
        case missingInputs = "missing_inputs"
    }
}

public struct BuilderContextPreviewSegmentDTO: Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var sourceLabel: String
    public var trustLevel: String
    public var isEnabled: Bool
    public var previewText: String

    public init(
        id: String,
        title: String,
        sourceLabel: String,
        trustLevel: String,
        isEnabled: Bool,
        previewText: String
    ) {
        self.id = id
        self.title = title
        self.sourceLabel = sourceLabel
        self.trustLevel = trustLevel
        self.isEnabled = isEnabled
        self.previewText = previewText
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case sourceLabel = "source_label"
        case trustLevel = "trust_level"
        case isEnabled = "is_enabled"
        case previewText = "preview_text"
    }
}

public struct ApprovalDecisionDTO: Codable, Equatable, Sendable {
    public var approved: Bool
    public var reason: String?

    public init(approved: Bool, reason: String? = nil) {
        self.approved = approved
        self.reason = reason
    }
}

public struct ApproveToolRequestDTO: Codable, Equatable, Sendable {
    public var id: String
    public var decision: ApprovalDecisionDTO

    public init(id: String, decision: ApprovalDecisionDTO) {
        self.id = id
        self.decision = decision
    }
}

public struct SubmitToolResultRequestDTO: Codable, Equatable, Sendable {
    public var runId: String
    public var result: ToolResultDTO

    public init(runId: String, result: ToolResultDTO) {
        self.runId = runId
        self.result = result
    }

    private enum CodingKeys: String, CodingKey {
        case runId = "run_id"
        case result
    }
}

public struct CancelRunRequestDTO: Codable, Equatable, Sendable {
    public var runId: String

    public init(runId: String) {
        self.runId = runId
    }

    private enum CodingKeys: String, CodingKey {
        case runId = "run_id"
    }
}

public struct EmptyAgentOSRequestDTO: Codable, Equatable, Sendable {
    public init() {}
}

public struct EmptyAgentOSResponseDTO: Codable, Equatable, Sendable {
    public init() {}

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self.init()
            return
        }
        self.init()
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode([String: String]())
    }
}

public struct AgentProfileDTO: Codable, Equatable, Sendable {
    public var profileId: String
    public var profileRevisionId: UInt64
    public var displayName: String

    public init(profileId: String, profileRevisionId: UInt64, displayName: String) {
        self.profileId = profileId
        self.profileRevisionId = profileRevisionId
        self.displayName = displayName
    }

    private enum CodingKeys: String, CodingKey {
        case profileId = "profile_id"
        case profileRevisionId = "profile_revision_id"
        case displayName = "display_name"
    }
}

public struct PackageInspectReportDTO: Codable, Equatable, Sendable {
    public var packageName: String
    public var issues: [PermissionIssueDTO]

    public init(packageName: String, issues: [PermissionIssueDTO] = []) {
        self.packageName = packageName
        self.issues = issues
    }

    private enum CodingKeys: String, CodingKey {
        case packageName = "package_name"
        case issues
    }
}

public struct PackageInstallRequestDTO: Codable, Equatable, Sendable {
    public var packageURL: URL

    public init(packageURL: URL) {
        self.packageURL = packageURL
    }

    private enum CodingKeys: String, CodingKey {
        case packageURL = "package_url"
    }
}

public struct PackageInstallPreviewUIModel: Codable, Equatable, Sendable {
    public var profileName: String
    public var operations: [PackageInstallOperationUIModel]
    public var issues: [PermissionIssueDTO]

    public init(
        profileName: String,
        operations: [PackageInstallOperationUIModel],
        issues: [PermissionIssueDTO] = []
    ) {
        self.profileName = profileName
        self.operations = operations
        self.issues = issues
    }

    private enum CodingKeys: String, CodingKey {
        case profileName = "profile_name"
        case operations
        case issues
    }
}

public struct PackageInstallOperationUIModel: Codable, Equatable, Sendable {
    public var code: String
    public var title: String

    public init(code: String, title: String) {
        self.code = code
        self.title = title
    }
}

public struct RunSnapshotPreviewUIModel: Codable, Equatable, Sendable {
    public var profileId: String
    public var isReady: Bool
    public var issues: [PermissionIssueDTO]

    public init(profileId: String, isReady: Bool, issues: [PermissionIssueDTO] = []) {
        self.profileId = profileId
        self.isReady = isReady
        self.issues = issues
    }

    private enum CodingKeys: String, CodingKey {
        case profileId = "profile_id"
        case isReady = "is_ready"
        case issues
    }
}

public typealias RunSnapshotReadinessUIModel = RunSnapshotPreviewUIModel

public struct CapabilityRequirementDTO: Codable, Equatable, Sendable {
    public var code: String
    public var title: String

    public init(code: String, title: String) {
        self.code = code
        self.title = title
    }
}

public struct PermissionIssueDTO: Codable, Equatable, Sendable {
    public var code: String
    public var message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }
}

public struct PermissionReadinessUIModel: Codable, Equatable, Sendable {
    public var issues: [PermissionIssueDTO]

    public init(issues: [PermissionIssueDTO] = []) {
        self.issues = issues
    }

    public var isReady: Bool {
        issues.isEmpty
    }
}

public struct RunDebugUIModel: Codable, Equatable, Sendable {
    public var runId: String
    public var state: RunDebugStateDTO
    public var events: [RunDebugEventDTO]
    public var archives: [DebugArchiveDTO]
    public var checkpoints: [CheckpointDTO]

    public init(
        runId: String,
        state: RunDebugStateDTO,
        events: [RunDebugEventDTO],
        archives: [DebugArchiveDTO] = [],
        checkpoints: [CheckpointDTO]
    ) {
        self.runId = runId
        self.state = state
        self.events = events
        self.archives = archives
        self.checkpoints = checkpoints
    }

    private enum CodingKeys: String, CodingKey {
        case runId = "run_id"
        case state
        case events
        case archives
        case checkpoints
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.runId = try container.decode(String.self, forKey: .runId)
        self.state = try container.decode(RunDebugStateDTO.self, forKey: .state)
        self.events = try container.decode([RunDebugEventDTO].self, forKey: .events)
        self.archives = try container.decodeIfPresent([DebugArchiveDTO].self, forKey: .archives) ?? []
        self.checkpoints = try container.decode([CheckpointDTO].self, forKey: .checkpoints)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(runId, forKey: .runId)
        try container.encode(state, forKey: .state)
        try container.encode(events, forKey: .events)
        try container.encode(archives, forKey: .archives)
        try container.encode(checkpoints, forKey: .checkpoints)
    }
}

public struct RunDebugStateDTO: RawRepresentable, Codable, Equatable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static let created = Self(rawValue: "created")
    public static let running = Self(rawValue: "running")
    public static let awaitingApproval = Self(rawValue: "awaiting_approval")
    public static let awaitingTool = Self(rawValue: "awaiting_tool")
    public static let failed = Self(rawValue: "failed")
    public static let completed = Self(rawValue: "completed")

    public static func unknown(raw: String) -> Self {
        Self(rawValue: raw)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(rawValue: try container.decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public struct RunDebugEventDTO: Codable, Equatable, Sendable {
    public var id: String
    public var code: String
    public var title: String

    public init(id: String, code: String, title: String) {
        self.id = id
        self.code = code
        self.title = title
    }
}

public struct DebugArchiveDTO: Codable, Equatable, Sendable {
    public var id: String
    public var kind: DebugArchiveKindDTO
    public var title: String
    public var redactedPayload: String
    public var sourceLinks: [DebugArchiveSourceLinkDTO]

    public init(
        id: String,
        kind: DebugArchiveKindDTO,
        title: String,
        redactedPayload: String,
        sourceLinks: [DebugArchiveSourceLinkDTO] = []
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.redactedPayload = redactedPayload
        self.sourceLinks = sourceLinks
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case kind
        case title
        case redactedPayload = "redacted_payload"
        case sourceLinks = "source_links"
    }
}

public struct DebugArchiveKindDTO: RawRepresentable, Codable, Equatable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static let prompt = Self(rawValue: "prompt")
    public static let context = Self(rawValue: "context")
    public static let runtimeEvents = Self(rawValue: "runtime_events")

    public static func unknown(raw: String) -> Self {
        Self(rawValue: raw)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(rawValue: try container.decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public struct DebugArchiveSourceLinkDTO: Codable, Equatable, Sendable {
    public var kind: DebugArchiveSourceKindDTO
    public var targetId: String

    public init(kind: DebugArchiveSourceKindDTO, targetId: String) {
        self.kind = kind
        self.targetId = targetId
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case targetId = "target_id"
    }
}

public struct DebugArchiveSourceKindDTO: RawRepresentable, Codable, Equatable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static let promptArchive = Self(rawValue: "prompt_archive")
    public static let contextArchive = Self(rawValue: "context_archive")
    public static let runtimeEvent = Self(rawValue: "runtime_event")

    public static func unknown(raw: String) -> Self {
        Self(rawValue: raw)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(rawValue: try container.decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public struct CheckpointDTO: Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var canResume: Bool

    public init(id: String, title: String, canResume: Bool) {
        self.id = id
        self.title = title
        self.canResume = canResume
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case canResume = "can_resume"
    }
}

public struct AgentBuilderDraftDTO: Codable, Equatable, Sendable {
    public var profileId: String
    public var templateId: String
    public var displayName: String?
    public var systemPrompt: String?
    public var persona: String?
    public var responseStyle: String?
    public var selectedToolIds: [String]
    public var contextStepIds: [String]

    public init(
        profileId: String,
        templateId: String = "template_1",
        displayName: String? = nil,
        systemPrompt: String? = nil,
        persona: String? = nil,
        responseStyle: String? = nil,
        selectedToolIds: [String] = [],
        contextStepIds: [String] = []
    ) {
        self.profileId = profileId
        self.templateId = templateId
        self.displayName = displayName
        self.systemPrompt = systemPrompt
        self.persona = persona
        self.responseStyle = responseStyle
        self.selectedToolIds = selectedToolIds
        self.contextStepIds = contextStepIds
    }

    private enum CodingKeys: String, CodingKey {
        case profileId = "profile_id"
        case templateId = "template_id"
        case displayName = "display_name"
        case systemPrompt = "system_prompt"
        case persona
        case responseStyle = "response_style"
        case selectedToolIds = "selected_tool_ids"
        case contextStepIds = "context_step_ids"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.profileId = try container.decode(String.self, forKey: .profileId)
        self.templateId = try container.decodeIfPresent(String.self, forKey: .templateId) ?? "template_1"
        self.displayName = try container.decodeIfPresent(String.self, forKey: .displayName)
        self.systemPrompt = try container.decodeIfPresent(String.self, forKey: .systemPrompt)
        self.persona = try container.decodeIfPresent(String.self, forKey: .persona)
        self.responseStyle = try container.decodeIfPresent(String.self, forKey: .responseStyle)
        self.selectedToolIds = try container.decodeIfPresent([String].self, forKey: .selectedToolIds) ?? []
        self.contextStepIds = try container.decodeIfPresent([String].self, forKey: .contextStepIds) ?? []
    }
}

public struct AgentBuilderUIModel: Codable, Equatable, Sendable {
    public var profileId: String
    public var displayName: String
    public var readiness: PermissionReadinessUIModel

    public init(
        profileId: String,
        displayName: String,
        readiness: PermissionReadinessUIModel
    ) {
        self.profileId = profileId
        self.displayName = displayName
        self.readiness = readiness
    }

    private enum CodingKeys: String, CodingKey {
        case profileId = "profile_id"
        case displayName = "display_name"
        case readiness
    }
}

public typealias ReadinessUIModel = PermissionReadinessUIModel
