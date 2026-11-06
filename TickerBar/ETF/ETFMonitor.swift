import AppKit
import Combine
import UniformTypeIdentifiers

@MainActor
final class ETFMonitor: ObservableObject {
    @Published var selectedPage = UserDefaults.standard.bool(forKey: "etfPanelSelected") {
        didSet { UserDefaults.standard.set(selectedPage, forKey: "etfPanelSelected") }
    }
    @Published var section = 0
    @Published var paused = false
    @Published private(set) var refreshing = false
    @Published private(set) var error: String?
    @Published private(set) var capture: ETFStore.Capture
    @Published private(set) var history: ETFHistory?
    @Published var selectedCurve = ""
    @Published var selectedFlowDate = ""

    private let service: ETFService
    private let store: ETFStore
    private let clock: MarketClock

    init(service: ETFService = ETFService(), store: ETFStore = ETFStore(), clock: MarketClock = MarketClock()) {
        self.service = service
        self.store = store
        self.clock = clock
        capture = store.loadCapture()
        history = store.loadHistory()
        if let history { // Seed is copied into the user's own archive on first use.
            do { try store.save(history, name: "history.json") }
            catch { self.error = "本地历史保存失败：\(error.localizedDescription)" }
        }
    }

    var day: String {
        capture.quotes.filter { $0.code != "000001" }.map { ETFTime.day($0.timestamp) }.max()
            ?? capture.minutes.values.flatMap { $0.map(\.day) }.max() ?? ""
    }
    var quotes: [ETFSnapshot] {
        capture.quotes.filter { $0.code != "000001" && ETFTime.day($0.timestamp) == day }
            .sorted { $0.amount == $1.amount ? $0.code < $1.code : $0.amount > $1.amount }
    }
    var total: Double { quotes.reduce(0) { $0 + $1.amount } }
    var aggregates: [ETFAggregate] { ETFMath.aggregate(capture.minutes, day: day) }
    var indexMinutes: [ETFMinute] { (capture.minutes["000001"] ?? []).filter { $0.day == day } }
    var minuteMissing: [String] {
        ETFDescriptor.basket.filter { !(capture.minutes[$0.code] ?? []).contains { $0.day == day } }.map(\.code)
    }
    var days: [ETFHistory.Day] {
        var records = Dictionary((history?.days ?? []).map { ($0.date, $0) }, uniquingKeysWith: { _, b in b })
        let dates = Set(capture.daily.values.flatMap { $0.keys })
        for date in dates where date < ETFTime.day(Date()) {
            let values = ETFDescriptor.basket.compactMap { capture.daily[$0.code]?[date] }
            guard values.count == 20 else { continue }
            let old = records[date]
            records[date] = .init(date: date, basketTurnover: values.reduce(0, +),
                                  basketNetFlow: old?.basketNetFlow, broadMarketFlows: old?.broadMarketFlows)
        }
        return records.values.sorted { $0.date < $1.date }
    }
    var flowDays: [ETFHistory.Day] { days.filter { $0.basketNetFlow != nil } }
    var broadDays: [ETFHistory.Day] { days.filter { !($0.broadMarketFlows?.isEmpty ?? true) } }
    var flowDay: ETFHistory.Day? { flowDays.first { $0.date == selectedFlowDate } ?? flowDays.last }
    var curves: [ETFHistory.Curve] {
        var values = Dictionary((history?.curves ?? []).map { ($0.label, $0) }, uniquingKeysWith: { _, b in b })
        let dates = Set(capture.minutes.values.flatMap { $0.map(\.day) }).filter { $0 < day }.sorted()
        for date in dates {
            let points = ETFMath.aggregate(capture.minutes, day: date)
            // Never archive an incomplete trading session as a comparison day.
            // Providers may omit 13:00, while the reference axis resumes at 13:01.
            let canonical = points.filter { $0.slot != 121 }
            guard canonical.first?.slot == 0, canonical.last?.slot == 241,
                  canonical.count == 241, canonical.allSatisfy({ $0.coverage == 20 }) else { continue }
            values[date] = .init(label: date, date: date, startDate: nil, endDate: nil, interpolated: false,
                                points: canonical.map { p in
                let minute = p.slot <= 120 ? p.slot + 570 : p.slot - 121 + 780
                return .init(time: String(format: "%02d:%02d", minute / 60, minute % 60), cumulative: p.cumulative)
            })
        }
        return values.values.sorted { $0.label > $1.label }
    }
    var comparison: ETFHistory.Curve? {
        curves.first { $0.label == selectedCurve } ?? curves.filter { $0.date != nil && ($0.date ?? "") < day }.first
    }
    var average: ETFHistory.Curve? {
        let complete = curves.filter { $0.date != nil && ($0.date ?? "") < day && !$0.interpolated }
            .sorted { ($0.date ?? "") < ($1.date ?? "") }.suffix(20)
        guard complete.count == 20, let first = complete.first, let last = complete.last else {
            return history?.curves.first { $0.date == nil }
        }
        return .init(label: "本地20日均值", date: nil, startDate: first.date, endDate: last.date,
                     interpolated: false, points: first.points.enumerated().map { i, p in
            .init(time: p.time, cumulative: complete.reduce(0) { $0 + $1.points[i].cumulative } / 20)
        })
    }
    var status: String {
        if paused { return "已暂停 · 所有 ETF 自动请求停止" }
        if refreshing { return "采集中…" }
        if let error { return error }
        guard let updated = capture.updated else { return "等待首次采集" }
        let age = Date().timeIntervalSince(updated)
        if day != ETFTime.day(Date()) { return "最近交易数据 \(day) · 非今日" }
        if age > 180 { return "本地缓存 · 上次采集 \(ETFTime.formatter("HH:mm").string(from: updated))" }
        switch clock.status(.a) {
        case .open: return "公开行情 · 60 秒采集 · \(quotes.count)/20"
        case .lunchBreak: return "午间休市 · 已保存本地"
        case .closed: return "时段已结束/未开盘 · 已保存本地"
        }
    }
    func run() async {
        // This task belongs to the visible ETF panel; SwiftUI cancels it on close/switch.
        if !paused { await refresh(automatic: true) }
        while !Task.isCancelled {
            do { try await Task.sleep(nanoseconds: 60_000_000_000) } catch { return }
            guard !Task.isCancelled else { return }
            if !paused && clock.status(.a) == .open { await refresh(automatic: true) }
        }
    }
    func refresh(automatic: Bool = false) async {
        guard !refreshing, !Task.isCancelled, !(automatic && paused) else { return }
        refreshing = true
        error = nil
        defer { refreshing = false }
        var problems: [String] = []
        do {
            let values = try await service.snapshots()
            capture.quotes = values
            capture.updated = Date()
            if quotes.count < 20 { problems.append("快照 \(quotes.count)/20，合计不完整") }
        } catch { problems.append("快照失败，保留本地数据") }

        let targets = ETFDescriptor.basket.map { ($0.code, $0.secid) } + [("000001", "1.000001")]
        // Upstream has no verified batch minute endpoint. Bound concurrency to four.
        var failed = 0
        for start in stride(from: 0, to: targets.count, by: 4) {
            if Task.isCancelled || automatic && paused { break }
            let group = Array(targets[start..<min(start + 4, targets.count)])
            let results = await withTaskGroup(of: (String, [ETFMinute]?).self) { tasks in
                for (code, secid) in group {
                    tasks.addTask { [service] in (code, try? await service.minutes(secid: secid)) }
                }
                var out: [(String, [ETFMinute]?)] = []
                for await value in tasks { out.append(value) }
                return out
            }
            for (code, rows) in results {
                if let rows { capture.minutes[code] = ETFStore.merge(capture.minutes[code] ?? [], rows) }
                else { failed += 1 }
            }
        }
        if failed > 0 { problems.append("\(failed) 路分时失败，保留旧记录") }
        if !Task.isCancelled, !(automatic && paused), capture.dailyUpdated.map({ ETFTime.day($0) != ETFTime.day(Date()) }) ?? true {
            var dailyFailures = 0
            for etf in ETFDescriptor.basket {
                if Task.isCancelled || automatic && paused { break }
                do {
                    let values = try await service.daily(etf)
                    capture.daily[etf.code, default: [:]].merge(values) { _, new in new }
                } catch { dailyFailures += 1 }
            }
            if dailyFailures == 0 && !Task.isCancelled && !(automatic && paused) { capture.dailyUpdated = Date() }
            else { problems.append("日线采集未完成，下次重试") }
        }
        do { try store.save(capture, name: "capture.json") }
        catch { problems.append("本地保存失败：\(error.localizedDescription)") }
        error = problems.isEmpty ? nil : problems.joined(separator: "；")
    }
    func importHistory() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Data(contentsOf: url)
            let value = try ETFHistory.decode(data)
            try store.save(value, name: "history.json")
            history = value
            selectedCurve = ""
            selectedFlowDate = ""
            error = nil
        } catch { self.error = "导入失败：\(error.localizedDescription)" }
    }
    func exportArchive() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "etf-archive-\(ETFTime.day(Date())).json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            struct Archive: Encodable { let capture: ETFStore.Capture; let history: ETFHistory? }
            try JSONEncoder().encode(Archive(capture: capture, history: history)).write(to: url, options: .atomic)
        } catch { self.error = "导出失败：\(error.localizedDescription)" }
    }
}
