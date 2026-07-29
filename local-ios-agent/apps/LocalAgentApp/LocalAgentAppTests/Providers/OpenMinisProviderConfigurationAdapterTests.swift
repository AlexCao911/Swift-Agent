import Foundation
import LocalAgentLLMCloud
import Testing
@testable import LocalAgentApp

@Suite("OpenMinis provider configuration adapter")
struct OpenMinisProviderConfigurationAdapterTests {
    @Test
    func mapsProductConfigurationOntoLocalAgentProfileDraft() throws {
        let configuration = OpenMinisProviderConfiguration(
            id: "provider-1",
            rawProviderType: "openAI",
            displayName: "Work OpenAI",
            credentialMode: .apiKey,
            customBaseURL: URL(string: "https://gateway.example")!,
            appendsV1: true
        )

        let draft = try OpenMinisProviderConfigurationAdapter.makeDraft(
            configuration,
            secret: SecretBytes(utf8: "secret")
        )

        #expect(draft.profileID == "provider-1")
        #expect(draft.presetID == .openAIChatCompletions)
        #expect(draft.displayName == "Work OpenAI")
        #expect(draft.baseURL.absoluteString == "https://gateway.example/v1")
        #expect(draft.initialSecret != nil)
    }

    @Test
    func unsupportedProviderFailsBeforeAnyRuntimeCanUseIt() {
        let configuration = OpenMinisProviderConfiguration(
            id: "future",
            rawProviderType: "futureProvider",
            displayName: "Future",
            credentialMode: .oauth,
            customBaseURL: nil,
            appendsV1: false
        )

        #expect(throws: OpenMinisProviderConfigurationError.self) {
            try OpenMinisProviderConfigurationAdapter.makeDraft(
                configuration,
                secret: nil
            )
        }
    }

    @Test
    func configurationEncodingNeverContainsCredentialBytes() throws {
        let configuration = OpenMinisProviderConfiguration(
            id: "provider-1",
            rawProviderType: "kimiCode",
            displayName: "Kimi",
            credentialMode: .oauth,
            customBaseURL: nil,
            appendsV1: true
        )

        let encoded = try JSONEncoder().encode(configuration)
        let text = String(decoding: encoded, as: UTF8.self)

        #expect(!text.localizedCaseInsensitiveContains("access_token"))
        #expect(!text.localizedCaseInsensitiveContains("api_key"))
        #expect(!text.localizedCaseInsensitiveContains("secret"))
    }

    @Test
    func antigravityRequiresAndPreservesItsDiscoveredProject() throws {
        let configuration = OpenMinisProviderConfiguration(
            id: "antigravity-1",
            rawProviderType: "antigravity",
            displayName: "Antigravity",
            credentialMode: .oauth,
            customBaseURL: nil,
            appendsV1: false,
            providerProjectID: "project-sentinel"
        )

        let draft = try OpenMinisProviderConfigurationAdapter.makeDraft(
            configuration,
            secret: SecretBytes(utf8: "oauth-token")
        )

        #expect(draft.presetID == .antigravity)
        #expect(draft.providerProjectID == "project-sentinel")

        #expect(throws: OpenMinisProviderConfigurationError.self) {
            try OpenMinisProviderConfigurationAdapter.makeDraft(
                OpenMinisProviderConfiguration(
                    id: "antigravity-missing-project",
                    rawProviderType: "antigravity",
                    displayName: "Antigravity",
                    credentialMode: .oauth,
                    customBaseURL: nil,
                    appendsV1: false
                ),
                secret: SecretBytes(utf8: "oauth-token")
            )
        }
    }
}
