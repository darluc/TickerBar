import Foundation

/// Prepared once per data batch, off the main actor. View reads never scan the archive.
struct ETFPresentation: Sendable {
    var day = ""
    var quotes: [ETFSnapshot] = []
    var total = 0.0
    var aggregates: [ETFAggregate] = []
    var indexMinutes: [ETFMinute] = []
    var minuteMissing: [String] = ETFDescriptor.basket.map(\.code)
    var days: [ETFHistory.Day] = []
    var flowDays: [ETFHistory.Day] = []
    var broadDays: [ETFHistory.Day] = []
    var flowByDate: [String: ETFHistory.Day] = [:]
    var curves: [ETFHistory.Curve] = []
    var curveByLabel: [String: ETFHistory.Curve] = [:]
    var defaultComparison: ETFHistory.Curve?
    var average: ETFHistory.Curve?
    var minimumCoverage = 0
    var maximumCoverage = 0
    var broadCumulative: [Cumulative] = []

    struct Cumulative: Identifiable, Sendable {
        let date: String
        let amount: Double
        var id: String { date }
    }

    static func build(capture: ETFStore.Capture, history: ETFHistory?, now: Date = Date()) -> Self {
        var result = Self()
        let today = ETFTime.day(now)
        let formatter = ETFTime.formatter("yyyy-MM-dd")
        let datedQuotes = capture.quotes.filter { $0.code != "000001" }.map { ($0, formatter.string(from: $0.timestamp)) }
        result.day = datedQuotes.map(\.1).max()
            ?? capture.minutes.values.flatMap { $0.map(\.day) }.max() ?? ""
        result.quotes = datedQuotes.filter { $0.1 == result.day }.map(\.0)
            .sorted { $0.amount == $1.amount ? $0.code < $1.code : $0.amount > $1.amount }
        result.total = result.quotes.reduce(0) { $0 + $1.amount }

        // Index the archive by trading day in a single pass, rather than rescanning
        // every stored minute for every curve and every chart property read.
        var byDay: [String: [String: [ETFMinute]]] = [:]
        for (code, rows) in capture.minutes {
            for row in rows { byDay[row.day, default: [:]][code, default: []].append(row) }
        }
        let current = byDay[result.day] ?? [:]
        result.aggregates = ETFMath.aggregate(current, day: result.day)
        result.indexMinutes = current["000001"] ?? []
        result.minuteMissing = ETFDescriptor.basket.filter { current[$0.code]?.isEmpty ?? true }.map(\.code)
        result.minimumCoverage = result.aggregates.map(\.coverage).min() ?? 0
        result.maximumCoverage = result.aggregates.map(\.coverage).max() ?? 0

        var records = Dictionary((history?.days ?? []).map { ($0.date, $0) }, uniquingKeysWith: { _, b in b })
        for date in Set(capture.daily.values.flatMap { $0.keys }) where date < today {
            let values = ETFDescriptor.basket.compactMap { capture.daily[$0.code]?[date] }
            guard values.count == 20 else { continue }
            let old = records[date]
            records[date] = .init(date: date, basketTurnover: values.reduce(0, +),
                                  basketNetFlow: old?.basketNetFlow, broadMarketFlows: old?.broadMarketFlows)
        }
        result.days = records.values.sorted { $0.date < $1.date }
        result.flowDays = result.days.filter { $0.basketNetFlow != nil }
        result.broadDays = result.days.filter { !($0.broadMarketFlows?.isEmpty ?? true) }
        result.flowByDate = Dictionary(result.flowDays.map { ($0.date, $0) }, uniquingKeysWith: { _, b in b })
        var broadTotal = 0.0
        result.broadCumulative = result.broadDays.map { d in
            broadTotal += d.broadMarketFlows?.values.reduce(0, +) ?? 0
            return Cumulative(date: d.date, amount: broadTotal)
        }

        var curves = Dictionary((history?.curves ?? []).map { ($0.label, $0) }, uniquingKeysWith: { _, b in b })
        for (date, series) in byDay where date < result.day {
            let points = ETFMath.aggregate(series, day: date).filter { $0.slot != 121 }
            guard points.first?.slot == 0, points.last?.slot == 241,
                  points.count == 241, points.allSatisfy({ $0.coverage == 20 }) else { continue }
            curves[date] = .init(label: date, date: date, startDate: nil, endDate: nil, interpolated: false,
                                points: points.map { p in
                let minute = p.slot <= 120 ? p.slot + 570 : p.slot - 121 + 780
                return .init(time: String(format: "%02d:%02d", minute / 60, minute % 60), cumulative: p.cumulative)
            })
        }
        result.curves = curves.values.sorted { $0.label > $1.label }
        result.curveByLabel = curves
        result.defaultComparison = result.curves.first { $0.date != nil && ($0.date ?? "") < result.day }
        let complete = result.curves.filter { $0.date != nil && ($0.date ?? "") < result.day && !$0.interpolated }
            .sorted { ($0.date ?? "") < ($1.date ?? "") }.suffix(20)
        result.average = history?.curves.first { $0.date == nil }
        if complete.count == 20, let first = complete.first, let last = complete.last,
           complete.allSatisfy({ $0.points.map(\.time) == first.points.map(\.time) }) {
            result.average = .init(label: "本地20日均值", date: nil, startDate: first.date, endDate: last.date,
                                  interpolated: false, points: first.points.enumerated().map { i, p in
                .init(time: p.time, cumulative: complete.reduce(0) { $0 + $1.points[i].cumulative } / 20)
            })
        }
        return result
    }
}

/// Serial executor for decoding, aggregation, merging, and disk I/O. Never runs on MainActor.
actor ETFDataWorker {
    let store: ETFStore
    init(store: ETFStore) { self.store = store }

    struct Prepared: Sendable {
        let capture: ETFStore.Capture
        let history: ETFHistory?
        let display: ETFPresentation
        let error: String?
    }
    func load() -> Prepared {
        let capture = store.loadCapture()
        let history = store.loadHistory()
        var problem: String?
        if let history, !FileManager.default.fileExists(atPath: store.directory.appendingPathComponent("history.json").path) {
            do { try store.save(history, name: "history.json") }
            catch { problem = "本地历史保存失败：\(error.localizedDescription)" }
        }
        return Prepared(capture: capture, history: history,
                        display: .build(capture: capture, history: history), error: problem)
    }
    func prepare(capture: ETFStore.Capture, history: ETFHistory?, minutes: [String: [ETFMinute]] = [:], persist: Bool = true) -> Prepared {
        var next = capture
        for (code, rows) in minutes { next.minutes[code] = ETFStore.merge(next.minutes[code] ?? [], rows) }
        var problem: String?
        if persist {
            do { try store.save(next, name: "capture.json") }
            catch { problem = "本地保存失败：\(error.localizedDescription)" }
        }
        return Prepared(capture: next, history: history, display: .build(capture: next, history: history), error: problem)
    }
    func importHistory(url: URL, capture: ETFStore.Capture) throws -> Prepared {
        let history = try ETFHistory.decode(Data(contentsOf: url))
        try store.save(history, name: "history.json")
        return prepare(capture: capture, history: history, persist: false)
    }
    func export(url: URL, capture: ETFStore.Capture, history: ETFHistory?) throws {
        struct Archive: Encodable { let capture: ETFStore.Capture; let history: ETFHistory? }
        try JSONEncoder().encode(Archive(capture: capture, history: history)).write(to: url, options: .atomic)
    }
}
