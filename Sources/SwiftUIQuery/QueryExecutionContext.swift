/// Task-local context for code executed inside a query operation.
///
/// Networking layers can read `currentKey` for logging without the query system
/// knowing anything about endpoints, URLs, or transport details.
public enum QueryExecutionContext {
    @TaskLocal public static var currentKey: QueryKey?
}
