import Foundation
import LocalAgentLLMContracts

package actor OAuthCredentialRefreshCoordinator {
    private struct Key: Hashable {
        let credentialRef: String
        let presetID: ProviderPresetID
    }

    private let credentialStore: ProviderCredentialStore
    private let oauth: OAuthHTTPClient
    private let hostProcessEpoch: HostProcessEpoch
    private let clock: @Sendable () -> Date
    private let refreshBuffer: TimeInterval
    private var inFlight: [Key: Task<Bool, Error>] = [:]

    package init(
        credentialStore: ProviderCredentialStore,
        oauth: OAuthHTTPClient,
        hostProcessEpoch: HostProcessEpoch,
        clock: @escaping @Sendable () -> Date = Date.init,
        refreshBuffer: TimeInterval = 5 * 60
    ) {
        self.credentialStore = credentialStore
        self.oauth = oauth
        self.hostProcessEpoch = hostProcessEpoch
        self.clock = clock
        self.refreshBuffer = refreshBuffer
    }

    package func refreshIfNeeded(
        credentialRef: String,
        profile: ProviderOAuthProfile
    ) async throws -> Bool {
        try Task.checkCancellation()
        let key = Key(
            credentialRef: credentialRef,
            presetID: profile.presetID
        )
        let task: Task<Bool, Error>
        if let existing = inFlight[key] {
            task = existing
        } else {
            let store = credentialStore
            let client = oauth
            let epoch = hostProcessEpoch
            let now = clock
            let buffer = refreshBuffer
            task = Task.detached {
                try await Self.performRefreshIfNeeded(
                    credentialRef: credentialRef,
                    profile: profile,
                    credentialStore: store,
                    oauth: client,
                    hostProcessEpoch: epoch,
                    now: now(),
                    refreshBuffer: buffer
                )
            }
            inFlight[key] = task
        }
        do {
            let refreshed = try await task.value
            inFlight[key] = nil
            try Task.checkCancellation()
            return refreshed
        } catch {
            inFlight[key] = nil
            if Task.isCancelled { throw CancellationError() }
            throw error
        }
    }

    private nonisolated static func performRefreshIfNeeded(
        credentialRef: String,
        profile: ProviderOAuthProfile,
        credentialStore: ProviderCredentialStore,
        oauth: OAuthHTTPClient,
        hostProcessEpoch: HostProcessEpoch,
        now: Date,
        refreshBuffer: TimeInterval
    ) async throws -> Bool {
        guard let slot = try await credentialStore.slot(credentialRef),
              slot.lifecycle == .active
        else {
            throw OAuthHTTPFailure(code: "oauth.credential_unavailable")
        }
        let lease = try await credentialStore.acquireUseLease(
            credentialRef: credentialRef,
            purpose: .validation,
            preparationID: nil,
            hostProcessEpoch: hostProcessEpoch
        )
        let current: OAuthTokenCredential
        do {
            current = try await credentialStore.withCredential(
                for: lease.leaseID
            ) {
                try OAuthTokenCredential.decode(from: $0)
            }
            try await credentialStore.releaseValidationLease(lease.leaseID)
        } catch {
            try? await credentialStore.releaseValidationLease(lease.leaseID)
            throw error
        }
        guard current.expiresAt.map({
            $0 <= now.addingTimeInterval(refreshBuffer)
        }) == true else {
            return false
        }
        let refreshed = try await oauth.refresh(
            current,
            profile: profile,
            now: now
        )
        try await credentialStore.rotateCredential(
            credentialRef: credentialRef,
            expectedGeneration: slot.currentGeneration,
            replacement: try refreshed.secureSecret(),
            operationID: "oauth-refresh-\(UUID().uuidString.lowercased())"
        )
        return true
    }
}
