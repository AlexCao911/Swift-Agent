import LocalAgentBridge
import LocalAgentLLMContracts
import Foundation

public struct LLMHostFailure: Error, Equatable, Sendable {
    public let code: String
    public let message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }
}

public struct PreparedLLMSession: Sendable {
    public let handle: String
    public let capabilitySnapshot: CapabilitySnapshot
    public let publicCapabilityAttestation: PreparedCapabilityAttestationDTO
    public let hostBindingID: String
    public let hostBindingRevision: UInt64
    public let hostBindingHash: String
    public let preparedSessionRegistrationDigest: String
    public let hostAttestation: HostAttestationV1Document
    public let credentialUseLeaseID: String?
    public let egressAttestationDigest: String
    public let sanitizedSnapshotID: String
    public let hostProcessEpoch: HostProcessEpoch
    public let disclosureGrantID: String
    public let dataClasses: [String: Bool]
    public let highestSensitivity: String

    public init(
        handle: String,
        capabilitySnapshot: CapabilitySnapshot,
        publicCapabilityAttestation: PreparedCapabilityAttestationDTO,
        hostBindingID: String,
        hostBindingRevision: UInt64,
        hostBindingHash: String,
        preparedSessionRegistrationDigest: String,
        hostAttestation: HostAttestationV1Document,
        credentialUseLeaseID: String?,
        egressAttestationDigest: String,
        sanitizedSnapshotID: String,
        hostProcessEpoch: HostProcessEpoch,
        disclosureGrantID: String = "not_applicable",
        dataClasses: [String: Bool] = [:],
        highestSensitivity: String = "routine"
    ) {
        self.handle = handle
        self.capabilitySnapshot = capabilitySnapshot
        self.publicCapabilityAttestation = publicCapabilityAttestation
        self.hostBindingID = hostBindingID
        self.hostBindingRevision = hostBindingRevision
        self.hostBindingHash = hostBindingHash
        self.preparedSessionRegistrationDigest = preparedSessionRegistrationDigest
        self.hostAttestation = hostAttestation
        self.credentialUseLeaseID = credentialUseLeaseID
        self.egressAttestationDigest = egressAttestationDigest
        self.sanitizedSnapshotID = sanitizedSnapshotID
        self.hostProcessEpoch = hostProcessEpoch
        self.disclosureGrantID = disclosureGrantID
        self.dataClasses = dataClasses
        self.highestSensitivity = highestSensitivity
    }
}

package struct OpenedHostSession: Sendable {
    package let prepared: PreparedLLMSession
    package let driver: any LLMHostSessionDriver

    package init(
        prepared: PreparedLLMSession,
        driver: any LLMHostSessionDriver
    ) {
        self.prepared = prepared
        self.driver = driver
    }
}

package struct ReservedHostSession: Sendable {
    package let registration: PreparedSessionRegistrationDTO
    package let allocation: AllocatedHostSession
    package let open: @Sendable () async throws -> OpenedHostSession

    package init(
        registration: PreparedSessionRegistrationDTO,
        allocation: AllocatedHostSession,
        open: @escaping @Sendable () async throws -> OpenedHostSession
    ) {
        self.registration = registration
        self.allocation = allocation
        self.open = open
    }
}

package protocol LLMHostSessionReserving: Sendable {
    func reserve(preview: RunPreparationPreviewDTO) async throws -> ReservedHostSession
}

package func preparedCapabilityAttestation(
    _ preview: RunPreparationPreviewDTO
) throws -> PreparedCapabilityAttestationDTO {
    guard let requirements = preview.binding.requirements else {
        throw LLMHostFailure(
            code: "llm.host.requirements_missing",
            message: "V2 preparation preview is missing provider-neutral requirements"
        )
    }
    let capabilities = requirements.capabilities.sorted()
    let modalities = requirements.inputModalities.sorted()
    let toolCalling = requirements.toolCallingMode != "disabled"
    let document = try CanonicalJSONValue.object(entries: [
        .init(
            name: "supported_capabilities",
            value: .array(capabilities.map(CanonicalJSONValue.string))
        ),
        .init(
            name: "input_modalities",
            value: .array(modalities.map(CanonicalJSONValue.string))
        ),
        .init(name: "context_length", value: .string(requirements.contextBudget)),
        .init(name: "streaming", value: .bool(requirements.streamingRequired)),
        .init(name: "tool_calling", value: .bool(toolCalling)),
        .init(
            name: "expiration_millis",
            value: .number(Double(preview.totalDeadlineMillis))
        ),
    ])
    let digest = try CanonicalDigestV1.digest(
        domain: "capability-attestation:v1",
        document: document
    ).hex
    return PreparedCapabilityAttestationDTO(
        supportedCapabilities: capabilities,
        inputModalities: modalities,
        contextLength: requirements.contextBudget,
        streaming: requirements.streamingRequired,
        toolCalling: toolCalling,
        expirationMillis: preview.totalDeadlineMillis,
        attestationDigest: digest
    )
}

package func hostAttestationExpiration(_ milliseconds: UInt64) -> String {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"
    return formatter.string(
        from: Date(timeIntervalSince1970: Double(milliseconds) / 1_000)
    )
}

package func initialDataClasses(
    _ preview: RunPreparationPreviewDTO
) -> [String: Bool] {
    Dictionary(
        uniqueKeysWithValues: (preview.binding.initialDataClasses ?? [])
            .map { ($0, true) }
    )
}
