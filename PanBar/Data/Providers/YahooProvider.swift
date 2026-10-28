import Foundation

/// Yahoo Finance v8 chart 接口实现。
/// 原生支持全天 24h、美股盘前 (Pre-Market) 与盘后 (Post-Market) 数据。
struct YahooProvider: QuoteProvider {
    let id = "yahoo"
    let supportedMarkets: Set<Market> = [.a, .hk, .us]
    var supportsExtendedHours: Bool { true }

    let http: HTTPClient

    init(http: HTTPClient = YahooProvider.makeHTTP()) {
        self.http = http
    }

    /// Yahoo 会把带 PanBar 标识的 UA 直接 429,用独立 session + 浏览器 UA。
    private static func makeHTTP() -> HTTPClient {
        let ua = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
        let config = URLSessionConfiguration.ephemeral
        config.httpAdditionalHeaders = [
            "User-Agent": ua,
            "Accept": "application/json,text/plain,*/*",
            "Accept-Language": "en-US,en;q=0.9"
        ]
        config.timeoutIntervalForRequest = 12
        return HTTPClient(
            session: URLSession(configuration: config),
            defaultHeaders: [
                "User-Agent": ua,
                "Accept": "application/json",
                "Referer": "https://finance.yahoo.com/"
            ]
        )
    }

    func fetch(_ symbols: [SymbolID]) async throws -> [SymbolID: Quote] {
        guard !symbols.isEmpty else { return [:] }

        let chunks = symbols.chunked(by: 8)
        var result: [SymbolID: Quote] = [:]
        for chunk in chunks {
            let pairs = try await withThrowingTaskGroup(of: (SymbolID, Quote?).self) { group in
                for s in chunk {
                    group.addTask {
                        do {
                            return (s, try await self.fetchOne(s))
                        } catch {
                            Log.quote.warning("yahoo \(s.code, privacy: .public) failed: \(String(describing: error), privacy: .public)")
                            return (s, nil)
                        }
                    }
                }
                var out: [(SymbolID, Quote)] = []
                for try await (s, q) in group {
                    if let q = q { out.append((s, q)) }
                }
                return out
            }
            for (s, q) in pairs {
                result[s] = q
            }
        }
        return result
    }

    private func fetchOne(_ symbol: SymbolID) async throws -> Quote? {
        guard let yahooCode = SymbolEncoder.yahoo(symbol) else { return nil }
        guard let escaped = yahooCode.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else { return nil }

        // query2 对频控更宽松;includePrePost=true 覆盖盘前、常规盘、盘后与 24h
        let hosts = ["query2.finance.yahoo.com", "query1.finance.yahoo.com"]
        var lastError: Error?
        for host in hosts {
            let url = URL(string: "https://\(host)/v8/finance/chart/\(escaped)?range=1d&interval=5m&includePrePost=true")!
            do {
                let data = try await http.fetchData(url: url, timeout: 12)
                if let quote = try parse(data, symbol: symbol) {
                    Log.quote.info("yahoo \(symbol.code, privacy: .public) session=\(quote.extendedSession?.rawValue ?? "nil", privacy: .public) ext=\(quote.extendedPrice.map { "\($0)" } ?? "nil", privacy: .public) last=\(quote.price, privacy: .public)")
                    return quote
                }
            } catch {
                lastError = error
                Log.quote.warning("yahoo \(host, privacy: .public) \(symbol.code, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }
        if let lastError { throw lastError }
        return nil
    }

    private func parse(_ data: Data, symbol: SymbolID) throws -> Quote? {
        struct Resp: Decodable {
            let chart: Chart
            struct Chart: Decodable {
                let result: [Result]?
            }
            struct Result: Decodable {
                let meta: Meta
                let timestamp: [Int]?
                let indicators: Indicators?
            }
            struct Indicators: Decodable {
                let quote: [QuoteObj]?
            }
            struct QuoteObj: Decodable {
                let close: [Double?]?
            }
            struct Meta: Decodable {
                let currency: String?
                let regularMarketPrice: Double?
                let previousClose: Double?
                let chartPreviousClose: Double?
                let regularMarketDayHigh: Double?
                let regularMarketDayLow: Double?
                let regularMarketVolume: Double?
                let longName: String?
                let shortName: String?
                let preMarketPrice: Double?
                let preMarketChange: Double?
                let preMarketChangePercent: Double?
                let postMarketPrice: Double?
                let postMarketChange: Double?
                let postMarketChangePercent: Double?
                let fulldayPrice: Double?
                let fulldayChange: Double?
                let fulldayChangePercent: Double?
                let currentTradingPeriod: TradingPeriodContainer?
            }
            struct TradingPeriodContainer: Decodable {
                let pre: Period?
                let regular: Period?
                let post: Period?
            }
            struct Period: Decodable {
                let start: Int?
                let end: Int?
            }
        }

        let resp = try JSONDecoder().decode(Resp.self, from: data)
        guard let firstResult = resp.chart.result?.first else { return nil }
        let meta = firstResult.meta
        guard let regPrice = meta.regularMarketPrice ?? meta.fulldayPrice else { return nil }
        let prevClose = meta.previousClose ?? meta.chartPreviousClose ?? regPrice
        let currency = Currency(rawValue: meta.currency ?? "") ?? symbol.market.defaultCurrency

        // 提取全天分时(含盘前盘后)走势,末根常是当前扩展时段最新价
        var sparklinePts: [Double] = []
        if let closes = firstResult.indicators?.quote?.first?.close {
            sparklinePts = closes.compactMap { $0 }
        }
        let lastTrade = sparklinePts.last

        // 解析 24h 及美股盘前 / 盘后当前时段。
        // chart meta 通常没有 preMarketPrice,用 fulldayPrice / 末根 K 线;涨跌相对上一笔常规收盘。
        var extSession: ExtendedSession?
        var extPrice: Decimal?
        var extChange: Decimal?
        var extChangePct: Double?

        let nowSec = Int(Date().timeIntervalSince1970)
        let periods = meta.currentTradingPeriod
        let lastRegular = Decimal(regPrice)

        func applyExtended(
            _ session: ExtendedSession,
            price: Double?,
            change: Double?,
            changePct: Double?
        ) {
            let raw = price ?? lastTrade
            guard let raw, raw > 0 else { return }
            extSession = session
            extPrice = Decimal(raw)
            if let change {
                extChange = Decimal(change)
            } else {
                extChange = Decimal(raw) - lastRegular
            }
            if let changePct {
                extChangePct = changePct / 100.0
            } else if lastRegular > 0 {
                extChangePct = ((Decimal(raw) - lastRegular) as NSDecimalNumber).doubleValue
                    / (lastRegular as NSDecimalNumber).doubleValue
            }
        }

        if let pre = periods?.pre, let s = pre.start, let e = pre.end, nowSec >= s && nowSec < e {
            applyExtended(
                .preMarket,
                price: meta.preMarketPrice ?? meta.fulldayPrice,
                change: meta.preMarketChange ?? meta.fulldayChange,
                changePct: meta.preMarketChangePercent ?? meta.fulldayChangePercent
            )
        } else if let post = periods?.post, let s = post.start, let e = post.end, nowSec >= s && nowSec < e {
            applyExtended(
                .postMarket,
                price: meta.postMarketPrice ?? meta.fulldayPrice,
                change: meta.postMarketChange ?? meta.fulldayChange,
                changePct: meta.postMarketChangePercent ?? meta.fulldayChangePercent
            )
        } else if let reg = periods?.regular, let s = reg.start, let e = reg.end, nowSec >= s && nowSec <= e {
            extSession = .regular
        } else if symbol.market == .us {
            applyExtended(
                .overnight,
                price: meta.fulldayPrice,
                change: meta.fulldayChange,
                changePct: meta.fulldayChangePercent
            )
        }

        return Quote(
            symbol: symbol,
            name: meta.longName ?? meta.shortName ?? symbol.code,
            price: Decimal(regPrice),
            prevClose: Decimal(prevClose),
            open: nil,
            high: meta.regularMarketDayHigh.map { Decimal($0) },
            low: meta.regularMarketDayLow.map { Decimal($0) },
            volume: meta.regularMarketVolume.map { Decimal($0) },
            currency: currency,
            timestamp: Date(),
            isClosed: false,
            extendedPrice: extPrice,
            extendedChange: extChange,
            extendedChangePct: extChangePct,
            extendedSession: extSession,
            sparklineHistory: sparklinePts.isEmpty ? nil : sparklinePts
        )
    }
}

private extension Array {
    func chunked(by size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        var result: [[Element]] = []
        var i = 0
        while i < count {
            let end = Swift.min(i + size, count)
            result.append(Array(self[i..<end]))
            i = end
        }
        return result
    }
}
