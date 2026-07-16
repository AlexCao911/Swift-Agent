import Foundation
import LocalAgentLLMContracts

public struct EgressDocumentFailure: Error, Equatable, Sendable {
    public let code: String
    public let message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }
}

public enum EgressDecision: String, Equatable, Sendable {
    case allow
    case deny
}

extension EgressDecision: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard let value = Self(rawValue: raw) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "unknown egress decision"
            )
        }
        self = value
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public struct EgressApprovalDisplaySummary: Codable, Equatable, Sendable {
    public let disclosureDigest: String
    public let priorScopeGrantDigest: String?
    public let sourceSummary: SafeDisplaySummary
    public let newlyAddedDataClasses: Set<EgressDataClass>
    public let approvalSummaryDigest: String

    public init(
        disclosureDigest: String,
        priorScopeGrantDigest: String?,
        sourceSummary: SafeDisplaySummary,
        newlyAddedDataClasses: Set<EgressDataClass>,
        approvalSummaryDigest: String
    ) {
        self.disclosureDigest = disclosureDigest
        self.priorScopeGrantDigest = priorScopeGrantDigest
        self.sourceSummary = sourceSummary
        self.newlyAddedDataClasses = newlyAddedDataClasses
        self.approvalSummaryDigest = approvalSummaryDigest
    }
}

public struct EgressScopeGrant: Codable, Equatable, Sendable {
    public let grantID: String
    public let runID: String
    public let providerProfileID: String
    public let providerProfileRevision: UInt64
    public let origin: EgressOrigin
    public let credentialGeneration: UInt64
    public let retentionMode: ProviderRetentionMode
    public let retentionApprovalRevision: UInt64?
    public let retentionApprovalDigest: String?
    public let allowedDataClasses: Set<EgressDataClass>
    public let maximumSensitivity: DataSensitivity
    public let decisionRevision: UInt64
    public let issuedAt: Date
    public let expiresAt: Date?
    public let revokedAt: Date?
    public let grantDigest: String

    public init(
        grantID: String,
        runID: String,
        providerProfileID: String,
        providerProfileRevision: UInt64,
        origin: EgressOrigin,
        credentialGeneration: UInt64,
        retentionMode: ProviderRetentionMode,
        retentionApprovalRevision: UInt64?,
        retentionApprovalDigest: String?,
        allowedDataClasses: Set<EgressDataClass>,
        maximumSensitivity: DataSensitivity,
        decisionRevision: UInt64,
        issuedAt: Date,
        expiresAt: Date?,
        revokedAt: Date?,
        grantDigest: String
    ) {
        self.grantID = grantID
        self.runID = runID
        self.providerProfileID = providerProfileID
        self.providerProfileRevision = providerProfileRevision
        self.origin = origin
        self.credentialGeneration = credentialGeneration
        self.retentionMode = retentionMode
        self.retentionApprovalRevision = retentionApprovalRevision
        self.retentionApprovalDigest = retentionApprovalDigest
        self.allowedDataClasses = allowedDataClasses
        self.maximumSensitivity = maximumSensitivity
        self.decisionRevision = decisionRevision
        self.issuedAt = issuedAt
        self.expiresAt = expiresAt
        self.revokedAt = revokedAt
        self.grantDigest = grantDigest
    }
}

public struct GenerationEgressAuthorization: Codable, Equatable, Sendable {
    public let authorizationID: String
    public let generationTurnID: String
    public let disclosureDigest: String
    public let approvalSummaryDigest: String
    public let scopeGrantID: String
    public let scopeGrantDigest: String
    public let credentialGeneration: UInt64
    public let retentionMode: ProviderRetentionMode
    public let retentionApprovalRevision: UInt64?
    public let retentionApprovalDigest: String?
    public let issuedAt: Date
    public let expiresAt: Date
    public let authorizationDigest: String

    public init(
        authorizationID: String,
        generationTurnID: String,
        disclosureDigest: String,
        approvalSummaryDigest: String,
        scopeGrantID: String,
        scopeGrantDigest: String,
        credentialGeneration: UInt64,
        retentionMode: ProviderRetentionMode,
        retentionApprovalRevision: UInt64?,
        retentionApprovalDigest: String?,
        issuedAt: Date,
        expiresAt: Date,
        authorizationDigest: String
    ) {
        self.authorizationID = authorizationID
        self.generationTurnID = generationTurnID
        self.disclosureDigest = disclosureDigest
        self.approvalSummaryDigest = approvalSummaryDigest
        self.scopeGrantID = scopeGrantID
        self.scopeGrantDigest = scopeGrantDigest
        self.credentialGeneration = credentialGeneration
        self.retentionMode = retentionMode
        self.retentionApprovalRevision = retentionApprovalRevision
        self.retentionApprovalDigest = retentionApprovalDigest
        self.issuedAt = issuedAt
        self.expiresAt = expiresAt
        self.authorizationDigest = authorizationDigest
    }
}

public struct EgressAuditRecord: Codable, Equatable, Sendable {
    public let auditID: String
    public let runID: String
    public let previousChainDigest: String?
    public let generationTurnID: String
    public let disclosureDigest: String
    public let scopeGrantDigest: String
    public let generationAuthorizationDigest: String
    public let recordedAt: Date
    public let chainDigest: String

    public init(
        auditID: String,
        runID: String,
        previousChainDigest: String?,
        generationTurnID: String,
        disclosureDigest: String,
        scopeGrantDigest: String,
        generationAuthorizationDigest: String,
        recordedAt: Date,
        chainDigest: String
    ) {
        self.auditID = auditID
        self.runID = runID
        self.previousChainDigest = previousChainDigest
        self.generationTurnID = generationTurnID
        self.disclosureDigest = disclosureDigest
        self.scopeGrantDigest = scopeGrantDigest
        self.generationAuthorizationDigest = generationAuthorizationDigest
        self.recordedAt = recordedAt
        self.chainDigest = chainDigest
    }
}

package struct EgressSubjectFixture: Equatable, Sendable {
    package let providerProfileID: String
    package let providerProfileRevision: UInt64
    package let origin: EgressOrigin
    package let credentialGeneration: UInt64
    package let retentionMode: ProviderRetentionMode
    package let retentionApprovalRevision: UInt64?
    package let retentionApprovalDigest: String?
    package let scopeGrantID: String
    package let scopeGrantDigest: String
    package let approvalSummaryDigest: String
    package let generationAuthorizationID: String
    package let generationAuthorizationDigest: String

    package init(
        providerProfileID: String,
        providerProfileRevision: UInt64,
        origin: EgressOrigin,
        credentialGeneration: UInt64,
        retentionMode: ProviderRetentionMode,
        retentionApprovalRevision: UInt64?,
        retentionApprovalDigest: String?,
        scopeGrantID: String,
        scopeGrantDigest: String,
        approvalSummaryDigest: String,
        generationAuthorizationID: String,
        generationAuthorizationDigest: String
    ) {
        self.providerProfileID = providerProfileID
        self.providerProfileRevision = providerProfileRevision
        self.origin = origin
        self.credentialGeneration = credentialGeneration
        self.retentionMode = retentionMode
        self.retentionApprovalRevision = retentionApprovalRevision
        self.retentionApprovalDigest = retentionApprovalDigest
        self.scopeGrantID = scopeGrantID
        self.scopeGrantDigest = scopeGrantDigest
        self.approvalSummaryDigest = approvalSummaryDigest
        self.generationAuthorizationID = generationAuthorizationID
        self.generationAuthorizationDigest = generationAuthorizationDigest
    }
}

package func providerRetentionApprovalDigest(
    _ approval: ProviderRetentionApproval
) throws -> CanonicalDigest {
    try validateIdentity(
        profileID: approval.providerProfileID,
        profileRevision: approval.providerProfileRevision,
        origin: approval.origin
    )
    try validateRetention(
        mode: approval.retentionMode,
        revision: approval.decisionRevision,
        digest: nil,
        requiresDigest: false
    )
    guard approval.retentionMode == .providerStateApproved else {
        throw documentFailure("egress_document.retention_invalid", "retention approval must approve provider state")
    }
    let document = try CanonicalJSONValue.object(entries: [
        .init(name: "approval_revision", value: decimal(approval.decisionRevision)),
        .init(name: "behavior", value: .string(approval.behavior.rawValue)),
        .init(name: "decision", value: .string(EgressDecision.allow.rawValue)),
        .init(name: "issued_at", value: .string(try canonicalTimestamp(approval.issuedAt))),
        .init(name: "origin", value: try originDocument(approval.origin)),
        .init(name: "provider_profile_id", value: .string(approval.providerProfileID)),
        .init(name: "provider_profile_revision", value: decimal(approval.providerProfileRevision)),
        .init(name: "retention_mode", value: .string(approval.retentionMode.rawValue)),
        .init(name: "schema_version", value: .string("1")),
        .init(name: "window_class", value: .string(approval.disclosedWindowClass.rawValue)),
    ])
    return try CanonicalDigestV1.digest(
        domain: "provider-retention-approval:v1",
        document: document
    )
}

package func egressApprovalSummaryDigest(
    _ summary: EgressApprovalDisplaySummary
) throws -> CanonicalDigest {
    try requireDigest(summary.disclosureDigest, field: "disclosure digest")
    if let prior = summary.priorScopeGrantDigest {
        try requireDigest(prior, field: "prior scope grant digest")
    }
    guard summary.sourceSummary.triggeringToolDisplayKeys.allSatisfy({ !$0.isEmpty })
    else {
        throw documentFailure("egress_document.summary_invalid", "egress approval summary is invalid")
    }
    let document = try CanonicalJSONValue.object(entries: [
        .init(name: "disclosure_digest", value: .string(summary.disclosureDigest)),
        .init(
            name: "newly_added_data_classes",
            value: sortedDataClasses(summary.newlyAddedDataClasses)
        ),
        .init(
            name: "prior_scope_grant_digest",
            value: summary.priorScopeGrantDigest.map(CanonicalJSONValue.string) ?? .null
        ),
        .init(name: "schema_version", value: .string("1")),
        .init(name: "source_summary", value: try safeSummaryDocument(summary.sourceSummary)),
    ])
    return try CanonicalDigestV1.digest(
        domain: "egress-approval-summary:v1",
        document: document
    )
}

package func egressScopeGrantDigest(_ grant: EgressScopeGrant) throws -> CanonicalDigest {
    try validateIdentity(
        profileID: grant.providerProfileID,
        profileRevision: grant.providerProfileRevision,
        origin: grant.origin
    )
    try validateRetention(
        mode: grant.retentionMode,
        revision: grant.retentionApprovalRevision,
        digest: grant.retentionApprovalDigest,
        requiresDigest: true
    )
    guard !grant.grantID.isEmpty, !grant.runID.isEmpty,
          !grant.allowedDataClasses.isEmpty, grant.decisionRevision > 0
    else { throw documentFailure("egress_document.grant_invalid", "egress scope grant is invalid") }
    let document = try CanonicalJSONValue.object(entries: [
        .init(name: "allowed_data_classes", value: sortedDataClasses(grant.allowedDataClasses)),
        .init(name: "credential_generation", value: decimal(grant.credentialGeneration)),
        .init(name: "decision", value: .string(EgressDecision.allow.rawValue)),
        .init(name: "decision_revision", value: decimal(grant.decisionRevision)),
        .init(name: "expires_at", value: try optionalTimestamp(grant.expiresAt)),
        .init(name: "grant_id", value: .string(grant.grantID)),
        .init(name: "issued_at", value: .string(try canonicalTimestamp(grant.issuedAt))),
        .init(name: "maximum_sensitivity", value: .string(grant.maximumSensitivity.rawValue)),
        .init(name: "origin", value: try originDocument(grant.origin)),
        .init(name: "provider_profile_id", value: .string(grant.providerProfileID)),
        .init(name: "provider_profile_revision", value: decimal(grant.providerProfileRevision)),
        .init(
            name: "retention_approval_digest",
            value: grant.retentionApprovalDigest.map(CanonicalJSONValue.string) ?? .null
        ),
        .init(
            name: "retention_approval_revision",
            value: grant.retentionApprovalRevision.map(decimal) ?? .null
        ),
        .init(name: "retention_mode", value: .string(grant.retentionMode.rawValue)),
        .init(name: "revoked_at", value: try optionalTimestamp(grant.revokedAt)),
        .init(name: "run_id", value: .string(grant.runID)),
        .init(name: "schema_version", value: .string("1")),
    ])
    return try CanonicalDigestV1.digest(domain: "egress-scope-grant:v1", document: document)
}

package func egressGenerationAuthorizationDigest(
    _ authorization: GenerationEgressAuthorization
) throws -> CanonicalDigest {
    for (value, field) in [
        (authorization.disclosureDigest, "disclosure digest"),
        (authorization.approvalSummaryDigest, "approval summary digest"),
        (authorization.scopeGrantDigest, "scope grant digest"),
    ] { try requireDigest(value, field: field) }
    try validateRetention(
        mode: authorization.retentionMode,
        revision: authorization.retentionApprovalRevision,
        digest: authorization.retentionApprovalDigest,
        requiresDigest: true
    )
    guard !authorization.authorizationID.isEmpty,
          !authorization.generationTurnID.isEmpty,
          !authorization.scopeGrantID.isEmpty,
          authorization.expiresAt > authorization.issuedAt
    else {
        throw documentFailure("egress_document.authorization_invalid", "generation authorization is invalid")
    }
    let document = try CanonicalJSONValue.object(entries: [
        .init(name: "approval_summary_digest", value: .string(authorization.approvalSummaryDigest)),
        .init(name: "authorization_id", value: .string(authorization.authorizationID)),
        .init(name: "credential_generation", value: decimal(authorization.credentialGeneration)),
        .init(name: "decision", value: .string(EgressDecision.allow.rawValue)),
        .init(name: "disclosure_digest", value: .string(authorization.disclosureDigest)),
        .init(name: "expires_at", value: .string(try canonicalTimestamp(authorization.expiresAt))),
        .init(name: "generation_turn_id", value: .string(authorization.generationTurnID)),
        .init(name: "issued_at", value: .string(try canonicalTimestamp(authorization.issuedAt))),
        .init(
            name: "retention_approval_digest",
            value: authorization.retentionApprovalDigest.map(CanonicalJSONValue.string) ?? .null
        ),
        .init(
            name: "retention_approval_revision",
            value: authorization.retentionApprovalRevision.map(decimal) ?? .null
        ),
        .init(name: "retention_mode", value: .string(authorization.retentionMode.rawValue)),
        .init(name: "schema_version", value: .string("1")),
        .init(name: "scope_grant_digest", value: .string(authorization.scopeGrantDigest)),
        .init(name: "scope_grant_id", value: .string(authorization.scopeGrantID)),
    ])
    return try CanonicalDigestV1.digest(
        domain: "egress-generation-authorization:v1",
        document: document
    )
}

package func egressSubjectDigest(_ subject: EgressSubjectFixture) throws -> CanonicalDigest {
    try validateIdentity(
        profileID: subject.providerProfileID,
        profileRevision: subject.providerProfileRevision,
        origin: subject.origin
    )
    for (value, field) in [
        (subject.scopeGrantDigest, "scope grant digest"),
        (subject.approvalSummaryDigest, "approval summary digest"),
        (subject.generationAuthorizationDigest, "generation authorization digest"),
    ] { try requireDigest(value, field: field) }
    try validateRetention(
        mode: subject.retentionMode,
        revision: subject.retentionApprovalRevision,
        digest: subject.retentionApprovalDigest,
        requiresDigest: true
    )
    guard !subject.scopeGrantID.isEmpty, !subject.generationAuthorizationID.isEmpty else {
        throw documentFailure("egress_document.subject_invalid", "egress subject identity is empty")
    }
    let document = try CanonicalJSONValue.object(entries: [
        .init(name: "approval_summary_digest", value: .string(subject.approvalSummaryDigest)),
        .init(name: "credential_generation", value: decimal(subject.credentialGeneration)),
        .init(name: "generation_authorization_digest", value: .string(subject.generationAuthorizationDigest)),
        .init(name: "generation_authorization_id", value: .string(subject.generationAuthorizationID)),
        .init(name: "kind", value: .string("cloud")),
        .init(name: "origin", value: try originDocument(subject.origin)),
        .init(name: "provider_profile_id", value: .string(subject.providerProfileID)),
        .init(name: "provider_profile_revision", value: decimal(subject.providerProfileRevision)),
        .init(
            name: "retention_approval_digest",
            value: subject.retentionApprovalDigest.map(CanonicalJSONValue.string) ?? .null
        ),
        .init(
            name: "retention_approval_revision",
            value: subject.retentionApprovalRevision.map(decimal) ?? .null
        ),
        .init(name: "retention_mode", value: .string(subject.retentionMode.rawValue)),
        .init(name: "schema_version", value: .string("1")),
        .init(name: "scope_grant_digest", value: .string(subject.scopeGrantDigest)),
        .init(name: "scope_grant_id", value: .string(subject.scopeGrantID)),
    ])
    return try CanonicalDigestV1.digest(domain: "egress-subject:v1", document: document)
}

package func egressAuditChainDigest(_ audit: EgressAuditRecord) throws -> CanonicalDigest {
    for (value, field) in [
        (audit.disclosureDigest, "disclosure digest"),
        (audit.scopeGrantDigest, "scope grant digest"),
        (audit.generationAuthorizationDigest, "generation authorization digest"),
    ] { try requireDigest(value, field: field) }
    if let previous = audit.previousChainDigest {
        try requireDigest(previous, field: "previous chain digest")
    }
    guard !audit.auditID.isEmpty, !audit.runID.isEmpty, !audit.generationTurnID.isEmpty else {
        throw documentFailure("egress_document.audit_invalid", "egress audit identity is empty")
    }
    let document = try CanonicalJSONValue.object(entries: [
        .init(name: "audit_id", value: .string(audit.auditID)),
        .init(name: "decision", value: .string(EgressDecision.allow.rawValue)),
        .init(name: "disclosure_digest", value: .string(audit.disclosureDigest)),
        .init(name: "generation_authorization_digest", value: .string(audit.generationAuthorizationDigest)),
        .init(name: "generation_turn_id", value: .string(audit.generationTurnID)),
        .init(
            name: "previous_chain_digest",
            value: audit.previousChainDigest.map(CanonicalJSONValue.string) ?? .null
        ),
        .init(name: "recorded_at", value: .string(try canonicalTimestamp(audit.recordedAt))),
        .init(name: "run_id", value: .string(audit.runID)),
        .init(name: "schema_version", value: .string("1")),
        .init(name: "scope_grant_digest", value: .string(audit.scopeGrantDigest)),
    ])
    return try CanonicalDigestV1.digest(domain: "egress-audit-chain:v1", document: document)
}

package func credentialUseLeaseDigest(_ lease: CredentialUseLease) throws -> CanonicalDigest {
    guard !lease.leaseID.isEmpty, !lease.credentialRef.isEmpty else {
        throw documentFailure("egress_document.lease_invalid", "credential lease identity is empty")
    }
    let document = try CanonicalJSONValue.object(entries: [
        .init(name: "credential_ref", value: .string(lease.credentialRef)),
        .init(name: "generation", value: decimal(lease.generation)),
        .init(name: "host_process_epoch", value: .string(lease.hostProcessEpoch.rawValue)),
        .init(name: "lease_id", value: .string(lease.leaseID)),
        .init(
            name: "preparation_id",
            value: lease.preparationID.map(CanonicalJSONValue.string) ?? .null
        ),
        .init(name: "purpose", value: .string(lease.purpose.rawValue)),
        .init(name: "schema_version", value: .string("1")),
    ])
    return try CanonicalDigestV1.digest(domain: "credential-use-lease:v1", document: document)
}

package func canonicalEgressDate(_ value: String) -> Date? {
    let formatter = canonicalDateFormatter()
    guard let date = formatter.date(from: value),
          (try? canonicalTimestamp(date)) == value
    else { return nil }
    return date
}

func millisecondDate(_ date: Date) -> Date {
    Date(timeIntervalSince1970: floor(date.timeIntervalSince1970 * 1_000) / 1_000)
}

private func canonicalTimestamp(_ date: Date) throws -> String {
    let milliseconds = date.timeIntervalSince1970 * 1_000
    guard milliseconds.isFinite,
          abs(milliseconds - milliseconds.rounded()) < 0.000_1
    else {
        throw documentFailure(
            "egress_document.timestamp_noncanonical",
            "egress timestamps require exact millisecond precision"
        )
    }
    return canonicalDateFormatter().string(from: date)
}

private func canonicalDateFormatter() -> DateFormatter {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"
    return formatter
}

private func validateIdentity(
    profileID: String,
    profileRevision: UInt64,
    origin: EgressOrigin
) throws {
    guard !profileID.isEmpty, profileRevision > 0,
          origin.scheme == "https", !origin.host.isEmpty, origin.port > 0
    else { throw documentFailure("egress_document.identity_invalid", "egress identity is invalid") }
}

private func validateRetention(
    mode: ProviderRetentionMode,
    revision: UInt64?,
    digest: String?,
    requiresDigest: Bool
) throws {
    switch mode {
    case .statelessRequired:
        guard revision == nil, digest == nil else {
            throw documentFailure("egress_document.retention_invalid", "stateless mode cannot bind retention approval")
        }
    case .providerStateApproved:
        guard let revision, revision > 0 else {
            throw documentFailure("egress_document.retention_invalid", "provider state requires approval revision")
        }
        if requiresDigest {
            guard let digest else {
                throw documentFailure("egress_document.retention_invalid", "provider state requires approval digest")
            }
            try requireDigest(digest, field: "retention approval digest")
        }
    }
}

private func safeSummaryDocument(_ summary: SafeDisplaySummary) throws -> CanonicalJSONValue {
    let countClasses = summary.addedItemCounts.map(\.dataClass)
    guard Set(countClasses).count == countClasses.count,
          summary.triggeringToolDisplayKeys.allSatisfy({ !$0.isEmpty })
    else { throw documentFailure("egress_document.summary_invalid", "safe display summary is invalid") }
    let counts = try summary.addedItemCounts
        .sorted { $0.dataClass.rawValue < $1.dataClass.rawValue }
        .map { count in
            try CanonicalJSONValue.object(entries: [
                .init(name: "count", value: decimal(count.count)),
                .init(name: "data_class", value: .string(count.dataClass.rawValue)),
            ])
        }
    return try .object(entries: [
        .init(name: "added_item_counts", value: .array(counts)),
        .init(name: "approximate_added_size", value: .string(summary.approximateAddedSize.rawValue)),
        .init(
            name: "source_kinds",
            value: .array(summary.sourceKinds.map(\.rawValue).sorted().map(CanonicalJSONValue.string))
        ),
        .init(
            name: "triggering_tool_display_keys",
            value: .array(summary.triggeringToolDisplayKeys.sorted().map(CanonicalJSONValue.string))
        ),
    ])
}

private func originDocument(_ origin: EgressOrigin) throws -> CanonicalJSONValue {
    try .object(entries: [
        .init(name: "host", value: .string(origin.host)),
        .init(name: "port", value: .string(String(origin.port))),
        .init(name: "scheme", value: .string(origin.scheme)),
    ])
}

private func optionalTimestamp(_ date: Date?) throws -> CanonicalJSONValue {
    guard let date else { return .null }
    return .string(try canonicalTimestamp(date))
}

private func sortedDataClasses(_ values: Set<EgressDataClass>) -> CanonicalJSONValue {
    .array(values.map(\.rawValue).sorted().map(CanonicalJSONValue.string))
}

private func decimal(_ value: UInt64) -> CanonicalJSONValue {
    .string(String(value))
}

private func requireDigest(_ value: String, field: String) throws {
    guard value.utf8.count == 64, value.utf8.allSatisfy({
        ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102)
    }) else {
        throw documentFailure("egress_document.digest_invalid", "\(field) is not lowercase SHA-256")
    }
}

private func documentFailure(_ code: String, _ message: String) -> EgressDocumentFailure {
    EgressDocumentFailure(code: code, message: message)
}
