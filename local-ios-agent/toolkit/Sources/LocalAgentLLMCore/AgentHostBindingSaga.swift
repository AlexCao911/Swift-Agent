import Foundation
import LocalAgentLLMContracts

public struct HostBindingTuple: Codable, Equatable, Sendable {
    public let bindingID: String
    public let bindingRevision: UInt64
    public let bindingHash: String

    public init(bindingID: String, bindingRevision: UInt64, bindingHash: String) {
        self.bindingID = bindingID
        self.bindingRevision = bindingRevision
        self.bindingHash = bindingHash
    }
}

public struct HostBindingStageRequest: Codable, Equatable, Sendable {
    public let operationToken: String
    public let tokenDigest: String
    public let llmSlotID: String
    public let requirementsHash: String
    public let configuration: AgentHostConfiguration

    public init(
        operationToken: String,
        tokenDigest: String,
        llmSlotID: String,
        requirementsHash: String,
        configuration: AgentHostConfiguration
    ) {
        self.operationToken = operationToken
        self.tokenDigest = tokenDigest
        self.llmSlotID = llmSlotID
        self.requirementsHash = requirementsHash
        self.configuration = configuration
    }
}

public struct HostBindingStagingReceipt: Codable, Equatable, Sendable {
    public let tokenDigest: String
    public let llmSlotID: String
    public let requirementsHash: String
    public let binding: HostBindingTuple
    public let receiptDigest: String
}

public struct RustHostBindingCrossLink: Codable, Equatable, Sendable {
    public let operationToken: String
    public let tokenDigest: String
    public let llmSlotID: String
    public let requirementsHash: String
    public let binding: HostBindingTuple

    public init(
        operationToken: String,
        tokenDigest: String,
        llmSlotID: String,
        requirementsHash: String,
        binding: HostBindingTuple
    ) {
        self.operationToken = operationToken
        self.tokenDigest = tokenDigest
        self.llmSlotID = llmSlotID
        self.requirementsHash = requirementsHash
        self.binding = binding
    }
}

public struct HostBindingReconciliationOutcome: Equatable, Sendable {
    public let activatedTokens: [String]
    public let repairTokens: [String]
}

public struct HostBindingSagaError: Error, Equatable, Sendable {
    public let code: String
    public let message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }
}

public struct AgentHostBindingSaga: Sendable {
    private let store: LLMStore

    public init(store: LLMStore) {
        self.store = store
    }

    public func stageHostBinding(_ request: HostBindingStageRequest) async throws -> HostBindingStagingReceipt {
        guard request.configuration.llmSlotID == request.llmSlotID,
              request.configuration.requirementsHash == request.requirementsHash
        else {
            throw HostBindingSagaError(
                code: "host_binding.requirements_mismatch",
                message: "Swift configuration does not match the Rust slot and requirements"
            )
        }
        let bindingHash = try configurationDigest(request.configuration)
        let binding = HostBindingTuple(
            bindingID: request.configuration.bindingID,
            bindingRevision: request.configuration.revision,
            bindingHash: bindingHash
        )
        let receiptDigest = try stagingReceiptDigest(
            tokenDigest: request.tokenDigest,
            slotID: request.llmSlotID,
            requirementsHash: request.requirementsHash,
            binding: binding
        )
        let receipt = HostBindingStagingReceipt(
            tokenDigest: request.tokenDigest,
            llmSlotID: request.llmSlotID,
            requirementsHash: request.requirementsHash,
            binding: binding,
            receiptDigest: receiptDigest
        )
        return try await store.stage(StoredHostBindingRecord(
            request: request,
            receipt: receipt,
            state: .staged
        ))
    }

    public func activateHostBinding(operationToken: String, binding: HostBindingTuple) async throws {
        try await store.activate(token: operationToken, binding: binding)
    }

    public func reconcileHostBindings(
        _ rustCrossLinks: [RustHostBindingCrossLink]
    ) async throws -> HostBindingReconciliationOutcome {
        var activated: [String] = []
        var repairs: [String] = []
        for link in rustCrossLinks {
            guard let record = await store.record(token: link.operationToken),
                  record.request.tokenDigest == link.tokenDigest,
                  record.request.llmSlotID == link.llmSlotID,
                  record.request.requirementsHash == link.requirementsHash,
                  record.receipt.binding == link.binding
            else {
                repairs.append(link.operationToken)
                continue
            }
            try await store.activate(token: link.operationToken, binding: link.binding)
            activated.append(link.operationToken)
        }
        return HostBindingReconciliationOutcome(
            activatedTokens: activated.sorted(),
            repairTokens: repairs.sorted()
        )
    }
}

private func configurationDigest(_ configuration: AgentHostConfiguration) throws -> String {
    let parameters = try CanonicalJSONValue.object(entries: configuration.parameterOverrides.parameters.map {
        CanonicalJSONObjectEntry(name: $0.key, value: parameterValue($0.value))
    })
    let document = try CanonicalJSONValue.object(entries: [
        .init(name: "agent_profile_id", value: .string(configuration.agentProfileID)),
        .init(name: "agent_profile_revision", value: .string(String(configuration.agentProfileRevision))),
        .init(name: "binding_id", value: .string(configuration.bindingID)),
        .init(name: "binding_revision", value: .string(String(configuration.revision))),
        .init(name: "llm_slot_id", value: .string(configuration.llmSlotID)),
        .init(name: "requirements_hash", value: .string(configuration.requirementsHash)),
        .init(name: "llm_target_id", value: .string(configuration.llmTargetID)),
        .init(name: "llm_target_revision", value: .string(String(configuration.llmTargetRevision))),
        .init(name: "parameter_overrides", value: parameters),
    ])
    return try CanonicalDigestV1.digest(domain: "agent-host-binding:v1", document: document).hex
}

private func stagingReceiptDigest(
    tokenDigest: String,
    slotID: String,
    requirementsHash: String,
    binding: HostBindingTuple
) throws -> String {
    let bindingDocument = try CanonicalJSONValue.object(entries: [
        .init(name: "binding_id", value: .string(binding.bindingID)),
        .init(name: "binding_revision", value: .string(String(binding.bindingRevision))),
        .init(name: "binding_hash", value: .string(binding.bindingHash)),
    ])
    let document = try CanonicalJSONValue.object(entries: [
        .init(name: "token_digest", value: .string(tokenDigest)),
        .init(name: "llm_slot_id", value: .string(slotID)),
        .init(name: "requirements_hash", value: .string(requirementsHash)),
        .init(name: "binding", value: bindingDocument),
    ])
    return try CanonicalDigestV1.digest(
        domain: "host-binding-staging-receipt:v1",
        document: document
    ).hex
}

private func parameterValue(_ value: LLMParameterValue) -> CanonicalJSONValue {
    switch value {
    case let .decimal(value): return .number(value)
    case let .integer(value): return .string(String(value))
    case let .text(value): return .string(value)
    case let .boolean(value): return .bool(value)
    case let .textList(values): return .array(values.map(CanonicalJSONValue.string))
    }
}
