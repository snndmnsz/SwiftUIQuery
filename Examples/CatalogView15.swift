import SwiftUI
import SwiftUIQuery

/// iOS 15+ example. Uses the demo model and service from CatalogView.swift.
@MainActor
struct CatalogView15: View {
    @StateObject private var query: ObservableQueryResult<[CatalogProduct]>

    init() {
        _query = StateObject(wrappedValue: ObservableQueryResult(
            key: "demo:catalog",
            options: QueryOptions(cacheTime: .minutes(5))
        ) {
            try await DemoCatalog.shared.loadProducts()
        })
    }

    var body: some View {
        List {
            if let products = query.data {
                if products.isEmpty {
                    Text("No products yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(products) { product in
                        Text(product.name)
                    }
                }
            }

            if let error = query.error {
                Section("Unable to load products") {
                    Text(error.localizedDescription)
                        .foregroundStyle(.red)
                    Button("Try again") {
                        Task { await query.fetch() }
                    }
                    .disabled(query.isFetching)
                }
            }

            Button {
                Task { await query.refetch() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .disabled(!query.isResolved || query.isFetching)
        }
        .overlay {
            if query.isLoading {
                ProgressView("Loading products…")
            }
        }
        .navigationTitle("Catalog")
        .task { await query.run() }
        .refreshable { await query.refetch() }
    }
}
