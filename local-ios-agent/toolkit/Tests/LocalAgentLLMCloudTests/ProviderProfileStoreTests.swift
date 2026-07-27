import Foundation
import LocalAgentLLMContracts
import LocalAgentLLMCore
import Testing
@testable import LocalAgentLLMCloud

@Suite("Immutable cloud provider profiles")
struct ProviderProfileStoreTests {
    @Test
    func profileRevisionAndOriginArePinnedExactly() async throws {
        let validator = FixtureOriginValidator()
        let store = try ProviderProfileStore.inMemory(originValidator: validator)
        let profile = fixtureProfile()

        let stored = try await store.publish(profile)

        #expect(stored.revision == profile)
        #expect(stored.origin == EgressOrigin(
            scheme: "https",
            host: "api.openai.com",
            port: 443
        ))
        #expect(stored.lifecycle == .active)
        #expect((await store.state(
            profileID: profile.profileID,
            profileRevision: profile.revision
        ))?.validationState == .unvalidated)
    }

    @Test
    func revisionsAreImmutableIdempotentMonotonicAndReopenExactly() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("llm-state.sqlite")
        let first = try ProviderProfileStore(fileURL: url, originValidator: FixtureOriginValidator())
        let revision1 = fixtureProfile()
        let firstPublish = try await first.publish(revision1)
        #expect(try await first.publish(revision1) == firstPublish)

        let conflicting = ProviderProfileRevision(
            profileID: revision1.profileID,
            revision: revision1.revision,
            presetID: revision1.presetID,
            displayName: "Conflicting Name",
            baseURL: revision1.baseURL,
            credentialRef: revision1.credentialRef,
            retentionMode: revision1.retentionMode
        )
        await expectProfileFailure("provider_profile.revision_conflict") {
            try await first.publish(conflicting)
        }
        await expectProfileFailure("provider_profile.revision_not_monotonic") {
            try await first.publish(fixtureProfile(revision: 0))
        }

        let revision2 = fixtureProfile(
            revision: 2,
            baseURL: URL(string: "https://api.openai.com/v1/organization")!
        )
        _ = try await first.publish(revision2)
        let reopened = try ProviderProfileStore(
            fileURL: url,
            originValidator: FixtureOriginValidator()
        )
        #expect(await reopened.profile(
            profileID: revision1.profileID,
            revision: 1
        )?.revision == revision1)
        #expect(await reopened.profile(
            profileID: revision1.profileID,
            revision: 2
        )?.revision == revision2)
    }

    @Test
    func archiveAndStateCASDoNotDeleteOtherRevisionsOrTargets() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("llm-state.sqlite")
        let store = try ProviderProfileStore(
            fileURL: url,
            originValidator: FixtureOriginValidator()
        )
        let llmStore = try LLMStore(fileURL: url)
        let revision1 = fixtureProfile()
        let revision2 = fixtureProfile(revision: 2)
        _ = try await store.publish(revision1)
        _ = try await store.publish(revision2)
        let target = LLMTargetRevision(
            targetID: LLMTargetID(rawValue: "target-cloud"),
            revision: 1,
            kind: .cloud(
                providerProfileID: revision1.profileID,
                providerProfileRevision: revision1.revision
            ),
            modelID: "gpt-fixture",
            defaultParameters: GenerationConfiguration()
        )
        try await llmStore.publishTarget(target)

        let initialState = try #require(await store.state(
            profileID: revision1.profileID,
            profileRevision: revision1.revision
        ))
        _ = try await store.updateState(
            profileID: revision1.profileID,
            profileRevision: revision1.revision,
            expectedStateRevision: initialState.stateRevision
        ) { state in
            state.catalogRevision = 9
        }
        await expectProfileFailure("provider_profile.state_revision_conflict") {
            _ = try await store.updateState(
                profileID: revision1.profileID,
                profileRevision: revision1.revision,
                expectedStateRevision: initialState.stateRevision
            ) { state in
                state.catalogRevision = 10
            }
        }

        try await store.archive(
            profileID: revision1.profileID,
            revision: revision1.revision,
            expectedLifecycle: .active
        )
        #expect(await store.profile(
            profileID: revision1.profileID,
            revision: revision1.revision
        )?.lifecycle == .archived)
        #expect(await store.profile(
            profileID: revision2.profileID,
            revision: revision2.revision
        )?.lifecycle == .active)
        #expect(await llmStore.target(reference: target.reference) == target)
    }

    @Test
    func forbiddenOriginFailsBeforeAnyProfileRowExists() async throws {
        let validator = FixtureOriginValidator(
            rejectedHosts: ["127.0.0.1"]
        )
        let store = try ProviderProfileStore.inMemory(originValidator: validator)
        let forbidden = fixtureProfile(
            baseURL: URL(string: "https://127.0.0.1/v1")!
        )

        await expectProfileFailure("provider_profile.origin_forbidden") {
            try await store.publish(forbidden)
        }
        #expect(await store.profile(
            profileID: forbidden.profileID,
            revision: forbidden.revision
        ) == nil)
    }

    @Test
    func reopenedWritersUseSQLiteStateCAS() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("llm-state.sqlite")
        let first = try ProviderProfileStore(
            fileURL: url,
            originValidator: FixtureOriginValidator()
        )
        let profile = fixtureProfile()
        _ = try await first.publish(profile)
        let stale = try ProviderProfileStore(
            fileURL: url,
            originValidator: FixtureOriginValidator()
        )

        _ = try await first.updateState(
            profileID: profile.profileID,
            profileRevision: profile.revision,
            expectedStateRevision: 1
        ) { state in
            state.catalogRevision = 7
        }
        await expectProfileFailure("provider_profile.state_revision_conflict") {
            try await stale.updateState(
                profileID: profile.profileID,
                profileRevision: profile.revision,
                expectedStateRevision: 1
            ) { state in
                state.catalogRevision = 8
            }
        }
    }

    @Test
    func normalizedColumnsCannotDivergeFromVersionedPayload() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("llm-state.sqlite")
        let store = try ProviderProfileStore(
            fileURL: url,
            originValidator: FixtureOriginValidator()
        )
        let profile = fixtureProfile()
        _ = try await store.publish(profile)
        let connection = try SQLiteConnection(path: url.path)
        try connection.execute(
            "UPDATE provider_profile_revisions SET lifecycle = 'archived' WHERE profile_id = ?1 AND revision = ?2",
            bindings: [.text(profile.profileID), .text(String(profile.revision))]
        )

        #expect(throws: ProviderProfileFailure.self) {
            _ = try ProviderProfileStore(
                fileURL: url,
                originValidator: FixtureOriginValidator()
            )
        }
    }
}

package struct FixtureOriginValidator: ProviderOriginValidating {
    let rejectedHosts: Set<String>

    init(rejectedHosts: Set<String> = []) {
        self.rejectedHosts = rejectedHosts
    }

    package func validate(_ baseURL: URL) async throws -> EgressOrigin {
        guard baseURL.scheme == "https",
              baseURL.user == nil,
              baseURL.password == nil,
              baseURL.fragment == nil,
              let host = baseURL.host?.lowercased(),
              !rejectedHosts.contains(host)
        else {
            throw ProviderProfileFailure(
                code: "provider_profile.origin_forbidden",
                message: "fixture origin rejected"
            )
        }
        return EgressOrigin(scheme: "https", host: host, port: UInt16(baseURL.port ?? 443))
    }
}

private func fixtureProfile(
    revision: UInt64 = 1,
    baseURL: URL = URL(string: "https://api.openai.com/v1")!
) -> ProviderProfileRevision {
    ProviderProfileRevision(
        profileID: "provider-main",
        revision: revision,
        presetID: .openAI,
        displayName: "OpenAI",
        baseURL: baseURL,
        credentialRef: "credential-main"
    )
}

private func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(
        "provider-profile-store-\(UUID().uuidString)",
        isDirectory: true
    )
}

private func expectProfileFailure<T>(
    _ code: String,
    operation: () async throws -> T
) async {
    do {
        _ = try await operation()
        Issue.record("expected ProviderProfileFailure with code \(code)")
    } catch let failure as ProviderProfileFailure {
        #expect(failure.code == code)
    } catch {
        Issue.record("unexpected error: \(error)")
    }
}
