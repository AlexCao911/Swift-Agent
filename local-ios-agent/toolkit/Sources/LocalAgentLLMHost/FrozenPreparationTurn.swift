import Foundation
import LocalAgentBridge
import LocalAgentLLMCloud
import LocalAgentLLMContracts
import LocalAgentLLMCore

package enum FrozenPreparationTurn {
    package static func cloudRequest(
        preview: RunPreparationPreviewDTO,
        resolvedParameters: GenerationConfiguration
    ) throws -> CloudGenerationTurnRequest {
        let frozen = preview.frozenInitialTurn
        let payload = frozen.payload
        let disclosure = frozen.disclosure
        guard payload.schemaVersion == "1",
              payload.modelInputID == preview.binding.modelInputId,
              payload.toolSchemaDigest == preview.binding.toolSchemaDigest,
              payload.sourceRevisionsDigest == preview.binding.sourceRevisionsDigest,
              disclosure.contentDigest == preview.binding.modelInputDigest,
              disclosure.sourceRevisionDigest == preview.binding.sourceRevisionsDigest,
              try disclosure.computedDigest().hex == preview.binding.initialDisclosureDigest,
              disclosure.safeDisplaySummary.triggeringToolDisplayKeys.isEmpty
        else {
            throw invalid()
        }

        _ = try payload.computedDigest()
        let toolSchema = try decodeCanonicalJSON(payload.toolSchemaJSON)
        guard try CanonicalDigestV1.digest(
            domain: "tool-schema:v1",
            document: toolSchema
        ).hex == preview.binding.toolSchemaDigest else {
            throw invalid()
        }

        let input = AgentLLMInput(
            inputID: payload.modelInputID,
            messages: try payload.messages.map(inputMessage)
        )
        guard payload.attachments.isEmpty,
              !input.messages.contains(where: { message in
                  message.content.contains(where: {
                      if case .attachment = $0 { true } else { false }
                  })
              })
        else {
            throw LLMHostFailure(
                code: "capability.cloud_attachment_path_unavailable",
                message: "cloud attachment encoding is unavailable"
            )
        }

        let sourceRevisions = CanonicalJSONValue.array(
            try payload.sourceRevisions.map(sourceRevision)
        )
        let semanticHistory = CanonicalJSONValue.array(
            try payload.semanticHistory.map(semanticMessage)
        )
        let toolResults = try payload.toolResults.map(normalizedToolResult)
        let request = CloudGenerationTurnRequest(
            input: input,
            canonicalToolSchema: toolSchema,
            sourceRevisionDocument: sourceRevisions,
            toolResults: toolResults,
            providerRequiredSemanticHistory: semanticHistory,
            disclosure: disclosure,
            resolvedParameters: resolvedParameters
        )
        do {
            _ = try CloudSemanticTurnValidator().validate(
                CloudGenerationTurnCandidate(
                    input: request.input,
                    canonicalToolSchema: request.canonicalToolSchema,
                    sourceRevisionDocument: request.sourceRevisionDocument,
                    resolvedAttachments: [],
                    toolResults: request.toolResults,
                    providerRequiredSemanticHistory: request.providerRequiredSemanticHistory,
                    disclosure: request.disclosure,
                    resolvedParameters: request.resolvedParameters
                )
            )
        } catch {
            throw invalid()
        }
        return request
    }

    private static func inputMessage(
        _ message: HostSemanticMessage
    ) throws -> LLMInputMessage {
        let role: LLMInputRole
        switch message.role {
        case "system", "summary": role = .system
        case "user": role = .user
        case "assistant": role = .assistant
        case "tool": role = .tool
        default: throw invalid()
        }
        return LLMInputMessage(
            role: role,
            content: try message.content.map(inputContent)
        )
    }

    private static func inputContent(
        _ content: HostSemanticContent
    ) throws -> LLMInputContent {
        switch content.kind {
        case .text:
            guard let text = content.text,
                  content.modality == nil,
                  content.attachmentID == nil,
                  content.mediaType == nil
            else {
                throw invalid()
            }
            return .text(text)
        case .attachment:
            guard content.text == nil,
                  let modality = content.modality.flatMap(LLMInputModality.init(rawValue:)),
                  let attachmentID = content.attachmentID,
                  !attachmentID.isEmpty,
                  let mediaType = content.mediaType,
                  !mediaType.isEmpty
            else {
                throw invalid()
            }
            return .attachment(
                modality: modality,
                attachmentID: attachmentID,
                mediaType: mediaType
            )
        }
    }

    private static func sourceRevision(
        _ revision: HostSourceRevision
    ) throws -> CanonicalJSONValue {
        try .object(entries: [
            .init(name: "digest", value: .string(revision.digest)),
            .init(name: "revision", value: .string(revision.revision)),
            .init(name: "source_id", value: .string(revision.sourceID)),
        ])
    }

    private static func semanticMessage(
        _ message: HostSemanticMessage
    ) throws -> CanonicalJSONValue {
        try .object(entries: [
            .init(
                name: "content",
                value: .array(try message.content.map(semanticContent))
            ),
            .init(name: "role", value: .string(message.role)),
        ])
    }

    private static func semanticContent(
        _ content: HostSemanticContent
    ) throws -> CanonicalJSONValue {
        var entries = [
            CanonicalJSONObjectEntry(name: "kind", value: .string(content.kind.rawValue)),
        ]
        if let text = content.text {
            entries.append(.init(name: "text", value: .string(text)))
        }
        if let modality = content.modality {
            entries.append(.init(name: "modality", value: .string(modality)))
        }
        if let attachmentID = content.attachmentID {
            entries.append(.init(name: "attachment_id", value: .string(attachmentID)))
        }
        if let mediaType = content.mediaType {
            entries.append(.init(name: "media_type", value: .string(mediaType)))
        }
        return try .object(entries: entries)
    }

    private static func normalizedToolResult(
        _ result: HostToolResult
    ) throws -> NormalizedToolResult {
        guard let sensitivity = DataSensitivity(rawValue: result.highestSensitivity) else {
            throw invalid()
        }
        let classes = try Set(result.dataClasses.map { value in
            guard let dataClass = EgressDataClass(rawValue: value) else {
                throw invalid()
            }
            return dataClass
        })
        return NormalizedToolResult(
            callID: result.callID,
            toolName: result.toolName,
            result: result.result,
            isError: result.isError,
            dataClasses: classes,
            highestSensitivity: sensitivity
        )
    }

    private static func decodeCanonicalJSON(_ source: String) throws -> CanonicalJSONValue {
        do {
            return try JSONDecoder().decode(
                CanonicalJSONValue.self,
                from: Data(source.utf8)
            )
        } catch {
            throw invalid()
        }
    }

    private static func invalid() -> LLMHostFailure {
        LLMHostFailure(
            code: "llm.host.preparation_binding_mismatch",
            message: "cloud reservation input differs from the Rust preview"
        )
    }
}
