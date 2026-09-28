#if canImport(UIKit)
import UIKit
import Combine
import SwiftUIQuery

/// A self-contained iOS 15+ example. Present inside a UINavigationController.
@MainActor
final class CatalogViewController: UITableViewController {
    private let query: ObservableQueryResult<[String]>
    private var subscriptions = Set<AnyCancellable>()
    private var refreshTask: Task<Void, Never>?
    private var products: [String] = []
    private let statusLabel = UILabel()

    init(client: QueryClient = .shared) {
        query = ObservableQueryResult(
            key: "uikit/catalog", client: client,
            options: QueryOptions(staleTime: .minutes(5))
        ) {
            try await Task.sleep(nanoseconds: 300_000_000)
            return ["Notebook", "Pencil", "Backpack"]
        }
        super.init(style: .plain)
    }

    required init?(coder: NSCoder) {
        fatalError("Use init(client:)")
    }

    deinit {
        refreshTask?.cancel()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Catalog"
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "Product")
        statusLabel.font = .preferredFont(forTextStyle: .body)
        statusLabel.adjustsFontForContentSizeCategory = true
        statusLabel.numberOfLines = 0
        statusLabel.textAlignment = .center
        tableView.backgroundView = statusLabel
        refreshControl = UIRefreshControl()
        refreshControl?.addTarget(self, action: #selector(refresh), for: .valueChanged)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        guard subscriptions.isEmpty else { return }
        query.$state.sink { [weak self] state in
            // @Published emits before query.state changes. Render this snapshot.
            self?.render(state)
        }.store(in: &subscriptions)
        // Performs an initial fetch and polls if refetchInterval is configured.
        query.startPeriodicRefetch()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        refreshTask?.cancel()
        refreshTask = nil
        query.stopObserving()
        subscriptions.removeAll()
        refreshControl?.endRefreshing()
    }

    @objc private func refresh() {
        guard refreshTask == nil else { return }
        let query = query
        refreshTask = Task { [weak self] in
            await query.refetch()
            guard !Task.isCancelled else { return }
            self?.refreshControl?.endRefreshing()
            self?.refreshTask = nil
        }
    }

    private func render(_ state: QueryState<[String]>) {
        products = state.data ?? []
        navigationItem.prompt = state.error?.localizedDescription
        if state.isLoading {
            statusLabel.text = "Loading…"
        } else if products.isEmpty {
            statusLabel.text = state.error == nil ? "No products" : "Pull to retry"
        } else {
            statusLabel.text = nil
        }
        if !state.isFetching { refreshControl?.endRefreshing() }
        tableView.reloadData()
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        products.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "Product", for: indexPath)
        var content = cell.defaultContentConfiguration()
        content.text = products[indexPath.row]
        cell.contentConfiguration = content
        return cell
    }
}
#endif
