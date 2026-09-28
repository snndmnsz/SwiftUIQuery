import Foundation

/// A stable identifier for one logical query.
///
/// Use keys that include every parameter that changes the returned value, such as
/// `"products/42"` or `"users/123/posts"`.
public struct QueryKey: Hashable, Sendable, ExpressibleByStringLiteral, CustomStringConvertible {
    public let rawValue: String

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: StringLiteralType) {
        self.rawValue = value
    }

    public var description: String {
        rawValue
    }
}
