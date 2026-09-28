import Foundation

/// Per-request query behavior.
public struct QueryOptions: Sendable, Equatable {
    public var enabled: Bool
    /// Alias for staleTime. It does not control garbage collection.
    public var cacheTime: CacheDuration {
        get { staleTime }
        set { staleTime = newValue }
    }
    public var staleTime: CacheDuration
    public var gcTime: CacheDuration
    public var retry: Int
    public var retryDelay: CacheDuration
    public var exponentialBackoff: Bool
    public var refetchInterval: CacheDuration?
    public var keepPreviousData: Bool

    public init(
        enabled: Bool = true,
        cacheTime: CacheDuration = .default,
        retry: Int = 0,
        retryDelay: CacheDuration = .seconds(1),
        exponentialBackoff: Bool = false,
        refetchInterval: CacheDuration? = nil,
        keepPreviousData: Bool = true,
        staleTime: CacheDuration? = nil,
        gcTime: CacheDuration = .default
    ) {
        self.enabled = enabled
        self.staleTime = staleTime ?? cacheTime
        self.gcTime = gcTime
        self.retry = max(0, retry)
        self.retryDelay = retryDelay
        self.exponentialBackoff = exponentialBackoff
        self.refetchInterval = refetchInterval
        self.keepPreviousData = keepPreviousData
    }
}
