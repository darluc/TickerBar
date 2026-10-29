import Foundation

/// Provider 标识。统一 ID 串便于持久化和 UI 显示。
enum ProviderID: String, Codable, CaseIterable, Sendable {
    case tencent
    case eastmoney
    case yahoo
    case finnhub
    case naver
    case binance

    var displayName: String {
        switch self {
        case .tencent:   return "腾讯财经"
        case .eastmoney: return "东方财富"
        case .yahoo:     return "Yahoo Finance"
        case .finnhub:   return "Finnhub"
        case .naver:     return "Naver 财经"
        case .binance:   return "Binance 币安"
        }
    }
}

/// 每市场的 provider 优先级列表 + 启用标志。
struct ProviderPreference: Codable, Equatable, Sendable {
    var order: [ProviderID]
    var enabled: [ProviderID: Bool]

    static let defaults: [Market: ProviderPreference] = [
        .a:  ProviderPreference(order: [.tencent, .eastmoney, .yahoo], enabled: [.tencent: true, .eastmoney: true, .yahoo: false, .finnhub: false, .naver: false, .binance: false]),
        .hk: ProviderPreference(order: [.tencent, .eastmoney, .yahoo], enabled: [.tencent: true, .eastmoney: true, .yahoo: false, .finnhub: false, .naver: false, .binance: false]),
        .us: ProviderPreference(order: [.tencent, .eastmoney, .yahoo, .finnhub], enabled: [.tencent: true, .eastmoney: true, .yahoo: true, .finnhub: false, .naver: false, .binance: false]),
        .kr: ProviderPreference(order: [.naver, .yahoo], enabled: [.naver: true, .yahoo: true, .tencent: false, .eastmoney: false, .finnhub: false, .binance: false]),
        .crypto: ProviderPreference(order: [.binance], enabled: [.binance: true, .yahoo: false, .tencent: false, .eastmoney: false, .finnhub: false, .naver: false])
    ]
}

/// 编排多 provider:按市场拆分 symbols → 按用户设定顺序 fallback。
actor ProviderOrchestrator: QuoteProvider {
    let id = "orchestrator"
    let supportedMarkets: Set<Market> = [.a, .hk, .us, .kr, .crypto]

    private let providers: [ProviderID: QuoteProvider]
    private var preferences: [Market: ProviderPreference]
    private var cooldownUntil: [String: Date] = [:]   // key = "providerID|market"
    private let cooldownDuration: TimeInterval = 30
    private let nasdaq = NasdaqProvider()
    private let robinhood = RobinhoodProvider()

    init(providers: [ProviderID: QuoteProvider], preferences: [Market: ProviderPreference]) {
        self.providers = providers
        self.preferences = preferences
    }

    func updatePreferences(_ prefs: [Market: ProviderPreference]) {
        self.preferences = prefs
    }

    func currentPreferences() -> [Market: ProviderPreference] {
        preferences
    }

    func fetch(_ symbols: [SymbolID]) async throws -> [SymbolID: Quote] {
        // 按市场分桶
        let byMarket = Dictionary(grouping: symbols, by: { $0.market })

        var combined: [SymbolID: Quote] = [:]
        var lastError: Error?

        for (market, marketSymbols) in byMarket {
            do {
                var result = try await fetchForMarket(market, symbols: marketSymbols)
                if market == .us {
                    result = await overlayUSExtended(result, symbols: marketSymbols)
                }
                combined.merge(result, uniquingKeysWith: { _, new in new })
            } catch {
                lastError = error
                Log.quote.warning("market \(market.rawValue, privacy: .public) all providers failed: \(String(describing: error), privacy: .public)")
            }
        }

        if combined.isEmpty, let lastError = lastError {
            throw lastError
        }
        return combined
    }

    private func fetchForMarket(_ market: Market, symbols: [SymbolID]) async throws -> [SymbolID: Quote] {
        let pref = preferences[market] ?? ProviderPreference.defaults[market]!
        let now = Date()
        var lastError: Error?

        let pids = pref.order.filter { pref.enabled[$0] == true }

        for pid in pids {
            guard let provider = providers[pid] else { continue }
            guard provider.supportedMarkets.contains(market) else { continue }

            let cooldownKey = "\(pid.rawValue)|\(market.rawValue)"
            if let until = cooldownUntil[cooldownKey], until > now { continue }

            do {
                let result = try await provider.fetch(symbols)
                if !result.isEmpty {
                    Log.quote.info("market=\(market.rawValue, privacy: .public) provider=\(pid.rawValue, privacy: .public) ok (\(result.count) quotes)")
                    return result
                }
            } catch {
                lastError = error
                cooldownUntil[cooldownKey] = now.addingTimeInterval(cooldownDuration)
                Log.quote.warning("provider \(pid.rawValue, privacy: .public) failed for \(market.rawValue, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }

        if let lastError = lastError {
            throw lastError
        }
        return [:]
    }

    /// 腾讯/Yahoo 常规价之上叠 Robinhood (24h/盘前/盘后) 或 Nasdaq。
    private func overlayUSExtended(_ quotes: [SymbolID: Quote], symbols: [SymbolID]) async -> [SymbolID: Quote] {
        guard MarketClock().status(.us) != .open else { return quotes }
        let need = symbols.filter { $0.market == .us && quotes[$0]?.isExtended != true }
        guard !need.isEmpty else { return quotes }

        // 优先使用原生支持 24h 夜盘 + 盘前盘后的 Robinhood
        do {
            let rhQuotes = try await robinhood.fetch(need)
            if !rhQuotes.isEmpty {
                var out = quotes
                for (sym, rq) in rhQuotes {
                    if let base = out[sym] {
                        out[sym] = base.overlayingExtended(from: rq)
                    } else {
                        out[sym] = rq
                    }
                }
                Log.quote.warning("robinhood 24h overlay success count=\(rhQuotes.count, privacy: .public)")
                return out
            }
        } catch {
            Log.quote.warning("robinhood fetch failed: \(String(describing: error), privacy: .public)")
        }

        // 兜底 Nasdaq (支持盘前 / 盘后)
        do {
            let extra = try await nasdaq.fetch(need)
            guard !extra.isEmpty else { return quotes }
            var out = quotes
            for (sym, nq) in extra {
                if let base = out[sym] {
                    out[sym] = base.overlayingExtended(from: nq)
                } else {
                    out[sym] = nq
                }
            }
            Log.quote.info("nasdaq overlay \(extra.count, privacy: .public) us quotes")
            return out
        } catch {
            Log.quote.warning("extended overlay failed: \(String(describing: error), privacy: .public)")
            return quotes
        }
    }
}
