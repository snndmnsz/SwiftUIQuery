import Foundation

public struct MutationState<Input: Sendable, Output: Sendable>: Sendable {
    public var status: MutationStatus = .idle
    public var variables: Input?
    public var data: Output?
    public var error: (any Error)?
    public init() {}
    public var isPending: Bool { status == .pending }
    public var isSuccess: Bool { status == .success }
    public var isError: Bool { status == .error }
}
