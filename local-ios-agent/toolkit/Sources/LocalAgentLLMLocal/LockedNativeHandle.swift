import Foundation
import LocalAgentLLMContracts

/// Owns one opaque C handle. Only the thread that wins `open -> closing`
/// invokes the release function; concurrent callers observe that same result.
package final class LockedNativeHandle: @unchecked Sendable {
    private enum State {
        case open(OpaquePointer)
        case closing(OpaquePointer, attempt: UInt64)
        case closed
    }

    private let condition = NSCondition()
    private let release: @Sendable (OpaquePointer) -> Result<Void, LLMFailure>
    private var state: State
    private var activeBorrows = 0
    private var attempt: UInt64 = 0
    private var lastResult: (attempt: UInt64, result: Result<Void, LLMFailure>)?

    package init(
        pointer: OpaquePointer,
        release: @escaping @Sendable (OpaquePointer) -> Result<Void, LLMFailure>
    ) {
        state = .open(pointer)
        self.release = release
    }

    deinit {
        try? close()
    }

    package var isClosed: Bool {
        condition.lock()
        defer { condition.unlock() }
        if case .closed = state { return true }
        return false
    }

    package func withOpenPointer<T>(
        _ operation: (OpaquePointer) throws -> T
    ) throws -> T {
        condition.lock()
        while case .closing = state { condition.wait() }
        guard case let .open(pointer) = state else {
            condition.unlock()
            throw LLMFailure(
                code: "local_engine.handle_closed",
                message: "native inference handle is already closed",
                retryable: false
            )
        }
        activeBorrows += 1
        condition.unlock()
        defer {
            condition.lock()
            activeBorrows -= 1
            if activeBorrows == 0 { condition.broadcast() }
            condition.unlock()
        }
        return try operation(pointer)
    }

    package func close() throws {
        condition.lock()
        switch state {
        case .closed:
            condition.unlock()
            return
        case let .closing(_, observedAttempt):
            waiting: while true {
                condition.wait()
                if case let .closing(_, activeAttempt) = state,
                   activeAttempt == observedAttempt
                {
                    continue waiting
                }
                break waiting
            }
            if let lastResult, lastResult.attempt == observedAttempt {
                condition.unlock()
                return try lastResult.result.get()
            }
            condition.unlock()
            return
        case let .open(pointer):
            attempt += 1
            let activeAttempt = attempt
            state = .closing(pointer, attempt: activeAttempt)
            while activeBorrows > 0 { condition.wait() }
            condition.unlock()

            let result = release(pointer)
            condition.lock()
            lastResult = (activeAttempt, result)
            switch result {
            case .success:
                state = .closed
            case .failure:
                state = .open(pointer)
            }
            condition.broadcast()
            condition.unlock()
            return try result.get()
        }
    }
}
