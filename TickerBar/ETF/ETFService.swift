import Foundation

struct ETFService {
    let http: HTTPClient
    init(http: HTTPClient = HTTPClient(defaultHeaders: ["Referer": "https://quote.eastmoney.com/"])) {
        self.http = http
    }
    func get(_ host: String, _ path: String, _ query: [String: String]) async throws -> [String: Any] {
        var url = URLComponents(string: "https://\(host)/api/qt/\(path)")!
        url.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        let data = try await http.fetchData(url: url.url!, timeout: 12)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let body = root["data"] as? [String: Any] else { throw ETFDataError.invalidResponse }
        return body
    }
    static func number(_ value: Any?) -> Double? {
        let n: Double?
        if let value = value as? NSNumber { n = value.doubleValue }
        else if let value = value as? String { n = Double(value) }
        else { n = nil }
        return n.flatMap { $0.isFinite ? $0 : nil }
    }
    func snapshots() async throws -> [ETFSnapshot] {
        let body = try await get("push2.eastmoney.com", "ulist.np/get", [
            "fltt": "2", "invt": "2", "fields": "f12,f13,f2,f3,f6,f18,f124",
            "secids": (ETFDescriptor.basket.map(\.secid) + ["1.000001"]).joined(separator: ",")
        ])
        let values = Self.parseSnapshots(body)
        guard !values.isEmpty else { throw ETFDataError.invalidResponse }
        return values
    }
    static func parseSnapshots(_ body: [String: Any]) -> [ETFSnapshot] {
        let allowed = Set(ETFDescriptor.basket.map(\.code) + ["000001"])
        return (body["diff"] as? [[String: Any]] ?? []).compactMap { row in
            guard let code = row["f12"] as? String, allowed.contains(code),
                  let amount = number(row["f6"]), amount >= 0,
                  let stamp = number(row["f124"]), stamp > 0 else { return nil }
            return ETFSnapshot(code: code, amount: amount, changePercent: number(row["f3"]), timestamp: Date(timeIntervalSince1970: stamp))
        }
    }
    func minutes(secid: String) async throws -> [ETFMinute] {
        let body = try await get("push2.eastmoney.com", "stock/trends2/get", [
            "secid": secid, "fields1": "f1,f2,f3,f4,f5,f6,f7",
            "fields2": "f51,f52,f53,f54,f55,f56,f57,f58", "ndays": "5", "iscr": "0"
        ])
        let rows = Self.parseMinutes(body["trends"] as? [String] ?? [])
        guard !rows.isEmpty else { throw ETFDataError.invalidResponse }
        return rows
    }
    static func parseMinutes(_ rows: [String]) -> [ETFMinute] {
        var unique: [String: ETFMinute] = [:]
        for row in rows {
            let f = row.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 7, ETFTime.slot(f[0]) != nil,
                  let close = Double(f[2]), close.isFinite, close > 0,
                  let amount = Double(f[6]), amount.isFinite, amount >= 0 else { continue }
            unique[f[0]] = ETFMinute(stamp: f[0], close: close, amount: amount)
        }
        return unique.values.sorted { $0.stamp < $1.stamp }
    }
    func daily(_ etf: ETFDescriptor) async throws -> [String: Double] {
        let body = try await get("push2his.eastmoney.com", "stock/kline/get", [
            "secid": etf.secid, "klt": "101", "fqt": "0", "lmt": "65", "end": "20500101",
            "fields1": "f1,f2,f3,f4,f5,f6", "fields2": "f51,f52,f53,f54,f55,f56,f57,f58,f59,f60,f61"
        ])
        var out: [String: Double] = [:]
        for row in body["klines"] as? [String] ?? [] {
            let f = row.split(separator: ",").map(String.init)
            if f.count >= 7, ETFTime.formatter("yyyy-MM-dd").date(from: f[0]) != nil,
               let value = Double(f[6]), value.isFinite, value >= 0 { out[f[0]] = value }
        }
        guard !out.isEmpty else { throw ETFDataError.invalidResponse }
        return out
    }
}

/// Local, versioned archive. Never holds credentials or calls the reference website.
struct ETFStore {
    let directory: URL
    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TickerBar/ETF", isDirectory: true)
    }
    struct Capture: Codable {
        var quotes: [ETFSnapshot] = []
        var minutes: [String: [ETFMinute]] = [:]
        var daily: [String: [String: Double]] = [:]
        var updated: Date?
        var dailyUpdated: Date?
    }
    func loadCapture() -> Capture {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("capture.json")),
              let capture = try? JSONDecoder().decode(Capture.self, from: data) else { return Capture() }
        return capture
    }
    func loadHistory() -> ETFHistory? {
        if let data = try? Data(contentsOf: directory.appendingPathComponent("history.json")),
           let h = try? ETFHistory.decode(data) { return h }
        guard let url = Bundle.main.url(forResource: "etf-history-seed", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? ETFHistory.decode(data)
    }
    func save<T: Encodable>(_ object: T, name: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(object).write(to: directory.appendingPathComponent(name), options: .atomic)
    }
    static func merge(_ previous: [ETFMinute], _ incoming: [ETFMinute]) -> [ETFMinute] {
        var rows = Dictionary(previous.map { ($0.stamp, $0) }, uniquingKeysWith: { _, b in b })
        for row in incoming { rows[row.stamp] = row }
        return rows.values.sorted { $0.stamp < $1.stamp }
    }
}
