import AppKit
import SwiftUI

@MainActor
final class SettingsNavigation: ObservableObject {
    @Published var selectedPane: SettingsRootView.Pane = .watchlist
    @Published var pendingAction: SettingsWindowController.PendingAction?
}

@MainActor
final class SettingsWindowController {
    static let shared = SettingsWindowController()

    let navigation = SettingsNavigation()
    private var window: NSWindow?

    enum PendingAction: Equatable {
        case addWatch
    }

    static var preferredPane: SettingsRootView.Pane? {
        get { nil }
        set {
            if let pane = newValue {
                shared.navigation.selectedPane = pane
            }
        }
    }

    static var pendingAction: PendingAction? {
        get { shared.navigation.pendingAction }
        set { shared.navigation.pendingAction = newValue }
    }

    private init() {}

    func show(initialAction: PendingAction? = nil) {
        navigation.pendingAction = initialAction
        if let initialAction = initialAction {
            navigation.selectedPane = pane(for: initialAction)
        }
        showWindow()
    }

    func show() {
        showWindow()
    }

    func show(pane: SettingsRootView.Pane) {
        navigation.selectedPane = pane
        showWindow()
    }

    private func pane(for action: PendingAction) -> SettingsRootView.Pane {
        switch action {
        case .addWatch: return .watchlist
        }
    }

    private func showWindow() {
        if let window = window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        guard let container = DependencyContainer.shared else { return }
        let view = SettingsRootView()
            .environmentObject(container.refresher)
            .environmentObject(navigation)
            .environment(\.container, container)
            .frame(minWidth: 580, minHeight: 460)

        let hosting = NSHostingController(rootView: view)
        let w = NSWindow(contentViewController: hosting)
        w.title = L("settings.title", comment: "设置")
        w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        w.setContentSize(NSSize(width: 680, height: 560))
        w.minSize = NSSize(width: 580, height: 460)
        w.center()
        w.isReleasedWhenClosed = false
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = w
    }
}

private struct ContainerKey: EnvironmentKey {
    static let defaultValue: DependencyContainer? = nil
}

extension EnvironmentValues {
    var container: DependencyContainer? {
        get { self[ContainerKey.self] }
        set { self[ContainerKey.self] = newValue }
    }
}

struct SettingsRootView: View {
    enum Pane: String, CaseIterable, Identifiable {
        case watchlist, ticker, general, markets, dataSources, about
        #if DEBUG
        case debug
        #endif

        var id: String { rawValue }
        var title: String {
            switch self {
            case .watchlist:   return L("settings.watchlist", comment: "自选")
            case .ticker:      return L("settings.ticker", comment: "菜单栏")
            case .general:     return L("settings.general", comment: "通用")
            case .markets:     return L("settings.markets", comment: "市场")
            case .dataSources: return L("settings.dataSources", comment: "数据源")
            case .about:       return L("settings.about", comment: "关于")
            #if DEBUG
            case .debug:       return "Debug"
            #endif
            }
        }
        var icon: String {
            switch self {
            case .watchlist:   return "star"
            case .ticker:      return "text.line.first.and.arrowtriangle.forward"
            case .general:     return "gear"
            case .markets:     return "clock"
            case .dataSources: return "antenna.radiowaves.left.and.right"
            case .about:       return "info.circle"
            #if DEBUG
            case .debug:       return "ladybug"
            #endif
            }
        }
    }

    @EnvironmentObject private var navigation: SettingsNavigation

    var body: some View {
        NavigationSplitView {
            List(Pane.allCases, selection: $navigation.selectedPane) { pane in
                Label(pane.title, systemImage: pane.icon).tag(pane)
            }
            .navigationSplitViewColumnWidth(min: 150, ideal: 170, max: 200)
        } detail: {
            switch navigation.selectedPane {
            case .watchlist:   WatchlistPane()
            case .ticker:      TickerPane()
            case .general:     GeneralPane()
            case .markets:     MarketsPane()
            case .dataSources: DataSourcesPane()
            case .about:       AboutPane()
            #if DEBUG
            case .debug:       DebugPane()
            #endif
            }
        }
    }
}
