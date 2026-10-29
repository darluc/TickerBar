import SwiftUI

struct TickerPane: View {
    @Environment(\.container) private var container

    var body: some View {
        if let container = container {
            TickerPaneContent(container: container, prefs: container.tickerPrefs)
        } else {
            Text(L("loading", comment: "加载中..."))
        }
    }
}

private struct TickerPaneContent: View {
    let container: DependencyContainer
    @ObservedObject var prefs: TickerPreferences

    @State private var watchlist: [WatchItem] = []

    var body: some View {
        Form {
            Section(header: Text(L("settings.ticker", comment: "菜单栏")).font(.title3)) {
                Picker(L("ticker.displayMode", comment: "展示模式"), selection: $prefs.displayMode) {
                    Text(L("ticker.mode.carousel", comment: "轮播")).tag(TickerDisplayMode.carousel)
                    Text(L("ticker.mode.scroll", comment: "跑马灯")).tag(TickerDisplayMode.scroll)
                }

                if prefs.displayMode == .scroll {
                    Picker(L("settings.scrollSpeed", comment: "滚动速度"), selection: $prefs.scrollSpeed) {
                        ForEach(ScrollSpeed.allCases) { s in
                            Text(s.displayName).tag(s)
                        }
                    }
                    Toggle(L("settings.pauseOnHover", comment: "鼠标悬停暂停"), isOn: $prefs.pauseOnHover)
                }
                if prefs.displayMode == .carousel {
                    Toggle(L("settings.pauseOnHover", comment: "鼠标悬停暂停"), isOn: $prefs.pauseOnHover)
                    Picker(L("ticker.carouselDwell", comment: "轮播停留时间"), selection: $prefs.carouselDwell) {
                        Text(L("ticker.dwell.2s", comment: "2 秒")).tag(2)
                        Text(L("ticker.dwell.3s", comment: "3 秒")).tag(3)
                        Text(L("ticker.dwell.4s", comment: "4 秒")).tag(4)
                        Text(L("ticker.dwell.6s", comment: "6 秒")).tag(6)
                        Text(L("ticker.dwell.10s", comment: "10 秒")).tag(10)
                    }
                }

                Toggle(L("settings.pauseWhenClosed", comment: "休市时暂停动画"), isOn: $prefs.pauseWhenClosed)

                Stepper(value: $prefs.maxItems, in: 1...50) {
                    Text(String(format: L("settings.maxItems", comment: "最多展示 %d 项"), prefs.maxItems))
                }

                if prefs.displayMode == .scroll {
                    Toggle(L("ticker.autoMenuBarWidth", comment: "自动适配菜单栏宽度"), isOn: $prefs.scrollAutoWidth)
                    if !prefs.scrollAutoWidth {
                        Stepper(value: $prefs.scrollMenuBarWidth, in: 160...720, step: 20) {
                            Text(String(format: L("ticker.menuBarWidth", comment: "菜单栏宽度: %d pt"), prefs.scrollMenuBarWidth))
                        }
                    }
                }
                if prefs.displayMode == .carousel {
                    Toggle(L("ticker.autoMenuBarWidth", comment: "自动适配菜单栏宽度"), isOn: $prefs.carouselAutoWidth)
                    if !prefs.carouselAutoWidth {
                        Stepper(value: $prefs.carouselMenuBarWidth, in: 100...360, step: 20) {
                            Text(String(format: L("ticker.menuBarWidth", comment: "菜单栏宽度: %d pt"), prefs.carouselMenuBarWidth))
                        }
                    }
                }
            }

            Section(header: Text(L("ticker.contentSection", comment: "显示内容")).font(.headline)) {
                Toggle(L("ticker.showAppIcon", comment: "显示应用图标"), isOn: $prefs.showAppIcon)
                Toggle(L("ticker.showQuoteCode", comment: "显示标的代码"), isOn: $prefs.showQuoteCode)
                Toggle(L("ticker.showQuoteName", comment: "显示标的名称"), isOn: $prefs.showQuoteName)
            }

            Section(header: Text(L("ticker.watchlistSection", comment: "自选标的排序")).font(.headline)) {
                if watchlist.isEmpty {
                    Text(L("watchlist.empty", comment: "暂无自选标的"))
                        .foregroundColor(.secondary)
                        .font(.caption)
                } else {
                    ForEach(watchlist) { item in
                        HStack {
                            Text(item.name.isEmpty ? item.symbol.code : item.name)
                            MarketBadge(market: item.symbol.market)
                            Spacer()
                            Text(item.symbol.code)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .onAppear {
            watchlist = (try? container.watchlistRepo.all()) ?? []
        }
    }
}
