import Foundation

/// A value snapshot of a query's UI-facing state.
public struct QueryState<Value: Sendable>: Sendable {
    public var data: Value?
    public var error: (any Error)?
    public var isLoading: Bool
    public var isFetching: Bool
    public var lastUpdated: Date?
    public var isStale: Bool
    public var isPreviousData: Bool

    public init(
        data: Value? = nil,
        error: (any Error)? = nil,
        isLoading: Bool = false,
        isFetching: Bool = false,
        lastUpdated: Date? = nil,
        isStale: Bool = true,
        isPreviousData: Bool = false
    ) {
        self.data = data
        self.error = error
        self.isLoading = isLoading
        self.isFetching = isFetching
        self.lastUpdated = lastUpdated
        self.isStale = isStale
        self.isPreviousData = isPreviousData
    }

    public var isSuccess: Bool {
        data != nil && error == nil
    }

    public var isError: Bool {
        error != nil
    }

    public var isResolved: Bool {
        data != nil || error != nil
    }
}
