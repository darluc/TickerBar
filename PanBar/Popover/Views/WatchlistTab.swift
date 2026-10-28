import SwiftUI

struct WatchlistTab: View {
    @EnvironmentObject var vm: PopoverViewModel
    @EnvironmentObject var refresher: QuoteRefresher
    @EnvironmentObject var prefs: TickerPreferences

    var onRequestAdd: () -> Void = {}

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

            Button(action: onRequestAdd) {
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
                onRequestAdd()
            }
            .controlSize(.small)
            .padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 30)
    }
}

/// 双行报价:常规盘大字着色 + 盘前/盘后小字,对齐常见行情软件。
private struct CleanWatchRow: View {
    let item: WatchItem
    let quote: Quote?
    let scheme: TickerColorScheme
    let metricMode: WatchlistTab.MetricMode
    let onToggleMetric: () -> Void

    @State private var isHovered = false

    private var code: String {
        item.symbol.market == .us ? item.symbol.code.uppercased() : item.symbol.code
    }

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    MarketBadge(market: item.symbol.market)
                    Text(item.name.isEmpty ? code : item.name)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                }
                Text(code)
                    .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                    .foregroundColor(.secondary)
                    .padding(.leading, 2)
            }
            .frame(width: 108, alignment: .leading)

            SparklineView(quote: quote, scheme: scheme, height: 28)
                .frame(maxWidth: .infinity)

            Button(action: onToggleMetric) {
                if let q = quote {
                    quotesColumn(q)
                } else {
                    VStack(alignment: .trailing, spacing: 3) {
                        Text("--")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.secondary)
                        Text("--")
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundColor(.secondary.opacity(0.55))
                    }
                }
            }
            .buttonStyle(.plain)
            .help(L("positions.hint.clickMetric", comment: "点击切换显示指标"))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
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

    @ViewBuilder
    private func quotesColumn(_ q: Quote) -> some View {
        let regularUp = q.change >= 0
        let regularColor = regularUp ? SemanticColors.up(scheme: scheme) : SemanticColors.down(scheme: scheme)
        let showExtended = q.isExtended

        VStack(alignment: .trailing, spacing: 3) {
            HStack(spacing: 6) {
                Text(formatPrice(q.price))
                    .font(.system(size: 14, weight: .bold))
                    .monospacedDigit()
                    .foregroundColor(regularColor)
                    .lineLimit(1)
                changePill(
                    text: metricText(pct: q.changePct, amount: q.change),
                    color: regularColor
                )
            }

            if showExtended {
                HStack(spacing: 5) {
                    Text(formatPrice(q.effectivePrice))
                        .font(.system(size: 11, weight: .medium))
                        .monospacedDigit()
                        .foregroundColor(.secondary)
                    Text(metricText(pct: q.effectiveChangePct, amount: q.effectiveChange))
                        .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                        .foregroundColor(.secondary)
                    if let session = q.extendedSession {
                        Text(session.shortLabel)
                            .font(.system(size: 8.5, weight: .semibold))
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .overlay(
                                RoundedRectangle(cornerRadius: 3, style: .continuous)
                                    .stroke(Color.secondary.opacity(0.35), lineWidth: 0.8)
                            )
                    }
                }
                .lineLimit(1)
            }
        }
        .frame(minWidth: 118, alignment: .trailing)
    }

    private func changePill(text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 10.5, weight: .bold, design: .monospaced))
            .foregroundColor(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2.5)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(color)
            )
    }

    private func formatPrice(_ value: Decimal) -> String {
        item.symbol.market.defaultCurrency.format(value)
    }

    private func metricText(pct: Double, amount: Decimal) -> String {
        switch metricMode {
        case .percent:
            return String(format: "%+.2f%%", pct * 100)
        case .amount:
            let sign = amount >= 0 ? "+" : ""
            return sign + formatPrice(amount)
        }
    }
}
