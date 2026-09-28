import SwiftUI
import SwiftUIQuery

// Copy this file into an app target that links SwiftUIQuery.
// The demo service is local; no network connection or credentials are needed.
struct CatalogProduct: Identifiable, Sendable {
    let id: Int
    let name: String
}

actor DemoCatalog {
    static let shared = DemoCatalog()

    func loadProducts() async throws -> [CatalogProduct] {
        try await Task.sleep(nanoseconds: 300_000_000)
        return [
            CatalogProduct(id: 1, name: "Field Notes"),
            CatalogProduct(id: 2, name: "Everyday Backpack"),
            CatalogProduct(id: 3, name: "Travel Mug")
        ]
    }
}

@available(iOS 17, macOS 14, *)
@MainActor
struct CatalogView: View {
    @State private var query: QueryResult<[CatalogProduct]>

    init() {
        let result = QueryResult<[CatalogProduct]>(
            key: "demo:catalog",
            options: QueryOptions(cacheTime: .minutes(5))
        ) {
            try await DemoCatalog.shared.loadProducts()
        }
        _query = State(initialValue: result)
    }

    var body: some View {
        NavigationStack {
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
            }
            .overlay {
                if query.isLoading {
                    ProgressView("Loading products…")
                }
            }
            .navigationTitle("Catalog")
            .toolbar {
                Button("Refresh", systemImage: "arrow.clockwise") {
                    Task { await query.refetch() }
                }
                .disabled(!query.isResolved || query.isFetching)
            }
            .task { await query.run() }
            .refreshable { await query.refetch() }
        }
    }
}
