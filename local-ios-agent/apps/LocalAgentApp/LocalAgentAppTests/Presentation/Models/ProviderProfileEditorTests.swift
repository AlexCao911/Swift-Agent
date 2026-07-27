import Testing
@testable import LocalAgentApp

@Suite("Provider Profile editor")
@MainActor
struct ProviderProfileEditorTests {
    @Test
    func profileEditorNeverRehydratesAPIKeyText() async {
        let client = ModelCenterClientSpy(snapshot: .fixture)
        let viewModel = ProviderProfileEditorViewModel(client: client)

        await viewModel.load(profileID: "profile", revision: 1)

        #expect(viewModel.apiKey.isEmpty)
        #expect(viewModel.hasStoredCredential)
        #expect(viewModel.baseURL == "https://api.openai.com:443")
    }
}
