import Foundation
import LocalAgentLLMContracts

package enum CppTokenEvent: Equatable, Sendable {
    case textDelta(String)
    case usage(inputTokens: UInt64?, outputTokens: UInt64?)
    case completed(rawFinishReason: String)
}

package enum CppEventChannelSendResult: Equatable, Sendable {
    case accepted
    case cancelled
    case closed
}

package struct CppTokenEventSequence: AsyncSequence, Sendable {
    package typealias Element = CppTokenEvent

    private let channel: CppEventChannel

    package init(channel: CppEventChannel) {
        self.channel = channel
    }

    package struct AsyncIterator: AsyncIteratorProtocol {
        private let channel: CppEventChannel

        fileprivate init(channel: CppEventChannel) {
            self.channel = channel
        }

        package func next() async throws -> CppTokenEvent? {
            try await channel.next()
        }
    }

    package func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(channel: channel)
    }
}

/// Synchronous native producers block on this condition-variable queue. The
/// async facade only moves the blocking dequeue onto a dedicated serial queue;
/// it does not add a second buffering policy.
package final class CppEventChannel: @unchecked Sendable {
    private let condition = NSCondition()
    private let consumerQueue = DispatchQueue(label: "local-agent.cpp-event-channel.consumer")
    private let maxEventCount: Int
    private let maxUTF8Bytes: Int
    private var queue: [(event: CppTokenEvent, byteCount: Int)] = []
    private var queuedBytes = 0
    private var finished = false
    private var cancelled = false
    private var cancellationDelivered = false
    private var terminalFailure: LLMFailure?
    private var failureDelivered = false

    package init(maxEventCount: Int, maxUTF8Bytes: Int) {
        precondition(maxEventCount > 0)
        precondition(maxUTF8Bytes > 0)
        self.maxEventCount = maxEventCount
        self.maxUTF8Bytes = maxUTF8Bytes
    }

    package var sequence: CppTokenEventSequence {
        CppTokenEventSequence(channel: self)
    }

    package var bufferedEventCount: Int {
        condition.withLock { queue.count }
    }

    package func send(_ event: CppTokenEvent) -> CppEventChannelSendResult {
        let bytes = byteCount(of: event)
        condition.lock()
        defer { condition.unlock() }

        while !cancelled, !finished, isFull(adding: bytes) {
            condition.wait()
        }
        if cancelled { return .cancelled }
        if finished { return .closed }

        queue.append((event, bytes))
        queuedBytes += bytes
        condition.broadcast()
        return .accepted
    }

    package func finish() {
        condition.withLock {
            guard !finished else { return }
            finished = true
            condition.broadcast()
        }
    }

    package func cancel() {
        condition.withLock {
            guard !cancelled else { return }
            cancelled = true
            condition.broadcast()
        }
    }

    package func fail(_ failure: LLMFailure) {
        condition.withLock {
            guard terminalFailure == nil, !finished else { return }
            terminalFailure = failure
            condition.broadcast()
        }
    }

    fileprivate func next() async throws -> CppTokenEvent? {
        try await withCheckedThrowingContinuation { continuation in
            consumerQueue.async { [self] in
                do {
                    continuation.resume(returning: try dequeue())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func dequeue() throws -> CppTokenEvent? {
        condition.lock()
        defer { condition.unlock() }

        while queue.isEmpty, !finished, !cancelled, terminalFailure == nil {
            condition.wait()
        }
        if !queue.isEmpty {
            let first = queue.removeFirst()
            queuedBytes -= first.byteCount
            condition.broadcast()
            return first.event
        }
        if cancelled, !cancellationDelivered {
            cancellationDelivered = true
            throw CancellationError()
        }
        if let terminalFailure, !failureDelivered {
            failureDelivered = true
            throw terminalFailure
        }
        return nil
    }

    private func isFull(adding bytes: Int) -> Bool {
        guard !queue.isEmpty else { return false }
        return queue.count >= maxEventCount || queuedBytes + bytes > maxUTF8Bytes
    }

    private func byteCount(of event: CppTokenEvent) -> Int {
        switch event {
        case let .textDelta(text), let .completed(text):
            text.utf8.count
        case .usage:
            MemoryLayout<UInt64?>.size * 2
        }
    }
}

private extension NSCondition {
    func withLock<T>(_ operation: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try operation()
    }
}
