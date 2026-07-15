import Foundation
import LocalAgentLLMContracts
import Testing
@testable import LocalAgentLLMLocal

@Suite("C++ native handle ownership")
struct CppInferenceOwnershipTests {
    @Test
    func concurrentAndRepeatedCloseReleasesExactlyOnce() async throws {
        let calls = LockedCounter()
        let handle = LockedNativeHandle(pointer: OpaquePointer(bitPattern: 1)!) { _ in
            calls.increment()
            Thread.sleep(forTimeInterval: 0.02)
            return .success(())
        }

        let tasks = (0..<20).map { _ in
            Task.detached { try handle.close() }
        }
        for task in tasks { try await task.value }
        try handle.close()

        #expect(calls.value == 1)
        #expect(handle.isClosed)
    }

    @Test
    func failedCloseRestoresOpenStateAndCanBeRetried() throws {
        let calls = LockedCounter()
        let handle = LockedNativeHandle(pointer: OpaquePointer(bitPattern: 2)!) { _ in
            let attempt = calls.increment()
            if attempt == 1 {
                return .failure(LLMFailure(
                    code: "local_engine.unload_failed",
                    message: "injected close failure",
                    retryable: true
                ))
            }
            return .success(())
        }

        #expect(throws: LLMFailure.self) { try handle.close() }
        #expect(!handle.isClosed)
        try handle.close()
        #expect(handle.isClosed)
        #expect(calls.value == 2)
    }

    @Test
    func closeWaitsForAnInFlightNativeCallBeforeReleasingThePointer() async throws {
        let entered = DispatchSemaphore(value: 0)
        let allowReturn = DispatchSemaphore(value: 0)
        let calls = LockedCounter()
        let handle = LockedNativeHandle(pointer: OpaquePointer(bitPattern: 3)!) { _ in
            calls.increment()
            return .success(())
        }

        let operation = Task.detached {
            try handle.withOpenPointer { _ in
                entered.signal()
                allowReturn.wait()
            }
        }
        let entryResult = await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: entered.wait(timeout: .now() + 1))
            }
        }
        #expect(entryResult == .success)

        let close = Task.detached { try handle.close() }
        try await Task.sleep(for: .milliseconds(20))
        #expect(calls.value == 0)

        allowReturn.signal()
        try await operation.value
        try await close.value
        #expect(calls.value == 1)
        #expect(handle.isClosed)
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    @discardableResult
    func increment() -> Int {
        lock.withLock {
            count += 1
            return count
        }
    }

    var value: Int { lock.withLock { count } }
}
