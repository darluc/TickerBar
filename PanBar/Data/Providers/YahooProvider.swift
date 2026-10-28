import Foundation

/// Yahoo Finance v8 chart 接口实现。
/// 原生支持全天 24h、美股盘前 (Pre-Market) 与盘后 (Post-Market) 数据。
struct YahooProvider: QuoteProvider {
    let id = "yahoo"
    let supportedMarkets: Set<Market> = [.a, .hk, .us]

    let http: HTTPClient

    init(http: HTTPClient = HTTPClient(defaultHeaders: [
        "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko)"
    ])) {
        self.http = http
    }

    func fetch(_ symbols: [SymbolID]) async throws -> [SymbolID: Quote] {
        guard !symbols.isEmpty else { return [:] }

        let chunks = symbols.chunked(by: 8)
        var result: [SymbolID: Quote] = [:]
        for chunk in chunks {
            let pairs = try await withThrowingTaskGroup(of: (SymbolID, Quote?).self) { group in
                for s in chunk {
                    group.addTask { (s, try? await self.fetchOne(s)) }
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

        // includePrePost=true 覆盖盘前、常规盘、盘后与 24h
        let url = URL(string: "https://query1.finance.yahoo.com/v8/finance/chart/\(escaped)?range=1d&interval=5m&includePrePost=true")!
        let data = try await http.fetchData(url: url)
        return try parse(data, symbol: symbol)
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

        // 解析 24h 及美股盘前 / 盘后当前时段
        var extSession: ExtendedSession?
        var extPrice: Decimal?
        var extChange: Decimal?
        var extChangePct: Double?

        let nowSec = Int(Date().timeIntervalSince1970)
        let periods = meta.currentTradingPeriod

        if let pre = periods?.pre, let s = pre.start, let e = pre.end, nowSec >= s && nowSec < e {
            extSession = .preMarket
            if let p = meta.preMarketPrice ?? meta.fulldayPrice {
                extPrice = Decimal(p)
                extChange = meta.preMarketChange.map { Decimal($0) } ?? (Decimal(p) - Decimal(prevClose))
                extChangePct = meta.preMarketChangePercent.map { $0 / 100.0 } ?? ((p - prevClose) / prevClose)
            }
        } else if let post = periods?.post, let s = post.start, let e = post.end, nowSec >= s && nowSec < e {
            extSession = .postMarket
            if let p = meta.postMarketPrice ?? meta.fulldayPrice {
                extPrice = Decimal(p)
                extChange = meta.postMarketChange.map { Decimal($0) } ?? (Decimal(p) - Decimal(prevClose))
                extChangePct = meta.postMarketChangePercent.map { $0 / 100.0 } ?? ((p - prevClose) / prevClose)
            }
        } else if let reg = periods?.regular, let s = reg.start, let e = reg.end, nowSec >= s && nowSec <= e {
            extSession = .regular
        } else if symbol.market == .us {
            // 夜盘 / 24h
            if let p = meta.fulldayPrice, p > 0 {
                extSession = .overnight
                extPrice = Decimal(p)
                extChange = meta.fulldayChange.map { Decimal($0) } ?? (Decimal(p) - Decimal(prevClose))
                extChangePct = meta.fulldayChangePercent.map { $0 / 100.0 } ?? ((p - prevClose) / prevClose)
            }
        }

        // 提取全天分时走势点集
        var sparklinePts: [Double] = []
        if let closes = firstResult.indicators?.quote?.first?.close {
            sparklinePts = closes.compactMap { $0 }
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
