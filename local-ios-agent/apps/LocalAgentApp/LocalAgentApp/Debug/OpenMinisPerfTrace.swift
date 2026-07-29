#if DEBUG
import Foundation

final class OpenMinisPerfTrace: @unchecked Sendable {
    private let lock = NSLock()
    private let now: @Sendable () -> UInt64
    private var timestamps: [String: UInt64] = [:]

    init(
        now: @escaping @Sendable () -> UInt64 = {
            DispatchTime.now().uptimeNanoseconds
        }
    ) {
        self.now = now
    }

    @discardableResult
    func mark(_ name: String) -> UInt64 {
        let timestamp = now()
        lock.withLock {
            timestamps[name] = timestamp
        }
        return timestamp
    }

    func elapsedNanoseconds(from start: String, to end: String) -> UInt64? {
        lock.withLock {
            guard let start = timestamps[start],
                  let end = timestamps[end],
                  end >= start else {
                return nil
            }
            return end - start
        }
    }
}
#endif
