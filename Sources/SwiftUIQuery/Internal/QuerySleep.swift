import Foundation

/// Cancellation-aware sleeping without the iOS 16 Duration/Clock APIs.
enum QuerySleep {
    static func sleep(for duration: CacheDuration) async throws {
        let nanoseconds = duration.seconds * 1_000_000_000
        // Saturate before conversion: large retry backoffs must not trap.
        let delay = nanoseconds >= Double(UInt64.max)
            ? UInt64.max
            : UInt64(nanoseconds)
        try await Task<Never, Never>.sleep(nanoseconds: delay)
    }
}
