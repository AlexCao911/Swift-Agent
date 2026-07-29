import LocalAgentLLMContracts

package struct ValidatedCloudGenerationTurn: Equatable, Sendable {
    package let semantic: CloudGenerationTurnCandidate
    package let contentDigest: CanonicalDigest
    package let sourceRevisionDigest: CanonicalDigest

    fileprivate init(
        semantic: CloudGenerationTurnCandidate,
        contentDigest: CanonicalDigest,
        sourceRevisionDigest: CanonicalDigest
    ) {
        self.semantic = semantic
        self.contentDigest = contentDigest
        self.sourceRevisionDigest = sourceRevisionDigest
    }
}

package struct CloudTurnValidationFailure: Error, Equatable, Sendable {
    package let code: String
    package let message: String

    package init(code: String, message: String) {
        self.code = code
        self.message = message
    }
}

package protocol CloudSemanticTurnValidating: Sendable {
    func validate(
        _ candidate: CloudGenerationTurnCandidate
    ) throws -> ValidatedCloudGenerationTurn
}

package struct CloudSemanticTurnValidator: CloudSemanticTurnValidating {
    package init() {}

    package func validate(
        _ candidate: CloudGenerationTurnCandidate
    ) throws -> ValidatedCloudGenerationTurn {
        do {
            _ = try candidate.disclosure.computedDigest()
        } catch {
            throw failure("cloud_turn.disclosure_invalid", "generation disclosure is invalid")
        }
        try validateSourceIdentities(candidate.sourceRevisionDocument)
        try validateAttachments(candidate)

        let contentDigest = try contentDigest(candidate)
        guard contentDigest.hex == candidate.disclosure.contentDigest else {
            throw failure(
                "cloud_turn.content_digest_mismatch",
                "semantic request does not match the disclosed content digest"
            )
        }

        let sourceRevisionDigest = try sourceRevisionDigest(candidate)
        guard sourceRevisionDigest.hex == candidate.disclosure.sourceRevisionDigest else {
            throw failure(
                "cloud_turn.source_revision_digest_mismatch",
                "source revisions do not match the disclosed source digest"
            )
        }
        return ValidatedCloudGenerationTurn(
            semantic: candidate,
            contentDigest: contentDigest,
            sourceRevisionDigest: sourceRevisionDigest
        )
    }

    package func contentDigest(
        _ candidate: CloudGenerationTurnCandidate
    ) throws -> CanonicalDigest {
        try CanonicalDigestV1.digest(
            domain: "agent-input:v1",
            document: semanticDocument(candidate)
        )
    }

    package func sourceRevisionDigest(
        _ candidate: CloudGenerationTurnCandidate
    ) throws -> CanonicalDigest {
        try CanonicalDigestV1.digest(
            domain: "source-revisions:v1",
            document: sourceDocument(candidate)
        )
    }

    private func validateAttachments(_ candidate: CloudGenerationTurnCandidate) throws {
        let hasAttachmentReference = candidate.input.messages.contains { message in
            message.content.contains { content in
                if case .attachment = content { return true }
                return false
            }
        }
        guard !hasAttachmentReference, candidate.resolvedAttachments.isEmpty else {
            throw failure(
                "capability.cloud_attachment_path_unavailable",
                "cloud attachment encoding and upload are unavailable in phase three"
            )
        }
        var referenced: [String: String] = [:]
        for message in candidate.input.messages {
            for content in message.content {
                guard case let .attachment(_, attachmentID, mediaType) = content else {
                    continue
                }
                guard !attachmentID.isEmpty, !mediaType.isEmpty else {
                    throw failure("cloud_turn.attachment_invalid", "attachment identity is empty")
                }
                if let existing = referenced[attachmentID], existing != mediaType {
                    throw failure(
                        "cloud_turn.attachment_conflict",
                        "one attachment identity has conflicting media types"
                    )
                }
                referenced[attachmentID] = mediaType
            }
        }

        var resolved: [String: CloudResolvedAttachmentIdentity] = [:]
        for identity in candidate.resolvedAttachments {
            guard !identity.attachmentID.isEmpty,
                  !identity.mediaType.isEmpty,
                  isLowercaseSHA256(identity.contentDigest),
                  resolved[identity.attachmentID] == nil
            else {
                throw failure(
                    "cloud_turn.attachment_identity_invalid",
                    "resolved attachment identity is malformed or duplicated"
                )
            }
            resolved[identity.attachmentID] = identity
        }
        guard Set(referenced.keys) == Set(resolved.keys) else {
            throw failure(
                "cloud_turn.attachment_identity_mismatch",
                "attachment references and resolved identities differ"
            )
        }
        for (attachmentID, mediaType) in referenced {
            guard resolved[attachmentID]?.mediaType == mediaType else {
                throw failure(
                    "cloud_turn.attachment_media_type_mismatch",
                    "attachment media type differs from its resolved identity"
                )
            }
        }
    }

    private func validateSourceIdentities(_ document: CanonicalJSONValue) throws {
        guard let sources = document.objectValue(forKey: "sources") else {
            return
        }
        guard case let .array(values) = sources else {
            throw failure("cloud_turn.source_document_invalid", "sources must be an array")
        }
        var identities = Set<String>()
        for value in values {
            guard case .object = value,
                  case let .string(identity)? = value.objectValue(forKey: "source_id"),
                  !identity.isEmpty,
                  identities.insert(identity).inserted
            else {
                throw failure(
                    "cloud_turn.source_identity_invalid",
                    "source identities must be non-empty and unique"
                )
            }
        }
    }

    private func semanticDocument(
        _ candidate: CloudGenerationTurnCandidate
    ) throws -> CanonicalJSONValue {
        try .object(entries: [
            .init(name: "canonical_tool_schema", value: candidate.canonicalToolSchema),
            .init(name: "input_id", value: .string(candidate.input.inputID)),
            .init(
                name: "messages",
                value: .array(try candidate.input.messages.map(messageDocument))
            ),
            .init(
                name: "provider_required_semantic_history",
                value: candidate.providerRequiredSemanticHistory
            ),
            .init(
                name: "resolved_attachments",
                value: .array(try sortedAttachments(candidate).map(attachmentDocument))
            ),
            .init(name: "schema_version", value: .string("1")),
            .init(
                name: "tool_results",
                value: .array(try candidate.toolResults.map(toolResultDocument))
            ),
        ])
    }

    private func sourceDocument(
        _ candidate: CloudGenerationTurnCandidate
    ) throws -> CanonicalJSONValue {
        try .object(entries: [
            .init(
                name: "resolved_attachments",
                value: .array(try sortedAttachments(candidate).map(attachmentDocument))
            ),
            .init(name: "schema_version", value: .string("1")),
            .init(name: "source_revision_document", value: candidate.sourceRevisionDocument),
        ])
    }

    private func sortedAttachments(
        _ candidate: CloudGenerationTurnCandidate
    ) -> [CloudResolvedAttachmentIdentity] {
        candidate.resolvedAttachments.sorted { lhs, rhs in
            lhs.attachmentID < rhs.attachmentID
        }
    }

    private func messageDocument(_ message: LLMInputMessage) throws -> CanonicalJSONValue {
        try .object(entries: [
            .init(
                name: "content",
                value: .array(try message.content.map(contentDocument))
            ),
            .init(name: "role", value: .string(message.role.rawValue)),
        ])
    }

    private func contentDocument(_ content: LLMInputContent) throws -> CanonicalJSONValue {
        switch content {
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
    }

    private func attachmentDocument(
        _ attachment: CloudResolvedAttachmentIdentity
    ) throws -> CanonicalJSONValue {
        try .object(entries: [
            .init(name: "attachment_id", value: .string(attachment.attachmentID)),
            .init(name: "byte_count", value: .string(String(attachment.byteCount))),
            .init(name: "content_digest", value: .string(attachment.contentDigest)),
            .init(name: "media_type", value: .string(attachment.mediaType)),
            .init(name: "revision", value: .string(String(attachment.revision))),
        ])
    }

    private func toolResultDocument(
        _ result: NormalizedToolResult
    ) throws -> CanonicalJSONValue {
        try .object(entries: [
            .init(name: "call_id", value: .string(result.callID)),
            .init(
                name: "data_classes",
                value: .array(result.dataClasses
                    .map(\.rawValue)
                    .sorted()
                    .map(CanonicalJSONValue.string))
            ),
            .init(name: "highest_sensitivity", value: .string(result.highestSensitivity.rawValue)),
            .init(name: "is_error", value: .bool(result.isError)),
            .init(name: "result", value: result.result),
            .init(name: "tool_name", value: .string(result.toolName)),
        ])
    }

    private func isLowercaseSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102)
        }
    }

    private func failure(_ code: String, _ message: String) -> CloudTurnValidationFailure {
        CloudTurnValidationFailure(code: code, message: message)
    }
}
