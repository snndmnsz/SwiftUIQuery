import Foundation

@MainActor
final class MutationController<Input: Sendable, Output: Sendable> {
    private(set) var state = MutationState<Input, Output>() {
        didSet { onStateChange?(state) }
    }
    var onStateChange: (@MainActor (MutationState<Input, Output>) -> Void)?
    private var generation = 0
    private var operation: (@Sendable (Input) async throws -> Output)?
    private var onMutate: (@MainActor (Input) async throws -> QueryRollback?)?
    private var onSuccess: (@MainActor (Output, Input) async -> Void)?
    private var onError: (@MainActor (any Error, Input) async -> Void)?
    private var onSettled: (@MainActor (Input) async -> Void)?

    init(operation: @escaping @Sendable (Input) async throws -> Output,
         onMutate: (@MainActor (Input) async throws -> QueryRollback?)?,
         onSuccess: (@MainActor (Output, Input) async -> Void)?,
         onError: (@MainActor (any Error, Input) async -> Void)?,
         onSettled: (@MainActor (Input) async -> Void)?) {
        self.operation = operation
        self.onMutate = onMutate
        self.onSuccess = onSuccess
        self.onError = onError
        self.onSettled = onSettled
    }

    func mutate(_ input: Input) async throws -> Output {
        guard let operation else { throw QueryError.disposed }
        generation += 1
        let current = generation
        // Each invocation owns its callbacks and rollback even when another starts.
        let onMutate = onMutate, onSuccess = onSuccess, onError = onError, onSettled = onSettled
        state = MutationState()
        state.variables = input
        state.status = .pending
        var rollback: QueryRollback?
        let output: Output
        do {
            try Task.checkCancellation()
            rollback = try await onMutate?(input)
            try Task.checkCancellation()
            output = try await operation(input)
        } catch {
            await rollback?.rollback()
            await onError?(error, input)
            await onSettled?(input)
            if current == generation {
                state.error = error
                state.status = .error
            }
            throw error
        }
        // Once the server operation succeeds, never roll it back merely because
        // the caller was canceled. Reconciliation callbacks must still run.
        await onSuccess?(output, input)
        await onSettled?(input)
        if current == generation {
            state.data = output
            state.error = nil
            state.status = .success
        }
        return output
    }

    func reset() {
        generation += 1
        state = MutationState()
    }

    func dispose() {
        reset()
        operation = nil
        onMutate = nil
        onSuccess = nil
        onError = nil
        onSettled = nil
    }
}
