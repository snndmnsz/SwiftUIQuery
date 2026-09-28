/// An optimistic cache write's rollback. It cannot overwrite a newer data write.
/// Release this token after settling the mutation to release its saved snapshot.
public struct QueryRollback: Sendable {
    let restore: @Sendable () async -> Bool

    /// Returns false if the query was removed, changed, or already rolled back.
    @discardableResult
    public func rollback() async -> Bool { await restore() }
}
