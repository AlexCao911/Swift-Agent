import Foundation
import LocalAgentLLMContracts
import Testing
@testable import LocalAgentLLMLocal

@Suite("C++ inference client payloads")
struct CppInferenceClientTests {
    @Test
    func modelPayloadUsesOnlyManifestResolvedLoadInputs() throws {
        let request = CppModelLoadRequest(
            engineID: "llama_cpp",
            modelID: "gemma-3",
            modelFormat: "gguf",
            artifactPathsByRole: [
                "weights": "/private/models/model.gguf",
                "multimodal_projection": "/private/models/mmproj.gguf",
            ],
            contextTokens: 32_768,
            manifestLoadOptions: [
                "n_threads": .number(4),
                "n_gpu_layers": .number(20),
                "mmap": .bool(true),
            ],
            template: LocalChatTemplateSelector(source: .gguf, templateID: "gemma"),
            toolCallCodecID: "llama_cpp_native_tools_v1"
        )

        let encoded = try CppInferenceRequestEncoder.modelJSON(request)
        let root = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(root["engine"] as? String == "llama_cpp")
        #expect(root["model_path"] as? String == "/private/models/model.gguf")
        #expect(root["mmproj_path"] as? String == "/private/models/mmproj.gguf")
        #expect(root["context_tokens"] as? Int == 32_768)
        #expect((root["runtime"] as? [String: Any])?["n_threads"] as? Int == 4)
        #expect((root["manifest_options"] as? [String: Any])?["mmap"] as? Bool == true)
        #expect(root["tool_call_codec_id"] as? String == "llama_cpp_native_tools_v1")
    }

    @Test
    func generationPayloadCarriesTypedMessagesTemplateToolsAndConcreteOptions() throws {
        let request = CppGenerationRequest(
            input: AgentLLMInput(
                inputID: "input-1",
                messages: [
                    LLMInputMessage(role: .system, content: [.text("Be concise")]),
                    LLMInputMessage(
                        role: .user,
                        content: [
                            .text("describe"),
                            .attachment(modality: .image, attachmentID: "image-1", mediaType: "image/rgb8"),
                        ]
                    ),
                ]
            ),
            attachments: [
                LocalResolvedAttachment(
                    attachmentID: "image-1",
                    rgb8: Data([255, 0, 0]),
                    width: 1,
                    height: 1
                ),
            ],
            canonicalToolSchema: try .object(entries: [
                .init(name: "tools", value: .array([
                    try .object(entries: [
                        .init(name: "name", value: .string("search")),
                        .init(name: "input_schema", value: try .object(entries: [
                            .init(name: "type", value: .string("object")),
                        ])),
                    ]),
                ])),
            ]),
            template: LocalChatTemplateSelector(source: .gguf, templateID: "gemma"),
            toolCallCodecID: "llama_cpp_native_tools_v1",
            continuationToolCalls: [
                NormalizedToolCall(
                    callID: "call-1",
                    name: "search",
                    argumentsJSON: #"{"q":"swift"}"#
                ),
            ],
            concreteOptions: ["temperature": .number(0.2), "max_new_tokens": .number(64)]
        )

        let encoded = try CppInferenceRequestEncoder.generationJSON(request)
        let root = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(root["schema_version"] as? String == "2")
        let messages = try #require(root["messages"] as? [[String: Any]])
        #expect(messages.count == 3)
        #expect(messages[2]["role"] as? String == "assistant")
        let calls = try #require(messages[2]["tool_calls"] as? [[String: Any]])
        #expect(calls.first?["id"] as? String == "call-1")
        #expect((calls.first?["function"] as? [String: Any])?["name"] as? String == "search")
        #expect((root["images"] as? [[String: Any]])?.first?["format"] as? String == "rgb8")
        #expect((root["template"] as? [String: Any])?["id"] as? String == "gemma")
        #expect(root["tool_call_codec_id"] as? String == "llama_cpp_native_tools_v1")
        #expect((root["sampling"] as? [String: Any])?["max_new_tokens"] as? Int == 64)
    }

    @Test
    func attachmentReferencesMustMatchExactBuffers() {
        let request = CppGenerationRequest(
            input: AgentLLMInput(
                inputID: "input-2",
                messages: [
                    LLMInputMessage(
                        role: .user,
                        content: [.attachment(modality: .image, attachmentID: "missing", mediaType: "image/rgb8")]
                    ),
                ]
            ),
            attachments: [],
            canonicalToolSchema: nil,
            template: LocalChatTemplateSelector(source: .gguf, templateID: "gemma"),
            toolCallCodecID: nil,
            concreteOptions: [:]
        )

        #expect(throws: LLMFailure.self) {
            try CppInferenceRequestEncoder.generationJSON(request)
        }
    }
}
