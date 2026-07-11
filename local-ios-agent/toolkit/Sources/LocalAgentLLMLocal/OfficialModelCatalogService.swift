import Foundation
import LocalAgentLLMContracts

public final class OfficialModelCatalogService: @unchecked Sendable {
    private let store: LocalModelStore
    private let keyRing: Data

    package init(store: LocalModelStore, keyRing: Data) {
        self.store = store
        self.keyRing = keyRing
    }

    public convenience init(store: LocalModelStore) throws {
        let resources = try OfficialModelCatalogResources.loadBundled()
        self.init(store: store, keyRing: resources.keyRing)
    }

    public func accept(
        bundled: Data,
        remote: Data?
    ) throws -> AcceptedLocalModelCatalog {
        var accepted = try loadPersisted()

        let bundledCandidate: VerifiedLocalModelCatalog?
        do {
            bundledCandidate = try OfficialLocalModelCatalogVerifier.verify(
                envelope: bundled,
                keyRing: keyRing
            )
        } catch let error as LLMFailure {
            if accepted == nil { throw error }
            bundledCandidate = nil
        }
        if let bundledCandidate {
            accepted = try consider(
                bundledCandidate,
                source: .bundled,
                current: accepted,
                ignoreRollback: accepted != nil
            )
        }

        guard let baseline = accepted else {
            throw catalogStateInvalid("no trusted bundled or persisted catalog exists")
        }
        guard let remote else { return baseline }

        let remoteCandidate: VerifiedLocalModelCatalog
        do {
            remoteCandidate = try OfficialLocalModelCatalogVerifier.verify(
                envelope: remote,
                keyRing: keyRing
            )
        } catch {
            return baseline
        }
        return try consider(
            remoteCandidate,
            source: .remote,
            current: baseline,
            ignoreRollback: false
        ) ?? baseline
    }

    private func loadPersisted() throws -> AcceptedLocalModelCatalog? {
        let stored: StoredLocalCatalogState?
        do {
            stored = try store.readCatalogState()
        } catch {
            throw catalogStateInvalid("persisted catalog row is corrupt")
        }
        guard let state = stored else { return nil }
        do {
            var envelope = Data("{\"signed\":".utf8)
            envelope.append(state.canonicalSignedBytes)
            envelope.append(Data(",\"signature\":\"\(Base64URL.encode(state.signature))\"}".utf8))
            let verified = try OfficialLocalModelCatalogVerifier.verify(
                envelope: envelope,
                keyRing: keyRing
            )
            guard verified.catalogRevision == state.acceptedRevision,
                  verified.keyID == state.keyID,
                  verified.canonicalSignedBytes == state.canonicalSignedBytes,
                  verified.signature == state.signature
            else { throw catalogStateInvalid("persisted catalog tuple is inconsistent") }
            return AcceptedLocalModelCatalog(
                verified: verified,
                source: .persisted,
                acceptedAt: state.acceptedAt
            )
        } catch {
            throw catalogStateInvalid("persisted accepted catalog cannot be re-verified")
        }
    }

    private func consider(
        _ candidate: VerifiedLocalModelCatalog,
        source: AcceptedLocalModelCatalog.Source,
        current: AcceptedLocalModelCatalog?,
        ignoreRollback: Bool
    ) throws -> AcceptedLocalModelCatalog? {
        if let current, candidate.catalogRevision < current.verified.catalogRevision, ignoreRollback {
            return current
        }
        let stored = try store.acceptVerifiedCatalog(
            candidate,
            expectedAcceptedRevision: current?.verified.catalogRevision
        )
        if let current,
           candidate.catalogRevision <= current.verified.catalogRevision {
            return stored
        }
        return AcceptedLocalModelCatalog(
            verified: stored.verified,
            source: source,
            acceptedAt: stored.acceptedAt
        )
    }
}

private func catalogStateInvalid(_ message: String) -> LLMFailure {
    LLMFailure(code: "download.catalog_state_invalid", message: message, retryable: false)
}
