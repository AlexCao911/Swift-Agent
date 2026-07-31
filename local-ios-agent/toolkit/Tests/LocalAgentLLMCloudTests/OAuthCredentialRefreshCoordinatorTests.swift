import Foundation
import LocalAgentLLMContracts
import Testing
@testable import LocalAgentLLMCore
@testable import LocalAgentLLMCloud

@Suite("OAuth credential refresh coordinator")
struct OAuthCredentialRefreshCoordinatorTests {
    @Test
    func concurrentCallersShareOneRefreshAndPersistRotatedRefreshToken() async throws {
        let fixture = try await refreshFixture(
            response: OAuthHTTPResponse(
                statusCode: 200,
                headers: [:],
                body: Data(
                    #"{"access_token":"access-two","refresh_token":"refresh-two","expires_in":7200}"#
                        .utf8
                )
            )
        )

        async let first = fixture.coordinator.refreshIfNeeded(
            credentialRef: "oauth",
            profile: fixture.profile
        )
        async let second = fixture.coordinator.refreshIfNeeded(
            credentialRef: "oauth",
            profile: fixture.profile
        )

        #expect(try await first)
        #expect(try await second)
        #expect(await fixture.transport.requestCount == 1)
        #expect(
            try await fixture.store.slot("oauth")?.currentGeneration == 2
        )
        let credential = try await loadCredential(
            fixture.store,
            generation: 2
        )
        #expect(credential.accessToken == "access-two")
        #expect(credential.refreshToken == "refresh-two")
    }

    @Test
    func cancelledWaiterDoesNotCancelTheSharedCredentialRotation() async throws {
        let fixture = try await refreshFixture(
            response: OAuthHTTPResponse(
                statusCode: 200,
                headers: [:],
                body: Data(
                    #"{"access_token":"access-two","refresh_token":"refresh-two","expires_in":7200}"#
                        .utf8
                )
            ),
            delay: .milliseconds(100)
        )
        let surviving = Task {
            try await fixture.coordinator.refreshIfNeeded(
                credentialRef: "oauth",
                profile: fixture.profile
            )
        }
        let cancelled = Task {
            try await fixture.coordinator.refreshIfNeeded(
                credentialRef: "oauth",
                profile: fixture.profile
            )
        }
        cancelled.cancel()

        await #expect(throws: CancellationError.self) {
            try await cancelled.value
        }
        #expect(try await surviving.value)
        #expect(await fixture.transport.requestCount == 1)
        #expect(
            try await fixture.store.slot("oauth")?.currentGeneration == 2
        )
    }

    @Test
    func terminalRefreshFailureLeavesCurrentCredentialGenerationIntact() async throws {
        let fixture = try await refreshFixture(
            response: OAuthHTTPResponse(
                statusCode: 400,
                headers: [:],
                body: Data(#"{"error":"invalid_grant"}"#.utf8)
            )
        )

        await #expect(throws: OAuthHTTPFailure.self) {
            try await fixture.coordinator.refreshIfNeeded(
                credentialRef: "oauth",
                profile: fixture.profile
            )
        }

        #expect(
            try await fixture.store.slot("oauth")?.currentGeneration == 1
        )
        let credential = try await loadCredential(
            fixture.store,
            generation: 1
        )
        #expect(credential.accessToken == "access-one")
        #expect(credential.refreshToken == "refresh-one")
    }
}

private struct OAuthRefreshFixture: Sendable {
    let store: ProviderCredentialStore
    let coordinator: OAuthCredentialRefreshCoordinator
    let transport: DelayedOAuthRefreshTransport
    let profile: ProviderOAuthProfile
}

private func refreshFixture(
    response: OAuthHTTPResponse,
    delay: Duration = .zero
) async throws -> OAuthRefreshFixture {
    let database = try SQLiteConnection(path: ":memory:")
    try LLMStoreSchema.ensureBaseSchema(database)
    try LLMStoreSchema.migrateToCurrent(database)
    let store = try ProviderCredentialStore(
        database: database,
        vault: LifecycleCredentialVault()
    )
    try await store.createSlot(
        credentialRef: "oauth",
        initialSecret: try OAuthTokenCredential(
            accessToken: "access-one",
            refreshToken: "refresh-one",
            expiresAt: Date().addingTimeInterval(30)
        ).secureSecret(),
        operationID: "create-oauth"
    )
    let transport = DelayedOAuthRefreshTransport(
        response: response,
        delay: delay
    )
    let profile = try #require(
        ProviderOAuthProfile.shipped.first { $0.presetID == .openAI }
    )
    return OAuthRefreshFixture(
        store: store,
        coordinator: OAuthCredentialRefreshCoordinator(
            credentialStore: store,
            oauth: OAuthHTTPClient(transport: transport),
            hostProcessEpoch: try HostProcessEpoch.generate()
        ),
        transport: transport,
        profile: profile
    )
}

private func loadCredential(
    _ store: ProviderCredentialStore,
    generation: UInt64
) async throws -> OAuthTokenCredential {
    let lease = try await store.acquireUseLease(
        credentialRef: "oauth",
        purpose: .validation,
        preparationID: nil,
        hostProcessEpoch: try HostProcessEpoch.generate()
    )
    #expect(lease.generation == generation)
    let credential = try await store.withCredential(for: lease.leaseID) {
        try OAuthTokenCredential.decode(from: $0)
    }
    try await store.releaseValidationLease(lease.leaseID)
    return credential
}

private actor DelayedOAuthRefreshTransport: CloudHTTPTransport {
    let response: OAuthHTTPResponse
    let delay: Duration
    private(set) var requestCount = 0

    init(response: OAuthHTTPResponse, delay: Duration) {
        self.response = response
        self.delay = delay
    }

    func oauth(
        _ request: OAuthHTTPRequest
    ) async throws -> OAuthHTTPResponse {
        requestCount += 1
        if delay > .zero {
            try await Task.sleep(for: delay)
        }
        return response
    }

    func json(_ request: AuthorizedCloudHTTPRequest) async throws -> Data {
        Issue.record("unexpected cloud JSON request")
        return Data()
    }

    func stream(
        _ request: AuthorizedCloudHTTPRequest
    ) async throws -> AsyncThrowingStream<SSEEvent, Error> {
        Issue.record("unexpected cloud stream request")
        return AsyncThrowingStream { $0.finish() }
    }
}
