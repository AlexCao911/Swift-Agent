import Foundation
import LocalAgentBridge
import LocalAgentLLMContracts

public final class LLMHostRuntime: @unchecked Sendable {
    public let hostProcessEpoch: HostProcessEpoch
    package let bridgeActor: LLMBridgeActor
    private let commandInbox: BoundedHostCommandInbox

    public convenience init(hostProcessEpoch: HostProcessEpoch) {
        self.init(
            hostProcessEpoch: hostProcessEpoch,
            rustSink: UnavailableRustSink()
        )
    }

    package init(
        hostProcessEpoch: HostProcessEpoch,
        rustSink: any LLMHostRustSink,
        modelExecutor: (any ModelGenerationExecuting)? = nil,
        toolExecutor: (any ToolBatchExecuting)? = nil,
        operationStartTimeout: Duration = .seconds(10)
    ) {
        let inbox = BoundedHostCommandInbox()
        let bridgeActor = LLMBridgeActor(
            inbox: inbox,
            hostProcessEpoch: hostProcessEpoch,
            rustSink: rustSink,
            modelExecutor: modelExecutor,
            toolExecutor: toolExecutor,
            operationStartTimeout: operationStartTimeout
        )
        self.hostProcessEpoch = hostProcessEpoch
        commandInbox = inbox
        self.bridgeActor = bridgeActor

        inbox.setSignal { [weak bridgeActor] in
            Task {
                await bridgeActor?.signalInbox()
            }
        }
    }

    public func copy(_ ownedBytes: Data) -> HostCommandCopyReceipt {
        commandInbox.copyAndEnqueue(ownedBytes)
    }

    package func drain() async {
        await bridgeActor.drainAvailable()
    }

    public func beginQuiescing() {
        commandInbox.beginQuiescing()
    }
}

private struct UnavailableRustSink: LLMHostRustSink {
    func submit(
        _ envelope: LLMEventEnvelope
    ) async throws -> LLMEventSubmissionResult {
        .staleSession
    }

    func submitCommandAcknowledgement(
        _ acknowledgement: HostCommandAcknowledgement
    ) async -> Bool {
        false
    }

    func acknowledgePreparedSessionCleanup(
        _ acknowledgement: PreparedSessionCleanupAcknowledgementDTO
    ) async -> Bool {
        false
    }

    func confirmPreparedSessionClosed(
        _ receipt: PreparedSessionClosedReceiptDTO
    ) async -> Bool {
        false
    }
}
