import Foundation
import LocalAgentLLMContracts
import LocalAgentLLMCore

package struct CloudWireRequestFailure: Error, Equatable, Sendable {
    package let code: String
    package let message: String

    package init(code: String, message: String) {
        self.code = code
        self.message = message
    }
}

package struct CloudResolvedAttachmentIdentity: Equatable, Sendable {
    package let attachmentID: String
    package let revision: UInt64
    package let contentDigest: String
    package let mediaType: String
    package let byteCount: UInt64

    package init(
        attachmentID: String,
        revision: UInt64,
        contentDigest: String,
        mediaType: String,
        byteCount: UInt64
    ) {
        self.attachmentID = attachmentID
        self.revision = revision
        self.contentDigest = contentDigest
        self.mediaType = mediaType
        self.byteCount = byteCount
    }
}

package protocol CloudAttachmentIdentityResolving: Sendable {
    func resolveIdentities(
        for input: AgentLLMInput,
        sourceRevisionDocument: CanonicalJSONValue
    ) throws -> [CloudResolvedAttachmentIdentity]
}

package struct CloudGenerationTurnCandidate: Equatable, Sendable {
    package let input: AgentLLMInput
    package let canonicalToolSchema: CanonicalJSONValue
    package let sourceRevisionDocument: CanonicalJSONValue
    package let resolvedAttachments: [CloudResolvedAttachmentIdentity]
    package let toolResults: [NormalizedToolResult]
    package let providerRequiredSemanticHistory: CanonicalJSONValue
    package let disclosure: GenerationDisclosure
    package let resolvedParameters: GenerationConfiguration

    package init(
        input: AgentLLMInput,
        canonicalToolSchema: CanonicalJSONValue,
        sourceRevisionDocument: CanonicalJSONValue,
        resolvedAttachments: [CloudResolvedAttachmentIdentity],
        toolResults: [NormalizedToolResult],
        providerRequiredSemanticHistory: CanonicalJSONValue,
        disclosure: GenerationDisclosure,
        resolvedParameters: GenerationConfiguration
    ) {
        self.input = input
        self.canonicalToolSchema = canonicalToolSchema
        self.sourceRevisionDocument = sourceRevisionDocument
        self.resolvedAttachments = resolvedAttachments
        self.toolResults = toolResults
        self.providerRequiredSemanticHistory = providerRequiredSemanticHistory
        self.disclosure = disclosure
        self.resolvedParameters = resolvedParameters
    }
}

package struct CloudWireRequest: Equatable, Sendable {
    package let method: String
    package let path: String
    package let queryItems: [URLQueryItem]
    package let headers: [String: String]
    package let body: Data?
    package let dataProvenance: CloudWireDataProvenance

    package init(
        method: String,
        path: String,
        queryItems: [URLQueryItem],
        headers: [String: String],
        body: Data?,
        dataProvenance: CloudWireDataProvenance = .generation
    ) throws {
        guard !method.isEmpty, method == method.uppercased() else {
            throw CloudWireRequestFailure(
                code: "cloud_wire.method_invalid",
                message: "cloud wire method must be non-empty uppercase ASCII"
            )
        }
        guard path.hasPrefix("/"),
              !path.hasPrefix("//"),
              !path.contains("://"),
              !path.contains("?"),
              !path.contains("#")
        else {
            throw CloudWireRequestFailure(
                code: "cloud_wire.path_not_relative",
                message: "cloud wire path must be origin-relative"
            )
        }
        let forbiddenHeaders = Set([
            "authorization", "proxy-authorization", "x-api-key", "x-goog-api-key",
        ])
        guard headers.keys.allSatisfy({
            let name = $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return !forbiddenHeaders.contains(name)
        }) else {
            throw CloudWireRequestFailure(
                code: "cloud_wire.authentication_forbidden",
                message: "adapter wire headers cannot contain authentication"
            )
        }
        let forbiddenQueryNames = Set([
            "api_key", "api-key", "key", "access_token", "token", "credential",
        ])
        guard queryItems.allSatisfy({
            let name = $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return !forbiddenQueryNames.contains(name)
        }) else {
            throw CloudWireRequestFailure(
                code: "cloud_wire.authentication_forbidden",
                message: "adapter wire query cannot contain authentication"
            )
        }
        self.method = method
        self.path = path
        self.queryItems = queryItems
        self.headers = headers
        self.body = body
        self.dataProvenance = dataProvenance
    }
}

package struct CloudProviderSessionContext: Equatable, Sendable {
    package let targetID: LLMTargetID
    package let targetRevision: UInt64
    package let providerProfileID: String
    package let providerProfileRevision: UInt64
    package let modelID: String
    package let retentionMode: ProviderRetentionMode
    package let retentionApprovalRevision: UInt64?
    package let retentionApprovalDigest: String?
    package let hostProcessEpoch: HostProcessEpoch

    package init(
        targetID: LLMTargetID,
        targetRevision: UInt64,
        providerProfileID: String,
        providerProfileRevision: UInt64,
        modelID: String,
        retentionMode: ProviderRetentionMode,
        retentionApprovalRevision: UInt64?,
        retentionApprovalDigest: String?,
        hostProcessEpoch: HostProcessEpoch
    ) {
        self.targetID = targetID
        self.targetRevision = targetRevision
        self.providerProfileID = providerProfileID
        self.providerProfileRevision = providerProfileRevision
        self.modelID = modelID
        self.retentionMode = retentionMode
        self.retentionApprovalRevision = retentionApprovalRevision
        self.retentionApprovalDigest = retentionApprovalDigest
        self.hostProcessEpoch = hostProcessEpoch
    }
}

package struct SSEEvent: Equatable, Sendable {
    package let event: String?
    package let id: String?
    package let retryMilliseconds: UInt64?
    package let data: Data

    package init(
        event: String?,
        id: String?,
        retryMilliseconds: UInt64?,
        data: Data
    ) {
        self.event = event
        self.id = id
        self.retryMilliseconds = retryMilliseconds
        self.data = data
    }
}
