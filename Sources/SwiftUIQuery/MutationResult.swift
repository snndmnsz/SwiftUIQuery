import Foundation
import Observation

@available(iOS 17, macOS 14, *)
@MainActor
@Observable
public final class MutationResult<Input: Sendable, Output: Sendable> {
    public private(set) var state: MutationState<Input, Output>
    @ObservationIgnored private let controller: MutationController<Input, Output>

    // Swift 6.0/6.1 Observation macros use a generic parameter named
    // MutationResult in their synthesized helper, shadowing this class name.
    // Supplying the helper explicitly keeps the public API and older toolchains.
    nonisolated func withMutation<Member, ReturnValue>(
        keyPath: KeyPath<MutationResult<Input, Output>, Member>,
        _ mutation: () throws -> ReturnValue
    ) rethrows -> ReturnValue {
        try _$observationRegistrar.withMutation(of: self, keyPath: keyPath, mutation)
    }

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
