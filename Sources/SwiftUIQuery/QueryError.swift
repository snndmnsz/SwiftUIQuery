import Foundation

public enum QueryError: Error, Sendable, LocalizedError {
    case disabled(QueryKey)
    case missingOperation(QueryKey)
    case typeMismatch(key: QueryKey, expected: String)
    case cancelled
    case underlying(String)
    case disposed
    case ownerReleased
    case invalidRefetchInterval

    public var errorDescription: String? {
        switch self {
        case .disabled(let key):
            "Query is disabled for key \(key.rawValue)."
        case .missingOperation(let key):
            "No registered operation exists for key \(key.rawValue)."
        case .typeMismatch(let key, let expected):
            "Cached value for key \(key.rawValue) does not match expected type \(expected)."
        case .cancelled:
            "Query was cancelled."
        case .disposed:
            "The query or mutation has been disposed."
        case .ownerReleased:
            "The operation owner has been released."
        case .invalidRefetchInterval:
            "The refetch interval must be greater than zero."
        case .underlying(let message):
            message
        }
    }
}
