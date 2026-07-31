import Foundation
import Testing
@testable import LocalAgentLLMCloud

@Suite("OAuth HTTP client")
struct OAuthHTTPClientTests {
    @Test
    func shippedProfilesDescribeEverySupportedOAuthProtocol() throws {
        let profiles = Dictionary(
            uniqueKeysWithValues: ProviderOAuthProfile.shipped.map {
                ($0.presetID, $0)
            }
        )

        #expect(profiles[.kimiCode]?.flow == .deviceCode)
        #expect(
            profiles[.kimiCode]?.tokenEndpoint.baseURL.host
                == "auth.kimi.com"
        )
        #expect(profiles[.openAI]?.flow == .authorizationCodePKCE)
        #expect(profiles[.openAI]?.tokenBodyEncoding == .json)
        #expect(
            profiles[.openAI]?.authorizationURL?.host == "auth.openai.com"
        )
        #expect(
            profiles[.anthropic]?.tokenBodyEncoding == .json
        )
        #expect(
            profiles[.gemini]?.tokenEndpoint.baseURL.host
                == "oauth2.googleapis.com"
        )
        #expect(
            profiles[.antigravity]?.tokenEndpoint.baseURL.host
                == "oauth2.googleapis.com"
        )
        #expect(
            profiles[.xAI]?.discoveryEndpoint?.baseURL.absoluteString
                == "https://auth.x.ai"
        )
        #expect(Set(profiles.keys) == [
            .openAI,
            .anthropic,
            .gemini,
            .xAI,
            .kimiCode,
            .antigravity,
        ])
    }

    @Test
    func anthropicExchangeIncludesTheVerifiedStateInItsJSONBody() async throws {
        let profile = try #require(
            ProviderOAuthProfile.shipped.first { $0.presetID == .anthropic }
        )
        let transport = SequencedOAuthTransport(responses: [
            OAuthHTTPResponse(
                statusCode: 200,
                headers: [:],
                body: Data(
                    #"{"access_token":"claude-access","refresh_token":"claude-refresh","expires_in":3600}"#
                        .utf8
                )
            ),
        ])
        let client = OAuthHTTPClient(transport: transport)
        let preparation = try await client.prepareAuthorization(
            profile: profile,
            state: "verified-state",
            codeChallenge: "pkce-challenge",
            nonce: nil
        )

        let credential = try await client.exchangeAuthorizationCode(
            preparation: preparation,
            code: "authorization-code",
            codeVerifier: "pkce-verifier"
        )

        #expect(credential.accessToken == "claude-access")
        let request = try #require(await transport.requests.first)
        #expect(request.path == "/v1/oauth/token")
        #expect(request.headers["content-type"] == "application/json")
        let json = try #require(
            try JSONSerialization.jsonObject(with: request.body ?? Data())
                as? [String: String]
        )
        #expect(json["code"] == "authorization-code")
        #expect(json["code_verifier"] == "pkce-verifier")
        #expect(json["grant_type"] == "authorization_code")
        #expect(json["state"] == "verified-state")
    }

    @Test
    func xAIDiscoversTrustedEndpointsAndUsesNoncePlanReferrerAndChallenge() async throws {
        let profile = try #require(
            ProviderOAuthProfile.shipped.first { $0.presetID == .xAI }
        )
        let transport = SequencedOAuthTransport(responses: [
            OAuthHTTPResponse(
                statusCode: 200,
                headers: [:],
                body: Data(
                    #"""
                    {
                      "authorization_endpoint": "https://auth.x.ai/oauth/authorize",
                      "token_endpoint": "https://auth.x.ai/oauth/token"
                    }
                    """#.utf8
                )
            ),
            OAuthHTTPResponse(
                statusCode: 200,
                headers: [:],
                body: Data(
                    #"{"access_token":"xai-access","refresh_token":"xai-refresh","expires_in":3600}"#
                        .utf8
                )
            ),
        ])
        let client = OAuthHTTPClient(transport: transport)

        let preparation = try await client.prepareAuthorization(
            profile: profile,
            state: "xai-state",
            codeChallenge: "xai-challenge",
            nonce: "xai-nonce"
        )
        let authorizationItems = try #require(
            URLComponents(
                url: preparation.authorizationURL,
                resolvingAgainstBaseURL: false
            )?.queryItems
        )
        let query = Dictionary(
            uniqueKeysWithValues: authorizationItems.map { ($0.name, $0.value) }
        )
        #expect(query["nonce"] == "xai-nonce")
        #expect(query["plan"] == "generic")
        #expect(query["referrer"] == "minis")
        #expect(query["code_challenge"] == "xai-challenge")

        _ = try await client.exchangeAuthorizationCode(
            preparation: preparation,
            code: "xai-code",
            codeVerifier: "xai-verifier"
        )

        let requests = await transport.requests
        #expect(requests.map(\.method) == ["GET", "POST"])
        #expect(requests.map(\.path) == [
            "/.well-known/openid-configuration",
            "/oauth/token",
        ])
        let tokenBody = String(
            decoding: try #require(requests.last?.body),
            as: UTF8.self
        )
        #expect(tokenBody.contains("code_challenge=xai-challenge"))
        #expect(tokenBody.contains("code_challenge_method=S256"))
    }

    @Test
    func xAIDiscoveryRejectsSubstitutedEndpointsBeforeAuthorization() async throws {
        let profile = try #require(
            ProviderOAuthProfile.shipped.first { $0.presetID == .xAI }
        )
        let transport = SequencedOAuthTransport(responses: [
            OAuthHTTPResponse(
                statusCode: 200,
                headers: [:],
                body: Data(
                    #"""
                    {
                      "authorization_endpoint": "https://attacker.example/authorize",
                      "token_endpoint": "https://attacker.example/token"
                    }
                    """#.utf8
                )
            ),
        ])
        let client = OAuthHTTPClient(transport: transport)

        await #expect(throws: OAuthHTTPFailure.self) {
            _ = try await client.prepareAuthorization(
                profile: profile,
                state: "state",
                codeChallenge: "challenge",
                nonce: "nonce"
            )
        }
        #expect((await transport.requests).count == 1)
    }

    @Test
    func openAICodexUsesJSONAndPreservesIDTokenAccountAndPlan() async throws {
        let profile = try #require(
            ProviderOAuthProfile.shipped.first { $0.presetID == .openAI }
        )
        let idToken =
            "e30.eyJjaGF0Z3B0X2FjY291bnRfaWQiOiJhY2NvdW50LTEiLCJjaGF0Z3B0X3BsYW5fdHlwZSI6InBsdXMifQ.sig"
        let response = try JSONSerialization.data(withJSONObject: [
            "access_token": "codex-access",
            "refresh_token": "codex-refresh",
            "id_token": idToken,
            "expires_in": 3_600,
        ])
        let transport = SequencedOAuthTransport(responses: [
            OAuthHTTPResponse(statusCode: 200, headers: [:], body: response),
        ])
        let client = OAuthHTTPClient(transport: transport)
        let preparation = try await client.prepareAuthorization(
            profile: profile,
            state: "openai-state",
            codeChallenge: "openai-challenge",
            nonce: nil
        )

        let credential = try await client.exchangeAuthorizationCode(
            preparation: preparation,
            code: "openai-code",
            codeVerifier: "openai-verifier"
        )

        #expect(credential.idToken == idToken)
        #expect(credential.accountID == "account-1")
        #expect(credential.planType == "plus")
        let request = try #require(await transport.requests.first)
        #expect(request.headers["content-type"] == "application/json")
        let body = try #require(
            try JSONSerialization.jsonObject(with: request.body ?? Data())
                as? [String: String]
        )
        #expect(body == [
            "client_id": profile.clientID,
            "code": "openai-code",
            "code_verifier": "openai-verifier",
            "grant_type": "authorization_code",
            "redirect_uri": "http://localhost:1455/auth/callback",
        ])
    }

    @Test(arguments: [ProviderPresetID.gemini, .antigravity])
    func googleFlowsUseExactFormEncodedAuthorizationCodeShape(
        _ presetID: ProviderPresetID
    ) async throws {
        let profile = try #require(
            ProviderOAuthProfile.shipped.first { $0.presetID == presetID }
        )
        let transport = SequencedOAuthTransport(responses: [
            OAuthHTTPResponse(
                statusCode: 200,
                headers: [:],
                body: Data(#"{"access_token":"google-access"}"#.utf8)
            ),
        ])
        let client = OAuthHTTPClient(transport: transport)
        let preparation = try await client.prepareAuthorization(
            profile: profile,
            state: "google-state",
            codeChallenge: "google-challenge",
            nonce: nil
        )

        _ = try await client.exchangeAuthorizationCode(
            preparation: preparation,
            code: "google-code",
            codeVerifier: "google-verifier"
        )

        let request = try #require(await transport.requests.first)
        #expect(
            request.headers["content-type"]
                == "application/x-www-form-urlencoded"
        )
        let body = String(
            decoding: try #require(request.body),
            as: UTF8.self
        )
        #expect(body.contains("client_id="))
        #expect(body.contains("code=google-code"))
        #expect(body.contains("code_verifier=google-verifier"))
        #expect(!body.contains("state="))
    }

    @Test
    func deviceAuthorizationAndTokenRefreshProduceExecutableOAuthCredential() async throws {
        let profile = try OAuthEndpointProfile(
            id: "kimi",
            baseURL: URL(string: "https://auth.kimi.com")!,
            expectedOrigin: EgressOrigin(
                scheme: "https",
                host: "auth.kimi.com",
                port: 443
            ),
            allowedPaths: [
                "/api/oauth/device_authorization",
                "/api/oauth/token",
            ]
        )
        let transport = SequencedOAuthTransport(responses: [
            OAuthHTTPResponse(
                statusCode: 200,
                headers: [:],
                body: Data(
                    #"""
                    {
                      "device_code": "device-code",
                      "user_code": "ABCD-EFGH",
                      "verification_uri": "https://auth.kimi.com/activate",
                      "expires_in": 900,
                      "interval": 5
                    }
                    """#.utf8
                )
            ),
            OAuthHTTPResponse(
                statusCode: 200,
                headers: [:],
                body: Data(
                    #"""
                    {
                      "access_token": "access-one",
                      "refresh_token": "refresh-one",
                      "expires_in": 3600
                    }
                    """#.utf8
                )
            ),
            OAuthHTTPResponse(
                statusCode: 200,
                headers: [:],
                body: Data(
                    #"""
                    {
                      "access_token": "access-two",
                      "expires_in": 7200
                    }
                    """#.utf8
                )
            ),
        ])
        let client = OAuthHTTPClient(transport: transport)

        let authorization = try await client.requestDeviceAuthorization(
            profile: profile,
            path: "/api/oauth/device_authorization",
            clientID: "client-id"
        )
        let first = try await client.exchangeDeviceCode(
            profile: profile,
            path: "/api/oauth/token",
            clientID: "client-id",
            deviceCode: authorization.deviceCode
        )
        let refreshed = try await client.refresh(
            first,
            profile: profile,
            path: "/api/oauth/token",
            clientID: "client-id"
        )

        #expect(authorization.userCode == "ABCD-EFGH")
        #expect(authorization.verificationURL.absoluteString == "https://auth.kimi.com/activate")
        #expect(refreshed.accessToken == "access-two")
        #expect(refreshed.refreshToken == "refresh-one")
        #expect(try refreshed.executableAccessToken(at: Date()) == "access-two")
        let requests = await transport.requests
        #expect(requests.map(\.path) == [
            "/api/oauth/device_authorization",
            "/api/oauth/token",
            "/api/oauth/token",
        ])
        #expect(requests.allSatisfy {
            $0.headers["content-type"]
                == "application/x-www-form-urlencoded"
        })
    }

    @Test
    func sendsOnlyAnAllowlistedEndpointThroughCloudTransport() async throws {
        let profile = try OAuthEndpointProfile(
            id: "kimi",
            baseURL: URL(string: "https://auth.kimi.com")!,
            expectedOrigin: EgressOrigin(
                scheme: "https",
                host: "auth.kimi.com",
                port: 443
            ),
            allowedPaths: ["/oauth/device/code", "/oauth/token"]
        )
        let transport = OAuthTransportSpy(
            response: OAuthHTTPResponse(
                statusCode: 200,
                headers: ["content-type": "application/json"],
                body: Data(#"{"access_token":"secret"}"#.utf8)
            )
        )
        let client = OAuthHTTPClient(transport: transport)
        let request = try OAuthHTTPRequest(
            profile: profile,
            method: "POST",
            path: "/oauth/token",
            headers: [
                "content-type": "application/x-www-form-urlencoded",
            ],
            body: Data("grant_type=refresh_token".utf8)
        )

        let response = try await client.send(request)

        #expect(response.statusCode == 200)
        #expect(await transport.requests == [request])
    }

    @Test
    func rejectsUnlistedPathsCredentialsInURLAndAuthenticationHeaders() throws {
        let profile = try OAuthEndpointProfile(
            id: "provider",
            baseURL: URL(string: "https://auth.example.com")!,
            expectedOrigin: EgressOrigin(
                scheme: "https",
                host: "auth.example.com",
                port: 443
            ),
            allowedPaths: ["/token"]
        )

        #expect(throws: OAuthHTTPFailure.self) {
            try OAuthHTTPRequest(
                profile: profile,
                method: "POST",
                path: "/not-allowed",
                headers: [:],
                body: nil
            )
        }
        #expect(throws: OAuthHTTPFailure.self) {
            try OAuthHTTPRequest(
                profile: profile,
                method: "POST",
                path: "/token",
                headers: ["Authorization": "Bearer secret"],
                body: nil
            )
        }
        #expect(throws: OAuthHTTPFailure.self) {
            _ = try OAuthEndpointProfile(
                id: "bad",
                baseURL: URL(string: "https://user:pass@auth.example.com")!,
                expectedOrigin: EgressOrigin(
                    scheme: "https",
                    host: "auth.example.com",
                    port: 443
                ),
                allowedPaths: ["/token"]
            )
        }
    }

    @Test
    func cancellationNeverBecomesAnOAuthRetry() async {
        let client = OAuthHTTPClient(transport: CancellingOAuthTransport())
        let profile = try! OAuthEndpointProfile(
            id: "cancel",
            baseURL: URL(string: "https://auth.example.com")!,
            expectedOrigin: EgressOrigin(
                scheme: "https",
                host: "auth.example.com",
                port: 443
            ),
            allowedPaths: ["/token"]
        )
        let request = try! OAuthHTTPRequest(
            profile: profile,
            method: "POST",
            path: "/token",
            headers: [:],
            body: nil
        )

        await #expect(throws: CancellationError.self) {
            try await client.send(request)
        }
    }
}

private actor SequencedOAuthTransport: CloudHTTPTransport {
    private(set) var requests: [OAuthHTTPRequest] = []
    private var responses: [OAuthHTTPResponse]

    init(responses: [OAuthHTTPResponse]) {
        self.responses = responses
    }

    func stream(
        _ request: AuthorizedCloudHTTPRequest
    ) async throws -> AsyncThrowingStream<SSEEvent, Error> {
        throw OAuthHTTPFailure(code: "unexpected_stream")
    }

    func json(_ request: AuthorizedCloudHTTPRequest) async throws -> Data {
        throw OAuthHTTPFailure(code: "unexpected_json")
    }

    func oauth(_ request: OAuthHTTPRequest) async throws -> OAuthHTTPResponse {
        requests.append(request)
        guard !responses.isEmpty else {
            throw OAuthHTTPFailure(code: "missing_response")
        }
        return responses.removeFirst()
    }
}

private actor OAuthTransportSpy: CloudHTTPTransport {
    private(set) var requests: [OAuthHTTPRequest] = []
    let response: OAuthHTTPResponse

    init(response: OAuthHTTPResponse) {
        self.response = response
    }

    func stream(
        _ request: AuthorizedCloudHTTPRequest
    ) async throws -> AsyncThrowingStream<SSEEvent, Error> {
        throw OAuthHTTPFailure(code: "unexpected_stream")
    }

    func json(_ request: AuthorizedCloudHTTPRequest) async throws -> Data {
        throw OAuthHTTPFailure(code: "unexpected_json")
    }

    func oauth(_ request: OAuthHTTPRequest) async throws -> OAuthHTTPResponse {
        requests.append(request)
        return response
    }
}

private actor CancellingOAuthTransport: CloudHTTPTransport {
    func stream(
        _ request: AuthorizedCloudHTTPRequest
    ) async throws -> AsyncThrowingStream<SSEEvent, Error> {
        throw CancellationError()
    }

    func json(_ request: AuthorizedCloudHTTPRequest) async throws -> Data {
        throw CancellationError()
    }

    func oauth(_ request: OAuthHTTPRequest) async throws -> OAuthHTTPResponse {
        throw CancellationError()
    }
}
