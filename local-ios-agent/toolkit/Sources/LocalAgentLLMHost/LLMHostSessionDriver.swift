import Foundation
import LocalAgentLLMContracts

package enum HostGenerationMode: Sendable {
    case start
    case resume
}

package struct HostGenerationTurn: Sendable {
    package let commandID: String
    package let generationTurnID: String
    package let payload: HostCommandPayload
    package let disclosure: GenerationDisclosure

    package init(
        commandID: String,
        generationTurnID: String,
        payload: HostCommandPayload,
        disclosure: GenerationDisclosure
    ) {
        self.commandID = commandID
        self.generationTurnID = generationTurnID
        self.payload = payload
        self.disclosure = disclosure
    }
}

package struct HostGenerationOperation: Sendable {
    package let opaqueOperationID: String
    package let events: LLMBackendEventStream

    package init(
        opaqueOperationID: String,
        events: LLMBackendEventStream
    ) {
        self.opaqueOperationID = opaqueOperationID
        self.events = events
    }
}

package struct AuthorizedHostGenerationLaunch: Sendable {
    package let run: @Sendable () async throws -> HostGenerationOperation

    package init(
        run: @escaping @Sendable () async throws -> HostGenerationOperation
    ) {
        self.run = run
    }
}

package protocol LLMHostSessionDriver: Sendable {
    func makeAuthorizedLaunch(
        for turn: HostGenerationTurn,
        mode: HostGenerationMode
    ) async throws -> AuthorizedHostGenerationLaunch

    func cancel() async throws
    func close() async throws
}

package struct DecodedHostGenerationTurn: Sendable {
    package let input: AgentLLMInput
    package let toolSchema: CanonicalJSONValue
    package let sourceRevisions: CanonicalJSONValue
    package let semanticHistory: CanonicalJSONValue
    package let semanticHistoryMessages: [LLMInputMessage]
    package let toolResults: [NormalizedToolResult]
}

package func decodeHostGenerationTurn(
    _ turn: HostGenerationTurn
) throws -> DecodedHostGenerationTurn {
    guard turn.payload.schemaVersion == "1",
          turn.disclosure.generationTurnID == turn.generationTurnID,
          turn.disclosure.sourceRevisionDigest
            == turn.payload.sourceRevisionsDigest
    else {
        throw LLMHostFailure(
            code: "generation.disclosure_mismatch",
            message: "the host command differs from its frozen disclosure"
        )
    }
    let toolSchema = try JSONDecoder().decode(
        CanonicalJSONValue.self,
        from: Data(turn.payload.toolSchemaJSON.utf8)
    )
    let messages = try turn.payload.messages.map(decodeMessage)
    let semanticHistoryMessages = try turn.payload.semanticHistory.map(
        decodeMessage
    )
    let history = try CanonicalJSONValue.array(
        turn.payload.semanticHistory.map(canonicalMessage)
    )
    let sources = try CanonicalJSONValue.object(entries: [
        .init(
            name: "sources",
            value: .array(try turn.payload.sourceRevisions.map { source in
                try .object(entries: [
                    .init(name: "digest", value: .string(source.digest)),
                    .init(name: "revision", value: .string(source.revision)),
                    .init(name: "source_id", value: .string(source.sourceID)),
                ])
            })
        ),
    ])
    let results = try turn.payload.toolResults.map { result in
        guard let sensitivity = DataSensitivity(
            rawValue: result.highestSensitivity
        ) else {
            throw semanticFailure("tool-result sensitivity is invalid")
        }
        return NormalizedToolResult(
            callID: result.callID,
            toolName: result.toolName,
            result: result.result,
            isError: result.isError,
            dataClasses: Set(try result.dataClasses.map { value in
                guard let dataClass = EgressDataClass(rawValue: value) else {
                    throw semanticFailure("tool-result data class is invalid")
                }
                return dataClass
            }),
            highestSensitivity: sensitivity
        )
    }
    return DecodedHostGenerationTurn(
        input: AgentLLMInput(
            inputID: turn.payload.modelInputID,
            messages: messages
        ),
        toolSchema: toolSchema,
        sourceRevisions: sources,
        semanticHistory: history,
        semanticHistoryMessages: semanticHistoryMessages,
        toolResults: results
    )
}

private func decodeMessage(
    _ message: HostSemanticMessage
) throws -> LLMInputMessage {
    let role: LLMInputRole
    switch message.role {
    case "system", "summary":
        role = .system
    case "user":
        role = .user
    case "assistant":
        role = .assistant
    case "tool":
        role = .tool
    default:
        throw semanticFailure("message role is invalid")
    }
    return LLMInputMessage(
        role: role,
        content: try message.content.map { content in
            switch content.kind {
            case .text:
                guard let text = content.text,
                      content.modality == nil,
                      content.attachmentID == nil,
                      content.mediaType == nil
                else {
                    throw semanticFailure("text content is malformed")
                }
                return .text(text)
            case .attachment:
                guard content.text == nil,
                      let modality = content.modality.flatMap(
                          LLMInputModality.init(rawValue:)
                      ),
                      let attachmentID = content.attachmentID,
                      let mediaType = content.mediaType,
                      !attachmentID.isEmpty,
                      !mediaType.isEmpty
                else {
                    throw semanticFailure("attachment content is malformed")
                }
                return .attachment(
                    modality: modality,
                    attachmentID: attachmentID,
                    mediaType: mediaType
                )
            }
        }
    )
}

private func canonicalMessage(
    _ message: HostSemanticMessage
) throws -> CanonicalJSONValue {
    try .object(entries: [
        .init(
            name: "content",
            value: .array(try message.content.map { content in
                var entries = [
                    CanonicalJSONObjectEntry(
                        name: "kind",
                        value: .string(content.kind.rawValue)
                    ),
                ]
                if let text = content.text {
                    entries.append(.init(name: "text", value: .string(text)))
                }
                if let modality = content.modality {
                    entries.append(.init(name: "modality", value: .string(modality)))
                }
                if let attachmentID = content.attachmentID {
                    entries.append(
                        .init(name: "attachment_id", value: .string(attachmentID))
                    )
                }
                if let mediaType = content.mediaType {
                    entries.append(
                        .init(name: "media_type", value: .string(mediaType))
                    )
                }
                return try .object(entries: entries)
            })
        ),
        .init(name: "role", value: .string(message.role)),
    ])
}

private func semanticFailure(_ message: String) -> LLMHostFailure {
    LLMHostFailure(code: "generation.semantic_request_invalid", message: message)
}
