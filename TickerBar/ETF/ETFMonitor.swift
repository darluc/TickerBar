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
    private(set) var capture = ETFStore.Capture()
    private(set) var history: ETFHistory?
    @Published private(set) var display = ETFPresentation()
    @Published var selectedCurve = ""
    @Published var selectedFlowDate = ""

    private let service: ETFService
    private let worker: ETFDataWorker
    private let clock: MarketClock
    private var loadTask: Task<ETFDataWorker.Prepared, Never>?
    private var loaded = false

    init(service: ETFService = ETFService(), store: ETFStore = ETFStore(), clock: MarketClock = MarketClock()) {
        self.service = service
        self.worker = ETFDataWorker(store: store)
        self.clock = clock
    }

    // Constant-time reads: scrolling, dragging, and changing tabs cannot rebuild history.
    var day: String { display.day }
    var quotes: [ETFSnapshot] { display.quotes }
    var total: Double { display.total }
    var aggregates: [ETFAggregate] { display.aggregates }
    var indexMinutes: [ETFMinute] { display.indexMinutes }
    var minuteMissing: [String] { display.minuteMissing }
    var days: [ETFHistory.Day] { display.days }
    var flowDays: [ETFHistory.Day] { display.flowDays }
    var broadDays: [ETFHistory.Day] { display.broadDays }
    var flowDay: ETFHistory.Day? { display.flowByDate[selectedFlowDate] ?? display.flowDays.last }
    var curves: [ETFHistory.Curve] { display.curves }
    var comparison: ETFHistory.Curve? { display.curveByLabel[selectedCurve] ?? display.defaultComparison }
    var average: ETFHistory.Curve? { display.average }

    private func apply(_ prepared: ETFDataWorker.Prepared) {
        capture = prepared.capture
        history = prepared.history
        display = prepared.display
    }
    private func loadIfNeeded() async {
        guard !loaded else { return }
        if loadTask == nil { loadTask = Task { [worker] in await worker.load() } }
        guard let task = loadTask else { return }
        let prepared = await task.value
        // Several callers may await the same task; publish the initial state once.
        guard !loaded else { return }
        apply(prepared)
        error = prepared.error
        loaded = true
        loadTask = nil
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
        await loadIfNeeded()
        if !paused && !Task.isCancelled { await refresh(automatic: true) }
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
        await loadIfNeeded()
        guard !Task.isCancelled else { return }
        var next = capture
        var problems: [String] = []
        do {
            let values = try await service.snapshots()
            next.quotes = values
            next.updated = Date()
            let prepared = await worker.prepare(capture: next, history: history, persist: false)
            apply(prepared)
            if quotes.count < 20 { problems.append("快照 \(quotes.count)/20，合计不完整") }
        } catch { problems.append("快照失败，保留本地数据") }

        let targets = ETFDescriptor.basket.map { ($0.code, $0.secid) } + [("000001", "1.000001")]
        // Upstream has no verified batch minute endpoint. Bound concurrency to four.
        var failed = 0
        var minuteBatch: [String: [ETFMinute]] = [:]
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
                if let rows { minuteBatch[code] = rows }
                else { failed += 1 }
            }
        }
        if failed > 0 { problems.append("\(failed) 路分时失败，保留旧记录") }
        let minuteState = await worker.prepare(capture: next, history: history, minutes: minuteBatch)
        apply(minuteState)
        next = minuteState.capture
        if let problem = minuteState.error { problems.append(problem) }
        if !Task.isCancelled, !(automatic && paused), next.dailyUpdated.map({ ETFTime.day($0) != ETFTime.day(Date()) }) ?? true {
            var dailyFailures = 0
            for etf in ETFDescriptor.basket {
                if Task.isCancelled || automatic && paused { break }
                do {
                    let values = try await service.daily(etf)
                    next.daily[etf.code, default: [:]].merge(values) { _, new in new }
                } catch { dailyFailures += 1 }
            }
            if dailyFailures == 0 && !Task.isCancelled && !(automatic && paused) { next.dailyUpdated = Date() }
            else { problems.append("日线采集未完成，下次重试") }
        }
        if next.dailyUpdated != capture.dailyUpdated || next.daily.count != capture.daily.count || next.daily != capture.daily {
            let prepared = await worker.prepare(capture: next, history: history)
            apply(prepared)
            if let problem = prepared.error { problems.append(problem) }
        }
        error = problems.isEmpty ? nil : problems.joined(separator: "；")
    }
    func importHistory() {
        guard !refreshing else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        refreshing = true
        Task {
            defer { refreshing = false }
            await loadIfNeeded()
            do {
                let prepared = try await worker.importHistory(url: url, capture: capture)
                apply(prepared)
                selectedCurve = ""
                selectedFlowDate = ""
                error = nil
            } catch { self.error = "导入失败：\(error.localizedDescription)" }
        }
    }
    func exportArchive() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "etf-archive-\(ETFTime.day(Date())).json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            await loadIfNeeded()
            do { try await worker.export(url: url, capture: capture, history: history) }
            catch { self.error = "导出失败：\(error.localizedDescription)" }
        }
    }
}
