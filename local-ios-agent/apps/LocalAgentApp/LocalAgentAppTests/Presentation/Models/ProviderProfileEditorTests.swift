import Foundation
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

    @Test
    func oauthLoginIsPendingUntilSecureProfilePublicationSucceeds() async {
        let client = ModelCenterClientSpy(snapshot: .fixture)
        let viewModel = ProviderProfileEditorViewModel(client: client)
        viewModel.credentialMode = .oauth

        await viewModel.loginWithOAuth()

        #expect(viewModel.hasPendingOAuthCredential)
        #expect(!viewModel.hasStoredCredential)

        await viewModel.save()

        #expect(!viewModel.hasPendingOAuthCredential)
        #expect(viewModel.hasStoredCredential)
    }

    @Test
    func oauthLoopbackServerReceivesTheExactCallbackAndStops() async throws {
        let server = OAuthCallbackServer(
            port: 0,
            callbackPath: "/auth/callback"
        )
        try server.start()
        let port = try #require(server.boundPort)
        defer { server.stop() }

        let callback = Task {
            try await server.waitForCallback(timeout: 2)
        }
        let url = try #require(URL(
            string: "http://127.0.0.1:\(port)/auth/callback?code=one-time-code&state=expected"
        ))
        let (_, response) = try await URLSession.shared.data(from: url)
        let result = try await callback.value

        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(result.code == "one-time-code")
        #expect(result.state == "expected")
        #expect(server.boundPort == nil)
    }

    @Test
    func oauthLoopbackBuffersACallbackThatArrivesBeforeWaiting() async throws {
        let server = OAuthCallbackServer(port: 0, callbackPath: "/auth/callback")
        try server.start()
        defer { server.stop() }
        let port = try #require(server.boundPort)
        let url = try #require(URL(
            string: "http://127.0.0.1:\(port)/auth/callback?code=one-time-code&state=expected"
        ))

        let (_, response) = try await URLSession.shared.data(from: url)
        let result = try await server.waitForCallback(timeout: 2)

        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(result == OAuthCallbackResult(code: "one-time-code", state: "expected"))
    }

    @Test
    func oauthLoopbackRejectsDuplicateQueryKeysWithoutTrapping() async throws {
        let server = OAuthCallbackServer(port: 0, callbackPath: "/auth/callback")
        try server.start()
        defer { server.stop() }
        let port = try #require(server.boundPort)
        let waiter = Task { try await server.waitForCallback(timeout: 2) }
        let url = try #require(URL(
            string: "http://127.0.0.1:\(port)/auth/callback?code=one&code=two&state=expected"
        ))

        let (_, response) = try await URLSession.shared.data(from: url)
        do {
            _ = try await waiter.value
            Issue.record("duplicate OAuth query keys completed the login")
        } catch {}

        #expect((response as? HTTPURLResponse)?.statusCode == 400)
        #expect(server.boundPort == nil)
    }

    @Test
    func cancellingOAuthWaitReleasesThePortForARetry() async throws {
        let server = OAuthCallbackServer(port: 0, callbackPath: "/auth/callback")
        try server.start()
        let port = try #require(server.boundPort)
        let waiter = Task { try await server.waitForCallback(timeout: 60) }

        waiter.cancel()
        await #expect(throws: CancellationError.self) {
            _ = try await waiter.value
        }
        #expect(server.boundPort == nil)

        let retry = OAuthCallbackServer(port: port, callbackPath: "/auth/callback")
        try retry.start()
        retry.stop()
    }

    @Test
    func xAILoopbackPreflightAcceptsOnlyTheTrustedOrigin() async throws {
        let server = OAuthCallbackServer(
            port: 0,
            callbackPath: "/auth/callback",
            trustedOrigin: "https://accounts.x.ai"
        )
        try server.start()
        defer { server.stop() }
        let port = try #require(server.boundPort)
        let url = try #require(URL(
            string: "http://127.0.0.1:\(port)/auth/callback"
        ))
        var request = URLRequest(url: url)
        request.httpMethod = "OPTIONS"
        request.setValue("https://accounts.x.ai", forHTTPHeaderField: "Origin")

        let (_, response) = try await URLSession.shared.data(for: request)

        let http = try #require(response as? HTTPURLResponse)
        #expect(http.statusCode == 204)
        #expect(http.value(forHTTPHeaderField: "Access-Control-Allow-Origin") == "https://accounts.x.ai")
    }
}
