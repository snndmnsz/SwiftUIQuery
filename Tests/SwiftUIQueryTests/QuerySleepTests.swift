import Testing
@testable import SwiftUIQuery

@Suite("Back-deployed query sleep")
struct QuerySleepTests {
    @Test func zeroDelayCompletes() async throws {
        try await QuerySleep.sleep(for: .seconds(0))
    }

    @Test func cancellationInterruptsLargeDelayWithoutOverflow() async {
        let task = Task {
            try await QuerySleep.sleep(for: .seconds(.greatestFiniteMagnitude))
        }
        task.cancel()
        do {
            try await task.value
            Issue.record("Expected cancellation")
        } catch is CancellationError {
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }
}
