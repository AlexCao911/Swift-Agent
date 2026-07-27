import Foundation
import LocalAgentLLMContracts

package struct LocalToolCallDecodingResult: Equatable, Sendable {
    package let visiblePreamble: String
    package let calls: [NormalizedToolCall]
    package let completion: LLMBackendCompletion
}

package enum LocalToolCallCodec {
    private static let supportedCodecID = "json_tool_calls_v1"
    private static let opening = "<tool_calls>"
    private static let closing = "</tool_calls>"

    package static func decode(codecID: String, rawText: String) throws -> LocalToolCallDecodingResult {
        guard codecID == supportedCodecID else {
            throw failure("local_engine.tool_codec_unsupported", "unsupported local tool-call codec")
        }
        guard let openingRange = rawText.range(of: opening),
              let closingRange = rawText.range(of: closing, range: openingRange.upperBound..<rawText.endIndex),
              closingRange.upperBound == rawText.endIndex,
              rawText.range(of: opening, range: openingRange.upperBound..<rawText.endIndex) == nil,
              rawText.range(of: closing, range: closingRange.upperBound..<rawText.endIndex) == nil
        else {
            throw failure("local_engine.tool_codec_malformed", "tool-call output is not exactly framed")
        }

        let payload = Data(rawText[openingRange.upperBound..<closingRange.lowerBound].utf8)
        let envelope: Envelope
        do {
            envelope = try JSONDecoder().decode(Envelope.self, from: payload)
        } catch {
            throw failure("local_engine.tool_codec_malformed", "tool-call output is not valid JSON")
        }
        guard !envelope.calls.isEmpty else {
            throw failure("local_engine.tool_codec_malformed", "tool-call batch must not be empty")
        }

        var seen = Set<String>()
        let calls = try envelope.calls.map { call -> NormalizedToolCall in
            guard !call.id.isEmpty, !call.name.isEmpty, seen.insert(call.id).inserted else {
                throw failure("local_engine.tool_codec_malformed", "tool-call IDs and names must be unique and non-empty")
            }
            let arguments = try String(
                decoding: CanonicalDigestV1.canonicalize(call.arguments),
                as: UTF8.self
            )
            return NormalizedToolCall(callID: call.id, name: call.name, argumentsJSON: arguments)
        }
        let orderedCallIDs = calls.map(\.callID)
        return LocalToolCallDecodingResult(
            visiblePreamble: String(rawText[..<openingRange.lowerBound]),
            calls: calls,
            completion: LLMBackendCompletion(
                outcome: .toolCallsReady,
                orderedCallIDs: orderedCallIDs,
                finishReason: .toolCalls
            )
        )
    }

    private struct Envelope: Decodable {
        let calls: [Call]
    }

    private struct Call: Decodable {
        let id: String
        let name: String
        let arguments: CanonicalJSONValue
    }

    private static func failure(_ code: String, _ message: String) -> LLMFailure {
        LLMFailure(code: code, message: message, retryable: false)
    }
}

package func localContinuationInput(
    _ input: AgentLLMInput,
    pendingToolCalls: [NormalizedToolCall]
) throws -> AgentLLMInput {
    guard !pendingToolCalls.isEmpty else { return input }
    let calls = try pendingToolCalls.map { call in
        let arguments = try JSONDecoder().decode(
            CanonicalJSONValue.self,
            from: Data(call.argumentsJSON.utf8)
        )
        return try CanonicalJSONValue.object(entries: [
            .init(name: "id", value: .string(call.callID)),
            .init(name: "name", value: .string(call.name)),
            .init(name: "arguments", value: arguments),
        ])
    }
    let document = try CanonicalJSONValue.object(entries: [
        .init(name: "calls", value: .array(calls)),
    ])
    let encoded = String(
        decoding: try CanonicalDigestV1.canonicalize(document),
        as: UTF8.self
    )
    var messages = input.messages
    let insertion = messages.firstIndex { $0.role == .tool } ?? messages.endIndex
    messages.insert(
        LLMInputMessage(
            role: .assistant,
            content: [.text("<tool_calls>\(encoded)</tool_calls>")]
        ),
        at: insertion
    )
    return AgentLLMInput(inputID: input.inputID, messages: messages)
}
