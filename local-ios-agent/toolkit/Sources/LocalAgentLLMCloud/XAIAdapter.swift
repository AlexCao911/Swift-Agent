package struct XAIAdapter: CloudProviderAdapter {
    package let presetID: ProviderPresetID = .xAI
    package let adapterID = "xai.responses"
    package let adapterVersion = "1"

    package init() {}

    package func makeDiscoveryRequest() throws -> CloudWireRequest {
        try ProviderProbeWireEncoder.modelDiscovery(encoderID: "openai_responses")
    }

    package func makeAccountValidationRequest() throws -> CloudWireRequest {
        try ProviderProbeWireEncoder.accountValidation(encoderID: "openai_responses")
    }

    package func makeModelValidationRequest(modelID: String) throws -> CloudWireRequest {
        try ProviderProbeWireEncoder.responsesModelValidation(
            encoderID: "openai_responses",
            modelID: modelID
        )
    }

    package func makeSession(
        _ context: CloudProviderSessionContext
    ) throws -> any CloudProviderSession {
        try OpenAIResponsesSession(context: context, semantics: .xAI)
    }
}
