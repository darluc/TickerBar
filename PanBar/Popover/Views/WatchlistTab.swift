import SwiftUI

struct WatchlistTab: View {
    @EnvironmentObject var vm: PopoverViewModel
    @EnvironmentObject var refresher: QuoteRefresher
    @EnvironmentObject var prefs: TickerPreferences

    /// 当前选中的指示器模式:百分比 / 涨跌额
    @State private var metricMode: MetricMode = .percent

    enum MetricMode {
        case percent
        case amount

        mutating func toggle() {
            self = (self == .percent) ? .amount : .percent
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // 组标签栏: 干净单一的 Watchlist 胶囊 + 右侧添加按钮
            watchlistGroupBar

            ScrollView {
                LazyVStack(spacing: 1) {
                    if vm.watchlist.isEmpty {
                        emptyState
                    } else {
                        ForEach(vm.watchlist) { item in
                            CleanWatchRow(
                                item: item,
                                quote: refresher.quotes[item.symbol],
                                scheme: prefs.colorScheme,
                                metricMode: metricMode,
                                onToggleMetric: {
                                    withAnimation(.easeInOut(duration: 0.16)) {
                                        metricMode.toggle()
                                    }
                                }
                            )
                            .contextMenu {
                                Button(L("action.openInBrowser", comment: "在浏览器中查看")) {
                                    openInBrowser(item.symbol)
                                }
                                Divider()
                                Button(L("action.delete", comment: "删除"), role: .destructive) {
                                    vm.deleteWatchItem(item.id)
                                }
                            }
                            .onTapGesture(count: 2) {
                                openInBrowser(item.symbol)
                            }
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            }
            .frame(maxHeight: .infinity)
        }
    }

    /// Pulse 原版顶部分组栏:单个干净的 Watchlist 胶囊与添加按钮
    private var watchlistGroupBar: some View {
        HStack(spacing: 6) {
            Text("Watchlist")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundColor(.primary)
                .padding(.horizontal, 9)
                .padding(.vertical, 3.5)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(0.08))
                )

            Spacer()

            Button(action: openAddSheet) {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.plain)
            .help(L("watchlist.quickAdd", comment: "添加标的"))
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 4)
    }

    private func openAddSheet() {
        SettingsWindowController.shared.show(initialAction: .addWatch)
    }

    private func openInBrowser(_ symbol: SymbolID) {
        let template = vm.settingsRepo.string(BrowserURLBuilder.templateKey) ?? BrowserURLBuilder.Template.xueqiu.rawValue
        if let url = BrowserURLBuilder.url(template: template, symbol: symbol) {
            NSWorkspace.shared.open(url)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            PulseWaveform()
                .stroke(Color.secondary.opacity(0.35), lineWidth: 1.5)
                .frame(width: 32, height: 18)
                .padding(.top, 24)
            Text(L("watchlist.empty", comment: "暂无自选标的"))
                .font(.system(size: 12))
                .foregroundColor(.secondary)
            Button(L("watchlist.quickAdd", comment: "添加标的")) {
                openAddSheet()
            }
            .controlSize(.small)
            .padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 30)
    }
}

/// 干净整洁的行项目，无大色块底色胶囊，文字优雅自然
private struct CleanWatchRow: View {
    let item: WatchItem
    let quote: Quote?
    let scheme: TickerColorScheme
    let metricMode: WatchlistTab.MetricMode
    let onToggleMetric: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 8) {
            // 左列:标的名称 + 市场徽章 & 代码
            VStack(alignment: .leading, spacing: 2.5) {
                Text(item.name.isEmpty ? item.symbol.code : item.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.primary)
                    .lineLimit(1)

                HStack(spacing: 4) {
                    MarketBadge(market: item.symbol.market)

                    Text(item.symbol.market == .us ? item.symbol.code.uppercased() : item.symbol.code)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundColor(.secondary)
                        .lineLimit(1)

                    // 美股盘前 / 盘后 / 24h 标记
                    if let q = quote, q.isExtended, let session = q.extendedSession {
                        Text(session.label)
                            .font(.system(size: 8.5, weight: .semibold))
                            .foregroundColor(.orange)
                            .padding(.horizontal, 3)
                            .padding(.vertical, 0.5)
                            .background(
                                RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                                    .fill(Color.orange.opacity(0.12))
                            )
                    }
                }
            }
            .frame(width: 96, alignment: .leading)

            // 中列:平滑走势折线图 (Sparkline)
            SparklineView(quote: quote, scheme: scheme, height: 26)
                .frame(maxWidth: .infinity)

            // 右列:最新现价 + 纯文本涨跌幅 (点击切换百分比/金额)
            Button(action: onToggleMetric) {
                VStack(alignment: .trailing, spacing: 2) {
                    if let q = quote {
                        Text(item.symbol.market.defaultCurrency.format(q.effectivePrice))
                            .font(.system(size: 13.5, weight: .bold))
                            .monospacedDigit()
                            .foregroundColor(.primary)
                            .lineLimit(1)

                        let isUp = q.effectiveChange >= 0
                        let textColor = isUp ? SemanticColors.up(scheme: scheme) : SemanticColors.down(scheme: scheme)

                        Text(metricText(q: q))
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundColor(textColor)
                            .lineLimit(1)
                    } else {
                        Text("--")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.secondary)
                        Text("--")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.secondary.opacity(0.6))
                    }
                }
                .frame(width: 72, alignment: .trailing)
            }
            .buttonStyle(.plain)
            .help(L("positions.hint.clickMetric", comment: "点击切换显示指标"))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isHovered ? Color.primary.opacity(0.05) : Color.clear)
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.12)) {
                isHovered = hovering
            }
        }
    }

    private func metricText(q: Quote) -> String {
        switch metricMode {
        case .percent:
            return String(format: "%+.2f%%", q.effectiveChangePct * 100)
        case .amount:
            let sign = q.effectiveChange >= 0 ? "+" : ""
            return sign + item.symbol.market.defaultCurrency.format(q.effectiveChange)
        }
    }
}
