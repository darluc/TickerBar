import SwiftUI
import Charts

struct ETFPanel: View {
    @EnvironmentObject var monitor: ETFMonitor
    @EnvironmentObject var prefs: TickerPreferences

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("宽基 ETF 资金监控").font(.system(size: 16, weight: .semibold))
                    Text("固定 20 只 · 2026-10-15 篮子 · 金额单位：亿元")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 2)
                Button { monitor.paused.toggle() } label: {
                    Image(systemName: monitor.paused ? "play.fill" : "pause.fill")
                }
                .buttonStyle(.plain)
                .help(monitor.paused ? "恢复自动采集" : "暂停所有 ETF 自动采集")
                Menu {
                    Button("导入本地历史 JSON", action: monitor.importHistory)
                    Button("导出完整本地档案", action: monitor.exportArchive)
                } label: { Image(systemName: "externaldrive") }
                .menuStyle(.borderlessButton).frame(width: 20)
            }.padding(.horizontal, 12).padding(.vertical, 8)

            Picker("监控内容", selection: $monitor.section) {
                Text(L("etf.section.intraday", comment: "盘中量能")).tag(0)
                Text(L("etf.section.flows", comment: "申赎与放量")).tag(1)
                Text(L("etf.section.broad", comment: "全市场宽基")).tag(2)
            }.pickerStyle(.segmented).controlSize(.small).padding(.horizontal, 12).padding(.bottom, 8)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if monitor.section == 0 { intraday }
                    else if monitor.section == 1 { flows }
                    else { broadMarket }
                }.padding(12)
            }
        }
        .task { await monitor.run() }
    }

    private func card(_ title: String, _ value: String, _ caption: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 10)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 21, weight: .semibold, design: .rounded)).monospacedDigit()
            Text(caption).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(10)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 9))
    }
    private func money(_ n: Double?) -> String { n.map { String(format: "%.2f", $0 / 1e8) } ?? "—" }
    private func heading(_ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 12, weight: .semibold))
            Text(subtitle).font(.system(size: 9)).foregroundStyle(.secondary)
        }
    }
    private var intraday: some View {
        Group {
            HStack(spacing: 8) {
                card(monitor.quotes.count == 20 ? "篮子成交额" : "已覆盖标的成交额", monitor.quotes.isEmpty ? "—" : money(monitor.total),
                     "快照 \(monitor.day) · \(monitor.quotes.count)/20")
                card("最新申赎净流入", money(monitor.flowDays.last?.basketNetFlow),
                     "\(monitor.flowDays.last?.date ?? "未接入") · 历史申赎，非实时")
            }
            if monitor.quotes.count < 20 || !monitor.minuteMissing.isEmpty {
                Text("数据不完整：快照 \(monitor.quotes.count)/20，分时 \(20 - monitor.minuteMissing.count)/20。部分合计可能低估。")
                    .font(.system(size: 10)).foregroundStyle(.orange)
            }
            heading("分钟成交额", "\(monitor.day) · 各分钟覆盖数 \(monitor.display.minimumCoverage)–\(monitor.display.maximumCoverage)/20 · 拖选查看区间成交额")
            if monitor.aggregates.isEmpty { empty("尚无分时记录，联网采集后保存本地") }
            else {
                minuteChart
            }
            if !monitor.indexMinutes.isEmpty {
                heading("上证综指", "同一交易日、同一时间轴；单独点位轴")
                Chart(monitor.indexMinutes, id: \.stamp) { p in
                    LineMark(x: .value("分钟", p.slot), y: .value("点位", p.close))
                        .foregroundStyle(SemanticColors.pulseBrandCyan)
                }
                .chartYScale(domain: .automatic(includesZero: false))
                .chartXScale(domain: 0...241).chartXAxis { timeAxis }
                .frame(height: 75)
            }
            heading("累计成交额对比", "快照与分钟独立采集，两者合计不必严格相等")
            HStack {
                Text("历史对比").font(.system(size: 10)).foregroundStyle(.secondary)
                Picker("历史对比", selection: $monitor.selectedCurve) {
                    Text("最近历史日").tag("")
                    ForEach(monitor.curves.filter { $0.date != nil }) { curve in Text(curve.label).tag(curve.label) }
                }.labelsHidden().controlSize(.small)
            }
            cumulativeChart
            if let avg = monitor.average {
                Text("\(avg.label)：\(avg.startDate ?? "") — \(avg.endDate ?? "")\(avg.interpolated ? " · 5 分钟线性插值" : " · 本地完整分钟记录")")
                    .font(.system(size: 9)).foregroundStyle(.secondary)
            }
            if let comparison = monitor.comparison {
                Text("对比日期 \(comparison.date ?? "")\(comparison.interpolated ? " · 历史插值" : " · 本地分钟记录")")
                    .font(.system(size: 9)).foregroundStyle(.secondary)
            }
            heading("成交额排名", "占比的分母为当前可用篮子成交额；\(monitor.quotes.count)/20\(monitor.quotes.count < 20 ? "，非完整篮子占比" : "")")
            ranking
        }
    }
    private var minuteChart: some View {
        ETFMinuteChart(points: monitor.aggregates)
    }
    private var cumulativeChart: some View {
        Chart {
            ForEach(monitor.aggregates) { p in
                LineMark(x: .value("分钟", p.slot), y: .value("亿元", p.cumulative / 1e8), series: .value("序列", "当前"))
                    .foregroundStyle(by: .value("序列", "当前"))
            }
            if let c = monitor.comparison {
                ForEach(c.points, id: \.time) { p in
                    LineMark(x: .value("分钟", p.slot), y: .value("亿元", p.cumulative / 1e8), series: .value("序列", "对比日"))
                        .foregroundStyle(by: .value("序列", "对比日"))
                }
            }
            if let c = monitor.average {
                ForEach(c.points, id: \.time) { p in
                    LineMark(x: .value("分钟", p.slot), y: .value("亿元", p.cumulative / 1e8), series: .value("序列", "20日均值"))
                        .foregroundStyle(by: .value("序列", "20日均值"))
                        .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                }
            }
        }.chartXScale(domain: 0...241).chartXAxis { timeAxis }
            .chartForegroundStyleScale(["当前": SemanticColors.pulseBrandBlue, "对比日": .orange, "20日均值": .gray])
            .frame(height: 155)
    }
    private var timeAxis: some AxisContent {
        AxisMarks(values: [0, 60, 120, 181, 241]) { value in
            AxisGridLine().foregroundStyle(.secondary.opacity(0.1))
            AxisValueLabel {
                if let n = value.as(Int.self) {
                    Text([0: "09:30", 60: "10:30", 120: "11:30", 181: "14:00", 241: "15:00"][n] ?? "")
                        .font(.system(size: 8))
                }
            }
        }
    }
    private var ranking: some View {
        VStack(spacing: 3) {
            HStack {
                Text("ETF").frame(maxWidth: .infinity, alignment: .leading)
                Text("成交额").frame(width: 68, alignment: .trailing)
                Text("占比").frame(width: 50, alignment: .trailing)
                Text("涨跌幅").frame(width: 56, alignment: .trailing)
            }.font(.system(size: 9)).foregroundStyle(.secondary)
            ForEach(monitor.quotes, id: \.code) { quote in
                let descriptor = ETFDescriptor.basket.first { $0.code == quote.code }
                HStack(spacing: 4) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(descriptor?.name ?? quote.code).font(.system(size: 10, weight: .medium)).lineLimit(1)
                        Text("\(quote.code) · \(ETFTime.formatter("HH:mm").string(from: quote.timestamp))")
                            .font(.system(size: 8, design: .monospaced)).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    Text(money(quote.amount)).frame(width: 68, alignment: .trailing)
                    Text(monitor.total > 0 ? String(format: "%.1f%%", quote.amount / monitor.total * 100) : "—")
                        .frame(width: 50, alignment: .trailing)
                    Text(quote.changePercent.map { String(format: "%+.2f%%", $0) } ?? "—")
                        .foregroundStyle(SemanticColors.directional(quote.changePercent ?? 0, scheme: prefs.colorScheme))
                        .frame(width: 56, alignment: .trailing)
                }
                .font(.system(size: 10, design: .monospaced)).monospacedDigit().padding(.vertical, 5).padding(.horizontal, 4)
                .background(alignment: .leading) {
                    GeometryReader { geo in
                        RoundedRectangle(cornerRadius: 4).fill(SemanticColors.pulseBrandBlue.opacity(0.07))
                            .frame(width: geo.size.width * quote.amount / max(monitor.quotes.first?.amount ?? 1, 1))
                    }
                }
            }
        }
    }
    private var flows: some View {
        Group {
            heading("20 只篮子 · 日度申赎", "T-1/历史数据；成交额不能推算申赎净流入")
            if let latest = monitor.flowDays.last {
                card("最近申赎净流入", money(latest.basketNetFlow), "数据所属日期 \(latest.date) · 原站种子")
                Text("申赎数据截至 \(latest.date)，此后日期尚无申赎记录；本地日线采集仅更新成交额。")
                    .font(.system(size: 10)).foregroundStyle(.orange)
                heading("近 60 个有记录交易日", "放量信号 = 日度申赎净流入 > 100 亿元")
                Chart(Array(monitor.flowDays.suffix(60))) { d in
                    BarMark(x: .value("日期", d.date), y: .value("净流入", (d.basketNetFlow ?? 0) / 1e8))
                        .foregroundStyle(SemanticColors.directional(d.basketNetFlow ?? 0, scheme: prefs.colorScheme))
                }.chartXAxis(.hidden).frame(height: 150)
                Picker("查看日期", selection: $monitor.selectedFlowDate) {
                    Text("最新记录").tag("")
                    ForEach(monitor.flowDays.reversed()) { day in Text(day.date).tag(day.date) }
                }.controlSize(.small)
                if let day = monitor.flowDay {
                    HStack(spacing: 8) {
                        card("当日成交额", money(day.basketTurnover), day.date)
                        card("当日申赎净流入", money(day.basketNetFlow), day.isSignal ? "超过 100 亿 · 放量信号" : "未超过 100 亿")
                    }
                }
                if let samples = monitor.history?.samples {
                    heading("原站预计算样本", "日度 \(samples.dailyCount) 日 · 成交额中位数 \(money(samples.turnoverMedian)) 亿")
                    Text("分钟案例：\(samples.signalCount) 个放量日 / \(samples.normalCount) 个常态日，\(samples.startDate) — \(samples.endDate)。与日度样本集合不同。\n日度样本排除：\(samples.excluded)")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
            } else { empty("本地还没有申赎历史") }
            provenance
        }
    }
    private var broadMarket: some View {
        Group {
            heading("全市场宽基 · 分类净流入", "独立统计范围，合计不等于固定 20 只篮子")
            if let latest = monitor.broadDays.last, let categories = latest.broadMarketFlows {
                card("全市场宽基净流入", money(categories.values.reduce(0, +)), "数据所属日期 \(latest.date) · 原站种子")
                let chartDays = Array(monitor.broadDays.suffix(30))
                Chart {
                    ForEach(chartDays) { d in
                        ForEach((d.broadMarketFlows ?? [:]).keys.sorted(), id: \.self) { cat in
                            BarMark(x: .value("日期", d.date), y: .value("亿元", (d.broadMarketFlows?[cat] ?? 0) / 1e8))
                                .foregroundStyle(by: .value("分类", cat))
                        }
                    }
                }.chartXAxis(.hidden).chartLegend(.hidden).frame(height: 155)
                heading("累计净流入", "从 \(monitor.broadDays.first?.date ?? "") 起累计；单位：亿元")
                broadCumulative
                ForEach(categories.keys.sorted(), id: \.self) { cat in
                    HStack {
                        Text(cat)
                        Spacer()
                        Text(money(categories[cat])).monospacedDigit()
                            .foregroundStyle(SemanticColors.directional(categories[cat] ?? 0, scheme: prefs.colorScheme))
                    }.font(.system(size: 11)).padding(.vertical, 3)
                }
            } else { empty("本地还没有全市场宽基历史") }
            provenance
        }
    }
    private var broadCumulative: some View {
        Chart(monitor.display.broadCumulative) { p in
            LineMark(x: .value("日期", p.date), y: .value("累计亿元", p.amount / 1e8))
                .foregroundStyle(SemanticColors.pulseBrandBlue)
        }.chartXAxis(.hidden).frame(height: 100)
    }
    private var provenance: some View {
        Text("\(monitor.history?.source ?? "未接入")。历史数值独立保存在本地；种子后续不自动更新申赎数据。")
            .font(.system(size: 9)).foregroundStyle(.secondary)
    }
    private func empty(_ text: String) -> some View {
        Text(text).font(.system(size: 11)).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 70)
    }
}

/// Keep pointer-frequency selection updates inside this chart, not the whole panel.
private struct ETFMinuteChart: View {
    let points: [ETFAggregate]
    @State private var selection: ClosedRange<Int>?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Chart(points) { p in
                BarMark(x: .value("分钟", p.slot), y: .value("成交额", p.amount / 1e8))
                    .foregroundStyle(p.coverage == 20 ? SemanticColors.pulseBrandBlue : .orange)
            }
            .chartXScale(domain: 0...241)
            .chartXAxis {
                AxisMarks(values: [0, 60, 120, 181, 241]) { value in
                    AxisGridLine().foregroundStyle(.secondary.opacity(0.1))
                    AxisValueLabel {
                        if let n = value.as(Int.self) {
                            Text([0: "09:30", 60: "10:30", 120: "11:30", 181: "14:00", 241: "15:00"][n] ?? "")
                                .font(.system(size: 8))
                        }
                    }
                }
            }
            .frame(height: 125)
            .chartOverlay { proxy in
                GeometryReader { geo in
                    Rectangle().fill(.clear).contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 3).onChanged { value in
                            let origin = geo[proxy.plotAreaFrame].origin.x
                            if let a: Int = proxy.value(atX: value.startLocation.x - origin),
                               let b: Int = proxy.value(atX: value.location.x - origin) {
                                let lower = max(0, min(241, min(a, b)))
                                let upper = max(0, min(241, max(a, b)))
                                let range = lower...upper
                                if range != selection { selection = range }
                            }
                        })
                }
            }
            if let selection {
                let rows = points.filter { selection.contains($0.slot) }
                let amount = rows.reduce(0) { $0 + $1.amount } / 1e8
                Text("选区成交额 \(String(format: "%.2f", amount)) 亿 · 最低覆盖 \(rows.map(\.coverage).min() ?? 0)/20")
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
            }
        }
    }
}
