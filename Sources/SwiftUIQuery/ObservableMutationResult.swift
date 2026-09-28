import Foundation
import Combine

/// Combine mutation adapter for SwiftUI and UIKit on iOS 15+.
/// UIKit consumers store this result and subscribe to `$state`, rendering the
/// emitted snapshot rather than reading the property during publication.
@MainActor
public final class ObservableMutationResult<Input: Sendable, Output: Sendable>: ObservableObject {
    @Published public private(set) var state: MutationState<Input, Output>
    private let controller: MutationController<Input, Output>

    /// Each call executes independently: no query caching, deduplication, or automatic retry.
    public init(
        operation: @escaping @Sendable (Input) async throws -> Output,
        onMutate: (@MainActor (Input) async throws -> QueryRollback?)? = nil,
        onSuccess: (@MainActor (Output, Input) async -> Void)? = nil,
        onError: (@MainActor (any Error, Input) async -> Void)? = nil,
        onSettled: (@MainActor (Input) async -> Void)? = nil
    ) {
        let controller = MutationController(operation: operation, onMutate: onMutate,
                                            onSuccess: onSuccess, onError: onError, onSettled: onSettled)
        self.controller = controller
        state = controller.state
        controller.onStateChange = { [weak self] in self?.state = $0 }
    }

    /// Captures an operation owner weakly. Callback captures remain caller-owned.
    public convenience init<Owner: AnyObject & Sendable>(
        owner: Owner,
        operation: @escaping @Sendable (Owner, Input) async throws -> Output,
        onMutate: (@MainActor (Input) async throws -> QueryRollback?)? = nil,
        onSuccess: (@MainActor (Output, Input) async -> Void)? = nil,
        onError: (@MainActor (any Error, Input) async -> Void)? = nil,
        onSettled: (@MainActor (Input) async -> Void)? = nil
    ) {
        self.init(operation: { [weak owner] input in
            guard let owner else { throw QueryError.ownerReleased }
            return try await operation(owner, input)
        }, onMutate: onMutate, onSuccess: onSuccess, onError: onError, onSettled: onSettled)
    }

    public var data: Output? { state.data }
    public var variables: Input? { state.variables }
    public var error: (any Error)? { state.error }
    public var isPending: Bool { state.isPending }
    public var isSuccess: Bool { state.isSuccess }
    public var isError: Bool { state.isError }
    public var isIdle: Bool { state.status == .idle }

    @discardableResult
    public func mutate(_ input: Input) async throws -> Output { try await controller.mutate(input) }
    public func reset() { controller.reset() }
    public func dispose() { controller.dispose() }
}
