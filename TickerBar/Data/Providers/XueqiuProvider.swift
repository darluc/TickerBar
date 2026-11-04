import Foundation

/// 雪球行情接口实现。
/// 原生支持美股 24h 夜盘（Blue Ocean ATS）、盘前（Pre-Market）与盘后（Post-Market）真实成交行情。
/// 支持单次批量多标的查询，直连稳定极速（<200ms），无需配置任何 Key。
struct XueqiuProvider: QuoteProvider {
    let id = "xueqiu"
    let supportedMarkets: Set<Market> = [.us]
    var supportsExtendedHours: Bool { true }

    let http: HTTPClient
    private let clock = MarketClock()

    init(http: HTTPClient = XueqiuProvider.makeHTTP()) {
        self.http = http
    }

    private static func makeHTTP() -> HTTPClient {
        HTTPClient(
            defaultHeaders: [
                "Referer": "https://xueqiu.com/",
                "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
            ]
        )
    }

    private func ensureCookie() async {
        guard let url = URL(string: "https://xueqiu.com/") else { return }
        _ = try? await http.fetchData(url: url, timeout: 5)
    }

    func fetch(_ symbols: [SymbolID]) async throws -> [SymbolID: Quote] {
        let us = symbols.filter { $0.market == .us }
        guard !us.isEmpty else { return [:] }

        await ensureCookie()

        let symList = us.map { $0.code.uppercased() }.joined(separator: ",")
        guard let url = URL(string: "https://stock.xueqiu.com/v5/stock/batch/quote.json?symbol=\(symList)&extend=detail") else {
            throw ProviderError.empty
        }

        do {
            let data = try await http.fetchData(url: url, timeout: 5)
            return try parse(data, symbols: us)
        } catch {
            // 如果遇到 cookie 失效，刷新 cookie 重试一次
            await ensureCookie()
            let data = try await http.fetchData(url: url, timeout: 5)
            return try parse(data, symbols: us)
        }
    }

    private func parse(_ data: Data, symbols: [SymbolID]) throws -> [SymbolID: Quote] {
        struct Resp: Decodable {
            let data: DataBlock?
            struct DataBlock: Decodable {
                let items: [Item]?
            }
            struct Item: Decodable {
                let quote: QuoteBlock?
            }
            struct QuoteBlock: Decodable {
                let symbol: String?
                let name: String?
                let current: Double?
                let last_close: Double?
                let open: Double?
                let high: Double?
                let low: Double?
                let volume: Double?
                let current_ext: Double?
                let chg_ext: Double?
                let percent_ext: Double?
                let current_night_session: Double?
                let chg_night_session: Double?
                let percent_night_session: Double?
            }
        }

        let decoded = try JSONDecoder().decode(Resp.self, from: data)
        let items = decoded.data?.items ?? []
        let symbolMap = Dictionary(uniqueKeysWithValues: symbols.map { ($0.code.uppercased(), $0) })
        let currentSession = clock.usExtendedSession()

        var result: [SymbolID: Quote] = [:]

        for item in items {
            guard let q = item.quote,
                  let code = q.symbol?.uppercased(),
                  let symbolID = symbolMap[code],
                  let regPriceVal = q.current, regPriceVal > 0 else { continue }

            let regularPrice = Decimal(regPriceVal)
            let prevClose = Decimal(q.last_close ?? regPriceVal)
            let open = q.open.map { Decimal($0) }
            let high = q.high.map { Decimal($0) }
            let low = q.low.map { Decimal($0) }
            let volume = q.volume.map { Decimal($0) }

            var extPrice: Decimal?
            var extChange: Decimal?
            var extPct: Double?
            var extSession: ExtendedSession?

            if currentSession == .overnight, let night = q.current_night_session, night > 0 {
                extSession = .overnight
                extPrice = Decimal(night)
                extChange = q.chg_night_session.map { Decimal($0) } ?? (Decimal(night) - regularPrice)
                extPct = (q.percent_night_session ?? 0) / 100.0
            } else if let ext = q.current_ext, ext > 0, currentSession != nil {
                extSession = currentSession
                extPrice = Decimal(ext)
                extChange = q.chg_ext.map { Decimal($0) } ?? (Decimal(ext) - regularPrice)
                extPct = (q.percent_ext ?? 0) / 100.0
            }

            result[symbolID] = Quote(
                symbol: symbolID,
                name: q.name ?? symbolID.code,
                price: regularPrice,
                prevClose: prevClose,
                open: open,
                high: high,
                low: low,
                volume: volume,
                currency: .usd,
                timestamp: Date(),
                isClosed: currentSession != nil,
                extendedPrice: extPrice,
                extendedChange: extChange,
                extendedChangePct: extPct,
                extendedSession: extSession
            )
        }
        return result
    }
}
