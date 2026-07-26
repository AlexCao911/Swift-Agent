import Foundation
import LocalAgentLLMContracts

package final class BoundedHostCommandInbox: @unchecked Sendable {
    private let capacity: Int
    private let lock = NSLock()
    private var queue: [Data] = []
    private var signal: (@Sendable () -> Void)?
    private var acceptingCommands = true

    package init(capacity: Int = 64) {
        precondition(capacity > 0)
        self.capacity = capacity
        queue.reserveCapacity(capacity)
    }

    package func setSignal(_ signal: @escaping @Sendable () -> Void) {
        lock.lock()
        self.signal = signal
        lock.unlock()
    }

    package func copyAndEnqueue(_ ownedBytes: Data) -> HostCommandCopyReceipt {
        lock.lock()
        guard acceptingCommands else {
            lock.unlock()
            return .hostUnavailable
        }
        guard queue.count < capacity else {
            lock.unlock()
            return .backpressure
        }
        queue.append(ownedBytes)
        let signal = self.signal
        lock.unlock()

        signal?()
        return .copied
    }

    package func pop() -> Data? {
        lock.lock()
        defer { lock.unlock() }
        guard !queue.isEmpty else { return nil }
        return queue.removeFirst()
    }

    package func hasQueuedData() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return !queue.isEmpty
    }

    package func beginQuiescing() {
        lock.lock()
        acceptingCommands = false
        lock.unlock()
    }
}
