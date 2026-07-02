import LocalAgentBridge

struct RunEventStreamService: Sendable {
    private let bridge: any ExecutionBridgeClient

    init(bridge: any ExecutionBridgeClient) {
        self.bridge = bridge
    }

    func observeEvents(runId: String, fromSequence: UInt64) -> AsyncThrowingStream<RuntimeEventDTO, Error> {
        bridge.observeEvents(runId: runId, fromSequence: fromSequence)
    }
}

#if DEBUG
extension RunEventStreamService {
    static var preview: Self {
        Self(bridge: MockRuntimeClient())
    }
}
#endif
