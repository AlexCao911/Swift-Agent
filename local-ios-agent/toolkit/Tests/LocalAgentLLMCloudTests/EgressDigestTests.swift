import Foundation
import LocalAgentLLMContracts
import Testing
@testable import LocalAgentLLMCloud

@Suite("Cloud egress canonical documents")
struct EgressDigestTests {
    @Test
    func documentBuildersMatchRegisteredGoldenFixtures() throws {
        let issued = try #require(canonicalEgressDate("2027-01-15T08:00:00.000Z"))
        let authorizationIssued = try #require(canonicalEgressDate("2027-01-15T08:01:00.000Z"))
        let approval = ProviderRetentionApproval(
            providerProfileID: "profile-main",
            providerProfileRevision: 3,
            origin: EgressOrigin(scheme: "https", host: "api.example.com", port: 443),
            retentionMode: .providerStateApproved,
            behavior: .serverSideConversationState,
            disclosedWindowClass: .thirtyOneToSixtyDays,
            decisionRevision: 2,
            issuedAt: issued,
            approvalDigest: ""
        )
        #expect(try providerRetentionApprovalDigest(approval).hex
            == "2bfb2bc5d25ff1d4f566ca9b74ce330da298ac30b5864e0d66b44be806a457ff")

        let summary = EgressApprovalDisplaySummary(
            disclosureDigest: String(repeating: "d", count: 64),
            priorScopeGrantDigest: nil,
            sourceSummary: SafeDisplaySummary(
                sourceKinds: [.conversation, .toolResult],
                addedItemCounts: [.init(dataClass: .contacts, count: 2)],
                approximateAddedSize: .lessThanOneKiB,
                triggeringToolDisplayKeys: ["contacts.search"]
            ),
            newlyAddedDataClasses: [.contacts, .toolResult],
            approvalSummaryDigest: ""
        )
        #expect(try egressApprovalSummaryDigest(summary).hex
            == "243230b3304a10c976e13d061b07f12ad91269c6ba6eb240e31221a0c3421063")

        let grant = EgressScopeGrant(
            grantID: "grant-1",
            runID: "run-1",
            providerProfileID: "profile-main",
            providerProfileRevision: 3,
            origin: EgressOrigin(scheme: "https", host: "api.example.com", port: 443),
            credentialGeneration: 7,
            retentionMode: .providerStateApproved,
            retentionApprovalRevision: 2,
            retentionApprovalDigest: String(repeating: "e", count: 64),
            allowedDataClasses: [.contacts, .text, .toolResult],
            maximumSensitivity: .sensitive,
            decisionRevision: 4,
            issuedAt: issued,
            expiresAt: try #require(canonicalEgressDate("2027-01-15T09:00:00.000Z")),
            revokedAt: nil,
            grantDigest: ""
        )
        #expect(try egressScopeGrantDigest(grant).hex
            == "744e2c0b5853d60789c2b33dd451596d576bc98a6f03703fae17908fc8caa4e2")

        let authorization = GenerationEgressAuthorization(
            authorizationID: "authorization-1",
            generationTurnID: "turn-2",
            disclosureDigest: String(repeating: "d", count: 64),
            approvalSummaryDigest: String(repeating: "b", count: 64),
            scopeGrantID: "grant-1",
            scopeGrantDigest: String(repeating: "f", count: 64),
            credentialGeneration: 7,
            retentionMode: .providerStateApproved,
            retentionApprovalRevision: 2,
            retentionApprovalDigest: String(repeating: "e", count: 64),
            issuedAt: authorizationIssued,
            expiresAt: try #require(canonicalEgressDate("2027-01-15T08:06:00.000Z")),
            authorizationDigest: ""
        )
        #expect(try egressGenerationAuthorizationDigest(authorization).hex
            == "d29010f4c1f04d5376352731e01d3186aa4480f6aa77f4edfeee4d58b848e337")

        let subject = EgressSubjectFixture(
            providerProfileID: "profile-main",
            providerProfileRevision: 3,
            origin: EgressOrigin(scheme: "https", host: "api.example.com", port: 443),
            credentialGeneration: 7,
            retentionMode: .providerStateApproved,
            retentionApprovalRevision: 2,
            retentionApprovalDigest: String(repeating: "e", count: 64),
            scopeGrantID: "grant-1",
            scopeGrantDigest: String(repeating: "f", count: 64),
            approvalSummaryDigest: String(repeating: "b", count: 64),
            generationAuthorizationID: "authorization-1",
            generationAuthorizationDigest: String(repeating: "a", count: 64)
        )
        #expect(try egressSubjectDigest(subject).hex
            == "76b0b3fceb333c00e51234a462b17e8899f909288c6285b808d36d0b3ee92351")

        let audit = EgressAuditRecord(
            auditID: "audit-1",
            runID: "run-1",
            previousChainDigest: nil,
            generationTurnID: "turn-2",
            disclosureDigest: String(repeating: "d", count: 64),
            scopeGrantDigest: String(repeating: "f", count: 64),
            generationAuthorizationDigest: String(repeating: "a", count: 64),
            recordedAt: authorizationIssued,
            chainDigest: ""
        )
        #expect(try egressAuditChainDigest(audit).hex
            == "80eb05d3e32fb1c8e3d51592a6d5272b48e8457121c1601f7d663d31535ae344")
    }

    @Test
    func unorderedScopeSetsProduceOneDigestAndMutationsChangeIt() throws {
        let issued = Date(timeIntervalSince1970: 1_800_000_000)
        let first = EgressScopeGrant(
            grantID: "grant",
            runID: "run",
            providerProfileID: "profile",
            providerProfileRevision: 1,
            origin: EgressOrigin(scheme: "https", host: "api.example.com", port: 443),
            credentialGeneration: 1,
            retentionMode: .statelessRequired,
            retentionApprovalRevision: nil,
            retentionApprovalDigest: nil,
            allowedDataClasses: [.text, .contacts],
            maximumSensitivity: .private,
            decisionRevision: 1,
            issuedAt: issued,
            expiresAt: nil,
            revokedAt: nil,
            grantDigest: ""
        )
        let reordered = EgressScopeGrant(
            grantID: first.grantID,
            runID: first.runID,
            providerProfileID: first.providerProfileID,
            providerProfileRevision: first.providerProfileRevision,
            origin: first.origin,
            credentialGeneration: first.credentialGeneration,
            retentionMode: first.retentionMode,
            retentionApprovalRevision: nil,
            retentionApprovalDigest: nil,
            allowedDataClasses: [.contacts, .text],
            maximumSensitivity: first.maximumSensitivity,
            decisionRevision: first.decisionRevision,
            issuedAt: first.issuedAt,
            expiresAt: nil,
            revokedAt: nil,
            grantDigest: ""
        )
        #expect(try egressScopeGrantDigest(first) == egressScopeGrantDigest(reordered))

        let changed = EgressScopeGrant(
            grantID: first.grantID,
            runID: first.runID,
            providerProfileID: first.providerProfileID,
            providerProfileRevision: first.providerProfileRevision,
            origin: first.origin,
            credentialGeneration: 2,
            retentionMode: first.retentionMode,
            retentionApprovalRevision: nil,
            retentionApprovalDigest: nil,
            allowedDataClasses: first.allowedDataClasses,
            maximumSensitivity: first.maximumSensitivity,
            decisionRevision: first.decisionRevision,
            issuedAt: first.issuedAt,
            expiresAt: nil,
            revokedAt: nil,
            grantDigest: ""
        )
        #expect(try egressScopeGrantDigest(first) != egressScopeGrantDigest(changed))
    }

    @Test
    func nonMillisecondTimestampIsRejected() {
        let grant = EgressScopeGrant(
            grantID: "grant",
            runID: "run",
            providerProfileID: "profile",
            providerProfileRevision: 1,
            origin: EgressOrigin(scheme: "https", host: "api.example.com", port: 443),
            credentialGeneration: 1,
            retentionMode: .statelessRequired,
            retentionApprovalRevision: nil,
            retentionApprovalDigest: nil,
            allowedDataClasses: [.text],
            maximumSensitivity: .routine,
            decisionRevision: 1,
            issuedAt: Date(timeIntervalSince1970: 1_800_000_000.000_4),
            expiresAt: nil,
            revokedAt: nil,
            grantDigest: ""
        )
        #expect(throws: EgressDocumentFailure.self) {
            try egressScopeGrantDigest(grant)
        }
    }
}
