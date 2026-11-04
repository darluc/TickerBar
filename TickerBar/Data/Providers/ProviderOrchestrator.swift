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
    private let sina = SinaProvider()
    private let xueqiu = XueqiuProvider()

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

    /// 腾讯/Yahoo 常规价之上叠 Xueqiu (原生 24h 夜盘 + 盘前盘后) / Sina / Robinhood / Nasdaq 的扩展时段实时报价。
    private func overlayUSExtended(_ quotes: [SymbolID: Quote], symbols: [SymbolID]) async -> [SymbolID: Quote] {
        guard MarketClock().status(.us) != .open else { return quotes }
        let currentSession = MarketClock().usExtendedSession()
        guard currentSession != nil else { return quotes }

        // 如果处于 24h 夜盘时段,即使腾讯返回了 20:00 盘后旧价，也优先让雪球获取 Blue Ocean ATS 实时夜盘价
        let need = symbols.filter { sym in
            sym.market == .us && (currentSession == .overnight || quotes[sym]?.isExtended != true)
        }
        guard !need.isEmpty else { return quotes }

        var out = quotes

        // 1. 优先使用雪球（全天候原生 24h 夜盘 Blue Ocean ATS + 盘前盘后真实成交价）
        do {
            let xqQuotes = try await xueqiu.fetch(need)
            for (sym, xq) in xqQuotes where xq.isExtended {
                if let base = out[sym] {
                    out[sym] = base.overlayingExtended(from: xq)
                } else {
                    out[sym] = xq
                }
            }
            let successCount = out.values.filter { $0.isExtended }.count
            if successCount > 0 {
                Log.quote.info("xueqiu extended overlay success count=\(successCount, privacy: .public)")
                return out
            }
        } catch {
            Log.quote.warning("xueqiu extended fetch failed: \(String(describing: error), privacy: .public)")
        }

        let stillNeed = symbols.filter { $0.market == .us && out[$0]?.isExtended != true }
        guard !stillNeed.isEmpty else { return out }

        // 2. 兜底使用新浪（盘前 / 盘后）
        do {
            let sinaQuotes = try await sina.fetch(stillNeed)
            for (sym, sq) in sinaQuotes where sq.isExtended {
                if let base = out[sym] {
                    out[sym] = base.overlayingExtended(from: sq)
                } else {
                    out[sym] = sq
                }
            }
            let successCount = out.values.filter { $0.isExtended }.count
            if successCount > 0 {
                Log.quote.info("sina extended overlay success count=\(successCount, privacy: .public)")
                return out
            }
        } catch {
            Log.quote.warning("sina extended fetch failed: \(String(describing: error), privacy: .public)")
        }

        // 3. 尝试 Robinhood (如果支持直连或走代理)
        do {
            let rhQuotes = try await robinhood.fetch(stillNeed)
            if !rhQuotes.isEmpty {
                for (sym, rq) in rhQuotes where rq.isExtended {
                    if let base = out[sym] {
                        out[sym] = base.overlayingExtended(from: rq)
                    } else {
                        out[sym] = rq
                    }
                }
                Log.quote.info("robinhood 24h overlay success count=\(rhQuotes.count, privacy: .public)")
                return out
            }
        } catch {
            Log.quote.warning("robinhood fetch failed: \(String(describing: error), privacy: .public)")
        }

        // 4. 兜底 Nasdaq (支持盘前 / 盘后)
        do {
            let extra = try await nasdaq.fetch(stillNeed)
            guard !extra.isEmpty else { return out }
            for (sym, nq) in extra where nq.isExtended {
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
            return out
        }
    }
}
