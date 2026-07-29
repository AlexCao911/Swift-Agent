import Foundation
import Testing
@testable import LocalAgentLLMCloud

@Suite("OAuth HTTP client")
struct OAuthHTTPClientTests {
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
