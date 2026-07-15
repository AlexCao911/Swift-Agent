import Foundation
import Testing
@testable import LocalAgentLLMLocal

@Suite("C++ event channel")
struct CppEventChannelTests {
    @Test
    func boundedChannelBackpressuresWithoutDroppingOrReordering() async throws {
        let channel = CppEventChannel(maxEventCount: 2, maxUTF8Bytes: 8)
        let producer = Task.detached {
            for value in 0..<20 {
                let result = channel.send(.textDelta(String(value)))
                guard result == .accepted else { return result }
            }
            channel.finish()
            return CppEventChannelSendResult.accepted
        }

        try await Task.sleep(for: .milliseconds(30))
        #expect(channel.bufferedEventCount == 2)

        var iterator = channel.sequence.makeAsyncIterator()
        var values: [String] = []
        while let event = try await iterator.next() {
            if case let .textDelta(value) = event { values.append(value) }
        }
        #expect(await producer.value == .accepted)
        #expect(values == (0..<20).map(String.init))
    }

    @Test
    func cancellationWakesBlockedProducerAndIsObservedExactlyOnceAfterDrain() async throws {
        let channel = CppEventChannel(maxEventCount: 1, maxUTF8Bytes: 8)
        #expect(channel.send(.textDelta("first")) == .accepted)
        let blocked = Task.detached {
            channel.send(.textDelta("second"))
        }

        try await Task.sleep(for: .milliseconds(30))
        channel.cancel()
        #expect(await blocked.value == .cancelled)

        var iterator = channel.sequence.makeAsyncIterator()
        #expect(try await iterator.next() == .textDelta("first"))
        await #expect(throws: CancellationError.self) {
            try await iterator.next()
        }
        #expect(try await iterator.next() == nil)
    }
}
