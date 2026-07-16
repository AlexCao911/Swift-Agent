import Testing
@testable import LocalAgentLLMCloud
import LocalAgentLLMContracts

@Suite("Cloud semantic turn validator")
struct CloudSemanticTurnValidatorTests {
    private let validator = CloudSemanticTurnValidator()

    @Test
    func validatesCompleteStartSemanticRequest() throws {
        let candidate = try fixtureCandidate()

        let validated = try validator.validate(candidate)

        #expect(validated.semantic == candidate)
        #expect(validated.contentDigest.hex == candidate.disclosure.contentDigest)
        #expect(validated.sourceRevisionDigest.hex == candidate.disclosure.sourceRevisionDigest)
    }

    @Test(arguments: SemanticMutation.allCases)
    func rejectsDisclosureForAnySemanticMutation(_ mutation: SemanticMutation) throws {
        let original = try fixtureCandidate(includeToolResult: true)
        let mutated = try mutation.apply(to: original)

        #expect(throws: CloudTurnValidationFailure.self) {
            try validator.validate(mutated)
        }
    }

    @Test
    func attachmentReferencesRequireOneExactAuthoritativeIdentity() throws {
        let original = try fixtureCandidate(includeAttachment: true)

        let missing = original.replacing(attachments: [])
        #expect(throws: CloudTurnValidationFailure.self) {
            try validator.validate(missing)
        }

        let duplicate = original.replacing(
            attachments: original.resolvedAttachments + original.resolvedAttachments
        )
        #expect(throws: CloudTurnValidationFailure.self) {
            try validator.validate(duplicate)
        }
    }

    @Test
    func duplicateSourceIdentitiesFailBeforeDigestComparison() throws {
        let original = try fixtureCandidate()
        let duplicateSources = try CanonicalJSONValue.object(entries: [
            .init(name: "sources", value: .array([
                try source(id: "frame-1", revision: 1),
                try source(id: "frame-1", revision: 2),
            ])),
        ])

        #expect(throws: CloudTurnValidationFailure.self) {
            try validator.validate(original.replacing(sourceDocument: duplicateSources))
        }
    }
}

enum SemanticMutation: String, CaseIterable, CustomTestStringConvertible {
    case message
    case toolSchema
    case sourceRevision
    case attachmentRevision
    case attachmentContentDigest
    case toolResult
    case semanticHistory

    var testDescription: String { rawValue }

    func apply(to candidate: CloudGenerationTurnCandidate) throws -> CloudGenerationTurnCandidate {
        switch self {
        case .message:
            return candidate.replacing(input: AgentLLMInput(
                inputID: candidate.input.inputID,
                messages: [.init(role: .user, content: [.text("tampered")])]
            ))
        case .toolSchema:
            return candidate.replacing(toolSchema: try .object(entries: [
                .init(name: "tools", value: .array([.string("tampered.tool")])),
            ]))
        case .sourceRevision:
            return candidate.replacing(sourceDocument: try .object(entries: [
                .init(name: "sources", value: .array([
                    try source(id: "frame-1", revision: 2),
                ])),
            ]))
        case .attachmentRevision:
            let first = candidate.resolvedAttachments[0]
            return candidate.replacing(attachments: [first.replacing(revision: first.revision + 1)])
        case .attachmentContentDigest:
            let first = candidate.resolvedAttachments[0]
            return candidate.replacing(attachments: [
                first.replacing(contentDigest: String(repeating: "d", count: 64)),
            ])
        case .toolResult:
            let first = candidate.toolResults[0]
            return candidate.replacing(toolResults: [NormalizedToolResult(
                callID: first.callID,
                toolName: first.toolName,
                result: .string("tampered result"),
                isError: first.isError,
                dataClasses: first.dataClasses,
                highestSensitivity: first.highestSensitivity
            )])
        case .semanticHistory:
            return candidate.replacing(semanticHistory: .array([.string("different-history")]))
        }
    }
}

private func fixtureCandidate(
    includeAttachment: Bool = true,
    includeToolResult: Bool = false
) throws -> CloudGenerationTurnCandidate {
    let attachments = includeAttachment ? [CloudResolvedAttachmentIdentity(
        attachmentID: "attachment-1",
        revision: 7,
        contentDigest: String(repeating: "c", count: 64),
        mediaType: "image/heic",
        byteCount: 4_096
    )] : []
    let content: [LLMInputContent] = includeAttachment
        ? [.text("describe"), .attachment(
            modality: .image,
            attachmentID: "attachment-1",
            mediaType: "image/heic"
        )]
        : [.text("hello")]
    let results = includeToolResult ? [NormalizedToolResult(
        callID: "call-1",
        toolName: "contacts.search",
        result: try .object(entries: [
            .init(name: "count", value: .number(2)),
        ]),
        isError: false,
        dataClasses: [.contacts, .toolResult],
        highestSensitivity: .sensitive
    )] : []
    let placeholder = GenerationDisclosure(
        schemaVersion: "1",
        generationTurnID: "turn-1",
        contentDigest: String(repeating: "0", count: 64),
        sourceRevisionDigest: String(repeating: "0", count: 64),
        dataClasses: includeAttachment ? [.text, .attachment] : [.text],
        highestSensitivity: .private,
        safeDisplaySummary: .init(
            sourceKinds: includeAttachment ? [.conversation, .attachment] : [.conversation],
            addedItemCounts: [],
            approximateAddedSize: includeAttachment ? .oneToOneHundredKiB : .lessThanOneKiB,
            triggeringToolDisplayKeys: []
        )
    )
    let candidate = CloudGenerationTurnCandidate(
        input: AgentLLMInput(
            inputID: "input-1",
            messages: [.init(role: .user, content: content)]
        ),
        canonicalToolSchema: try .object(entries: [
            .init(name: "tools", value: .array([.string("contacts.search")])),
        ]),
        sourceRevisionDocument: try .object(entries: [
            .init(name: "sources", value: .array([
                try source(id: "frame-1", revision: 1),
            ])),
        ]),
        resolvedAttachments: attachments,
        toolResults: results,
        providerRequiredSemanticHistory: .array([.string("assistant-turn-1")]),
        disclosure: placeholder,
        resolvedParameters: GenerationConfiguration()
    )
    let contentDigest = try CanonicalDigestV1.digest(
        domain: "agent-input:v1",
        document: try semanticDocument(candidate)
    ).hex
    let sourceDigest = try CanonicalDigestV1.digest(
        domain: "source-revisions:v1",
        document: try sourceDocument(candidate)
    ).hex
    return candidate.replacing(disclosure: GenerationDisclosure(
        schemaVersion: "1",
        generationTurnID: "turn-1",
        contentDigest: contentDigest,
        sourceRevisionDigest: sourceDigest,
        dataClasses: placeholder.dataClasses,
        highestSensitivity: placeholder.highestSensitivity,
        safeDisplaySummary: placeholder.safeDisplaySummary
    ))
}

private func semanticDocument(_ candidate: CloudGenerationTurnCandidate) throws -> CanonicalJSONValue {
    try .object(entries: [
        .init(name: "canonical_tool_schema", value: candidate.canonicalToolSchema),
        .init(name: "input_id", value: .string(candidate.input.inputID)),
        .init(name: "messages", value: .array(try candidate.input.messages.map(messageDocument))),
        .init(
            name: "provider_required_semantic_history",
            value: candidate.providerRequiredSemanticHistory
        ),
        .init(
            name: "resolved_attachments",
            value: .array(try candidate.resolvedAttachments.map(attachmentDocument))
        ),
        .init(name: "schema_version", value: .string("1")),
        .init(name: "tool_results", value: .array(try candidate.toolResults.map(toolResultDocument))),
    ])
}

private func sourceDocument(_ candidate: CloudGenerationTurnCandidate) throws -> CanonicalJSONValue {
    try .object(entries: [
        .init(
            name: "resolved_attachments",
            value: .array(try candidate.resolvedAttachments.map(attachmentDocument))
        ),
        .init(name: "schema_version", value: .string("1")),
        .init(name: "source_revision_document", value: candidate.sourceRevisionDocument),
    ])
}

private func messageDocument(_ message: LLMInputMessage) throws -> CanonicalJSONValue {
    try .object(entries: [
        .init(name: "content", value: .array(try message.content.map { item in
            switch item {
            case let .text(text):
                try .object(entries: [
                    .init(name: "text", value: .string(text)),
                    .init(name: "type", value: .string("text")),
                ])
            case let .attachment(modality, attachmentID, mediaType):
                try .object(entries: [
                    .init(name: "attachment_id", value: .string(attachmentID)),
                    .init(name: "media_type", value: .string(mediaType)),
                    .init(name: "modality", value: .string(modality.rawValue)),
                    .init(name: "type", value: .string("attachment")),
                ])
            }
        })),
        .init(name: "role", value: .string(message.role.rawValue)),
    ])
}

private func attachmentDocument(_ attachment: CloudResolvedAttachmentIdentity) throws -> CanonicalJSONValue {
    try .object(entries: [
        .init(name: "attachment_id", value: .string(attachment.attachmentID)),
        .init(name: "byte_count", value: .string(String(attachment.byteCount))),
        .init(name: "content_digest", value: .string(attachment.contentDigest)),
        .init(name: "media_type", value: .string(attachment.mediaType)),
        .init(name: "revision", value: .string(String(attachment.revision))),
    ])
}

private func toolResultDocument(_ result: NormalizedToolResult) throws -> CanonicalJSONValue {
    try .object(entries: [
        .init(name: "call_id", value: .string(result.callID)),
        .init(
            name: "data_classes",
            value: .array(result.dataClasses.map(\.rawValue).sorted().map(CanonicalJSONValue.string))
        ),
        .init(name: "highest_sensitivity", value: .string(result.highestSensitivity.rawValue)),
        .init(name: "is_error", value: .bool(result.isError)),
        .init(name: "result", value: result.result),
        .init(name: "tool_name", value: .string(result.toolName)),
    ])
}

private func source(id: String, revision: UInt64) throws -> CanonicalJSONValue {
    try .object(entries: [
        .init(name: "revision", value: .string(String(revision))),
        .init(name: "source_id", value: .string(id)),
    ])
}

private extension CloudGenerationTurnCandidate {
    func replacing(
        input: AgentLLMInput? = nil,
        toolSchema: CanonicalJSONValue? = nil,
        sourceDocument: CanonicalJSONValue? = nil,
        attachments: [CloudResolvedAttachmentIdentity]? = nil,
        toolResults: [NormalizedToolResult]? = nil,
        semanticHistory: CanonicalJSONValue? = nil,
        disclosure: GenerationDisclosure? = nil
    ) -> Self {
        Self(
            input: input ?? self.input,
            canonicalToolSchema: toolSchema ?? canonicalToolSchema,
            sourceRevisionDocument: sourceDocument ?? sourceRevisionDocument,
            resolvedAttachments: attachments ?? resolvedAttachments,
            toolResults: toolResults ?? self.toolResults,
            providerRequiredSemanticHistory: semanticHistory ?? providerRequiredSemanticHistory,
            disclosure: disclosure ?? self.disclosure,
            resolvedParameters: resolvedParameters
        )
    }
}

private extension CloudResolvedAttachmentIdentity {
    func replacing(
        revision: UInt64? = nil,
        contentDigest: String? = nil
    ) -> Self {
        Self(
            attachmentID: attachmentID,
            revision: revision ?? self.revision,
            contentDigest: contentDigest ?? self.contentDigest,
            mediaType: mediaType,
            byteCount: byteCount
        )
    }
}
