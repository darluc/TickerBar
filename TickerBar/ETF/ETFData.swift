import Foundation

struct ETFDescriptor: Identifiable {
    let code: String
    let name: String
    let index: String
    var id: String { code }
    var secid: String { "\(code.hasPrefix("15") ? 0 : 1).\(code)" }

    // Fixed basket, adjusted 2026-10-15. Never replace with turnover leaders.
    static let basket: [ETFDescriptor] = [
        .init(code: "510310", name: "沪深300ETF易方达", index: "沪深300"),
        .init(code: "510300", name: "沪深300ETF华泰柏瑞", index: "沪深300"),
        .init(code: "159919", name: "沪深300ETF嘉实", index: "沪深300"),
        .init(code: "563360", name: "A500ETF华泰柏瑞", index: "中证A500"),
        .init(code: "159352", name: "A500ETF南方", index: "中证A500"),
        .init(code: "159338", name: "中证A500ETF国泰", index: "中证A500"),
        .init(code: "159361", name: "A500ETF易方达", index: "中证A500"),
        .init(code: "512050", name: "A500ETF华夏", index: "中证A500"),
        .init(code: "512100", name: "中证1000ETF南方", index: "中证1000"),
        .init(code: "159845", name: "中证1000ETF华夏", index: "中证1000"),
        .init(code: "159633", name: "中证1000ETF易方达", index: "中证1000"),
        .init(code: "560010", name: "中证1000ETF广发", index: "中证1000"),
        .init(code: "588000", name: "科创50ETF华夏", index: "科创50"),
        .init(code: "588080", name: "科创50ETF易方达", index: "科创50"),
        .init(code: "159915", name: "创业板ETF易方达", index: "创业板指"),
        .init(code: "159952", name: "创业板ETF广发", index: "创业板指"),
        .init(code: "510500", name: "中证500ETF南方", index: "中证500"),
        .init(code: "159949", name: "创业板50ETF华安", index: "创业板50"),
        .init(code: "510050", name: "上证50ETF华夏", index: "上证50"),
        .init(code: "510210", name: "上证指数ETF富国", index: "上证指数")
    ]
}

enum ETFTime {
    static func formatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        f.dateFormat = format
        f.isLenient = false
        return f
    }
    static func day(_ date: Date) -> String { formatter("yyyy-MM-dd").string(from: date) }
    static func validDay(_ day: String) -> Bool {
        let a = Array(day.utf8)
        guard a.count == 10, a[4] == 45, a[7] == 45,
              a.enumerated().allSatisfy({ [4, 7].contains($0.offset) || (48...57).contains($0.element) }),
              let y = Int(day.prefix(4)), let m = Int(day.dropFirst(5).prefix(2)), let d = Int(day.suffix(2)),
              y >= 1900, (1...12).contains(m) else { return false }
        let leap = y % 400 == 0 || y % 4 == 0 && y % 100 != 0
        return (1...[31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31][m - 1]).contains(d)
    }
    /// Trading-session coordinate; lunch occupies no chart space.
    static func slot(_ stamp: String) -> Int? {
        guard stamp.count == 16, validDay(String(stamp.prefix(10))), stamp.dropFirst(10).first == " " else { return nil }
        let time = stamp.suffix(5).split(separator: ":").compactMap { Int($0) }
        guard time.count == 2, (0...23).contains(time[0]), (0...59).contains(time[1]) else { return nil }
        let m = time[0] * 60 + time[1]
        if (570...690).contains(m) { return m - 570 }
        if (780...900).contains(m) { return m - 780 + 121 }
        return nil
    }
}

struct ETFSnapshot: Codable, Sendable {
    let code: String
    let amount: Double // CNY, never net inflow
    let changePercent: Double?
    let timestamp: Date
}

struct ETFMinute: Codable, Sendable {
    let stamp: String // Shanghai yyyy-MM-dd HH:mm
    let close: Double
    let amount: Double
    var day: String { String(stamp.prefix(10)) }
    var slot: Int { ETFTime.slot(stamp) ?? 0 }
}

struct ETFAggregate: Identifiable, Sendable {
    let slot: Int
    let amount: Double
    let cumulative: Double
    let coverage: Int
    var id: Int { slot }
}

enum ETFMath {
    static func aggregate(_ series: [String: [ETFMinute]], day: String) -> [ETFAggregate] {
        var bySlot: [Int: [String: Double]] = [:]
        let codes = Set(ETFDescriptor.basket.map(\.code))
        for (code, rows) in series where codes.contains(code) {
            for row in rows where row.day == day {
                bySlot[row.slot, default: [:]][code] = row.amount
            }
        }
        var cumulative = 0.0
        return bySlot.keys.sorted().map { slot in
            let values = bySlot[slot]!
            let amount = values.values.reduce(0, +)
            cumulative += amount
            return ETFAggregate(slot: slot, amount: amount, cumulative: cumulative, coverage: values.count)
        }
    }
}

/// Explicit exchange format for offline research data; all monetary values are CNY.
/// No executable JavaScript is imported and no turnover-to-flow estimation is performed.
struct ETFHistory: Codable, Sendable {
    let version: Int
    let source: String
    let basketCodes: [String]
    let days: [Day]
    let curves: [Curve]
    var samples: Samples? = nil
    struct Samples: Codable, Sendable {
        let dailyCount: Int
        let turnoverMedian: Double
        let excluded: String
        let signalCount: Int
        let normalCount: Int
        let startDate: String
        let endDate: String
    }
    struct Day: Codable, Identifiable, Sendable {
        let date: String
        let basketTurnover: Double?
        let basketNetFlow: Double?
        let broadMarketFlows: [String: Double]?
        var id: String { date }
        var isSignal: Bool { (basketNetFlow ?? -.infinity) > 100 * 1e8 }
    }
    struct Curve: Codable, Identifiable, Sendable {
        let label: String
        let date: String?
        let startDate: String?
        let endDate: String?
        let interpolated: Bool
        let points: [Point]
        var id: String { label }
    }
    struct Point: Codable, Sendable {
        let time: String
        let cumulative: Double
        var slot: Int { ETFTime.slot("2000-01-01 " + time) ?? 0 }
    }
    static func decode(_ data: Data) throws -> ETFHistory {
        let h = try JSONDecoder().decode(Self.self, from: data)
        let expected = Set(ETFDescriptor.basket.map(\.code))
        func validDay(_ day: String) -> Bool {
            ETFTime.validDay(day)
        }
        guard h.version == 1, !h.source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              h.basketCodes.count == 20, Set(h.basketCodes) == expected,
              Set(h.days.map(\.date)).count == h.days.count,
              Set(h.curves.map(\.label)).count == h.curves.count,
              h.days.allSatisfy({ d in
                  validDay(d.date) && (d.basketTurnover.map { $0.isFinite && $0 >= 0 } ?? true)
                  && (d.basketNetFlow?.isFinite ?? true)
                  && (d.broadMarketFlows?.allSatisfy { !$0.key.isEmpty && $0.value.isFinite } ?? true)
              }),
              h.curves.allSatisfy({ c in
                  !c.label.isEmpty && !c.points.isEmpty
                  && ((c.date.map(validDay) ?? false) || ((c.startDate.map(validDay) ?? false) && (c.endDate.map(validDay) ?? false) && c.startDate! <= c.endDate!))
                  && c.points.allSatisfy { ETFTime.slot("2000-01-01 " + $0.time) != nil && $0.cumulative.isFinite && $0.cumulative >= 0 }
                  && zip(c.points, c.points.dropFirst()).allSatisfy { $0.slot < $1.slot && $0.cumulative <= $1.cumulative }
              }) else { throw ETFDataError.invalidHistory }
        return h
    }
}

enum ETFDataError: LocalizedError {
    case invalidResponse, invalidHistory
    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "行情响应无有效数据"
        case .invalidHistory: return "历史文件格式、篮子或数值不符合要求，请查看 docs/ETF-HISTORY.md"
        }
    }
}
