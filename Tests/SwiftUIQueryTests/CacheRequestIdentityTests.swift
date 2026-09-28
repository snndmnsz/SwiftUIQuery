import Testing
@testable import SwiftUIQuery

@Suite("Cache request ownership")
struct CacheRequestIdentityTests {
    @Test func invalidationDoesNotDisturbOtherKeys() async throws {
        let client = QueryClient()
        let _: Int = try await client.fetch(key: "one") { 1 }
        let _: Int = try await client.fetch(key: "two") { 2 }
        await client.invalidate("one")
        let unaffected: Int = try await client.fetch(key: "two") { 99 }
        let refreshed: Int = try await client.refetch(key: "one")
        #expect(unaffected == 2)
        #expect(refreshed == 1)
    }
}
