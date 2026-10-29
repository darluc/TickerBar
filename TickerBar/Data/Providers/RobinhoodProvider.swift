import Foundation

/// Robinhood 实时行情接口。
/// 原生支持美股 24h 全天交易 (Overnight 20:00 - 04:00 ET)、盘前 (04:00 - 09:30 ET) 与盘后 (16:00 - 20:00 ET)。
/// 无需 API Key，URLSession 原生可用，且不会像 Yahoo 那样对桌面端 403。
struct RobinhoodProvider: QuoteProvider {
    let id = "robinhood"
    let supportedMarkets: Set<Market> = [.us]
    var supportsExtendedHours: Bool { true }

    let http: HTTPClient
    private let clock = MarketClock()

    init(http: HTTPClient = RobinhoodProvider.makeHTTP()) {
        self.http = http
    }

    private static func makeHTTP() -> HTTPClient {
        let ua = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
        return HTTPClient(
            session: .shared,
            defaultHeaders: [
                "User-Agent": ua,
                "Accept": "application/json"
            ]
        )
    }

    func fetch(_ symbols: [SymbolID]) async throws -> [SymbolID: Quote] {
        let us = symbols.filter { $0.market == .us }
        guard !us.isEmpty else { return [:] }

        var out: [SymbolID: Quote] = [:]
        try await withThrowingTaskGroup(of: (SymbolID, Quote?).self) { group in
            for s in us {
                group.addTask { (s, try? await self.fetchOne(s)) }
            }
            for try await (s, q) in group {
                if let q { out[s] = q }
            }
        }
        return out
    }

    private func fetchOne(_ symbol: SymbolID) async throws -> Quote? {
        let code = symbol.code.uppercased()
        guard let url = URL(string: "https://api.robinhood.com/marketdata/quotes/\(code)/") else { return nil }
        let data = try await http.fetchData(url: url, timeout: 8)
        return try parse(data, symbol: symbol)
    }

    private func parse(_ data: Data, symbol: SymbolID) throws -> Quote? {
        struct Resp: Decodable {
            let symbol: String?
            let last_trade_price: String?
            let last_extended_hours_trade_price: String?
            let last_non_reg_trade_price: String?
            let previous_close: String?
            let adjusted_previous_close: String?
            let state: String?
        }

        let resp = try JSONDecoder().decode(Resp.self, from: data)
        guard let regPrice = decimal(resp.last_trade_price) else { return nil }
        let prevClose = decimal(resp.previous_close) ?? decimal(resp.adjusted_previous_close) ?? regPrice

        // 判断当前处于哪个时段
        let currentSession = clock.usExtendedSession()
        let nonRegPrice = decimal(resp.last_extended_hours_trade_price) ?? decimal(resp.last_non_reg_trade_price)

        var extPrice: Decimal?
        var extChange: Decimal?
        var extPct: Double?
        var extSession: ExtendedSession?

        if let currentSession, let live = nonRegPrice {
            extSession = currentSession
            extPrice = live
            extChange = live - regPrice
            if regPrice > 0 {
                extPct = ((live - regPrice) as NSDecimalNumber).doubleValue / (regPrice as NSDecimalNumber).doubleValue
            }
        }

        return Quote(
            symbol: symbol,
            name: symbol.code,
            price: regPrice,
            prevClose: prevClose,
            currency: .usd,
            timestamp: Date(),
            isClosed: currentSession != nil,
            extendedPrice: extPrice,
            extendedChange: extChange,
            extendedChangePct: extPct,
            extendedSession: extSession
        )
    }

    private func decimal(_ str: String?) -> Decimal? {
        guard let str, !str.isEmpty else { return nil }
        return Decimal(string: str.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
