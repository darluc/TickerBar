import Foundation
import Combine

@MainActor
final class PopoverViewModel: ObservableObject {
    @Published var watchlist: [WatchItem] = []

    let refresher: QuoteRefresher
    let watchlistRepo: WatchlistRepository
    let settingsRepo: SettingsRepository

    private var observationTask: Task<Void, Never>?

    init(
        refresher: QuoteRefresher,
        watchlistRepo: WatchlistRepository,
        settingsRepo: SettingsRepository
    ) {
        self.refresher = refresher
        self.watchlistRepo = watchlistRepo
        self.settingsRepo = settingsRepo
        reload()
        startObserving()
    }

    func reload() {
        watchlist = (try? watchlistRepo.all()) ?? []
    }

    private func startObserving() {
        observationTask = Task { [weak self] in
            guard let stream = self?.watchlistRepo.observeAll() else { return }
            for await items in stream {
                await MainActor.run {
                    self?.watchlist = items
                }
            }
        }
    }

    @discardableResult
    func addFromSearch(_ result: SymbolSearchResult) -> Bool {
        if watchlist.contains(where: { $0.symbol == result.symbol }) {
            return false
        }
        let order = (watchlist.map(\.order).max() ?? -1) + 1
        let item = WatchItem(
            symbol: result.symbol,
            name: result.name.isEmpty ? result.symbol.code : result.name,
            order: order,
            inTicker: true
        )
        do {
            try watchlistRepo.upsert(item)
            refresher.refreshNow()
            return true
        } catch {
            return false
        }
    }

    func isOnWatchlist(_ symbol: SymbolID) -> Bool {
        watchlist.contains(where: { $0.symbol == symbol })
    }

    func deleteWatchItem(_ id: UUID) {
        try? watchlistRepo.delete(id: id)
        refresher.refreshNow()
    }

    deinit {
        observationTask?.cancel()
    }
}
