import SwiftUI
import SwiftUIQuery

private actor DemoFavorites {
    private var favorite = false
    func load() -> Bool { favorite }
    func save(_ value: Bool) async throws -> Bool {
        try await Task.sleep(nanoseconds: 250_000_000)
        favorite = value
        return value
    }
}

/// iOS 15 example: shared query state, mutation, optimistic update, and rollback.
@MainActor
struct FavoriteView15: View {
    @StateObject private var query: ObservableQueryResult<Bool>
    @StateObject private var mutation: ObservableMutationResult<Bool, Bool>

    init() {
        let client = QueryClient()
        let service = DemoFavorites()
        _query = StateObject(wrappedValue: ObservableQueryResult(
            key: "favorite", client: client,
            options: QueryOptions(staleTime: .seconds(30), gcTime: .minutes(5))
        ) { await service.load() })
        _mutation = StateObject(wrappedValue: ObservableMutationResult(
            operation: { try await service.save($0) },
            onMutate: { desired in
                try await client.optimisticUpdate(key: "favorite", as: Bool.self) { _ in desired }
            },
            onSuccess: { saved, _ in
                try? await client.setQueryData(key: "favorite", data: saved)
            },
            onSettled: { _ in await client.invalidate("favorite") }
        ))
    }

    var body: some View {
        VStack(spacing: 16) {
            Button {
                let desired = !(query.data ?? false)
                Task { try? await mutation.mutate(desired) }
            } label: {
                Label(query.data == true ? "Remove favorite" : "Add favorite",
                      systemImage: query.data == true ? "star.fill" : "star")
            }
            .disabled(mutation.isPending || query.data == nil)
            if mutation.isPending { ProgressView("Saving…") }
            if let error = mutation.error ?? query.error {
                Text(error.localizedDescription).foregroundStyle(.red)
            }
        }
        .padding()
        .task { await query.run() }
    }
}
