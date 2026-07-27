import Foundation
import LocalAgentLLMCloud

enum AppCloudApprovalContent: Equatable, Sendable {
    case origin(origin: EgressOrigin, profileName: String)
    case scope(origin: EgressOrigin, summary: EgressApprovalDisplaySummary)
    case providerState(
        profileName: String,
        origin: EgressOrigin,
        disclosure: ProviderRetentionDisclosure
    )
}

struct AppCloudApprovalRequest: Identifiable, Equatable, Sendable {
    let id: UUID
    let content: AppCloudApprovalContent
}

actor AppCloudApprovalBroker: CloudLLMApprovalPrompting {
    nonisolated let updates: AsyncStream<AppCloudApprovalRequest?>

    private struct Pending {
        let request: AppCloudApprovalRequest
        let continuation: CheckedContinuation<EgressDecision, Never>
    }

    private let updateContinuation: AsyncStream<AppCloudApprovalRequest?>.Continuation
    private var current: Pending?
    private var queue: [Pending] = []

    init() {
        var continuation: AsyncStream<AppCloudApprovalRequest?>.Continuation!
        updates = AsyncStream(bufferingPolicy: .bufferingNewest(1)) {
            continuation = $0
        }
        updateContinuation = continuation
    }

    var currentRequest: AppCloudApprovalRequest? {
        current?.request
    }

    var pendingCount: Int {
        current == nil ? 0 : 1
    }

    var totalRequestCount: Int {
        pendingCount + queue.count
    }

    func requestOriginApproval(
        _ origin: EgressOrigin,
        profileName: String
    ) async -> EgressDecision {
        await enqueue(.origin(origin: origin, profileName: profileName))
    }

    func requestScopeApproval(
        origin: EgressOrigin,
        summary: EgressApprovalDisplaySummary
    ) async -> EgressDecision {
        await enqueue(.scope(origin: origin, summary: summary))
    }

    func requestProviderStateApproval(
        profileName: String,
        origin: EgressOrigin,
        disclosure: ProviderRetentionDisclosure
    ) async -> EgressDecision {
        await enqueue(.providerState(
            profileName: profileName,
            origin: origin,
            disclosure: disclosure
        ))
    }

    func respond(_ decision: EgressDecision) {
        guard let pending = current else { return }
        current = nil
        pending.continuation.resume(returning: decision)
        presentNext()
    }

    func dismissCurrent() {
        respond(.deny)
    }

    func denyAll() {
        let pending = [current].compactMap(\.self) + queue
        current = nil
        queue.removeAll()
        pending.forEach { $0.continuation.resume(returning: .deny) }
        updateContinuation.yield(nil)
    }

    private func enqueue(_ content: AppCloudApprovalContent) async -> EgressDecision {
        await withCheckedContinuation { continuation in
            let pending = Pending(
                request: AppCloudApprovalRequest(id: UUID(), content: content),
                continuation: continuation
            )
            if current == nil {
                current = pending
                updateContinuation.yield(pending.request)
            } else {
                queue.append(pending)
            }
        }
    }

    private func presentNext() {
        if queue.isEmpty {
            updateContinuation.yield(nil)
        } else {
            current = queue.removeFirst()
            updateContinuation.yield(current?.request)
        }
    }
}
