package struct GLMAdapter: CloudProviderAdapter {
    package let presetID: ProviderPresetID = .glm
    package let adapterID = "glm.chat_completions"
    package let adapterVersion = "1"

    package init() {}

    package func makeDiscoveryRequest() throws -> CloudWireRequest {
        try ProviderProbeWireEncoder.modelDiscovery(encoderID: "openai_chat_completions")
    }

    package func makeAccountValidationRequest() throws -> CloudWireRequest {
        try ProviderProbeWireEncoder.accountValidation(encoderID: "openai_chat_completions")
    }

    package func makeModelValidationRequest(modelID: String) throws -> CloudWireRequest {
        try ProviderProbeWireEncoder.chatModelValidation(
            encoderID: "openai_chat_completions",
            modelID: modelID
        )
    }

    package func makeSession(
        _ context: CloudProviderSessionContext
    ) throws -> any CloudProviderSession {
        try OpenAIChatCompletionsSession(context: context, semantics: .glm)
    }
}
