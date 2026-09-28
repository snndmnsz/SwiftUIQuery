import Foundation

/// A small, typed cache lifetime value.
public struct CacheDuration: Sendable, Equatable {
    public static let `default`: CacheDuration = .minutes(5)

    let seconds: TimeInterval

    private init(seconds: TimeInterval) {
        self.seconds = seconds.isNaN ? 0 : max(0, seconds)
    }

    public static func seconds(_ value: TimeInterval) -> CacheDuration {
        CacheDuration(seconds: value)
    }

    public static func minutes(_ value: TimeInterval) -> CacheDuration {
        CacheDuration(seconds: value * 60)
    }

    public static func hours(_ value: TimeInterval) -> CacheDuration {
        CacheDuration(seconds: value * 60 * 60)
    }

    public static func days(_ value: TimeInterval) -> CacheDuration {
        CacheDuration(seconds: value * 60 * 60 * 24)
    }

    func adding(to date: Date) -> Date {
        date.addingTimeInterval(seconds)
    }
}
