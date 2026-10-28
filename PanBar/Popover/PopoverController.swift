import AppKit
import SwiftUI

@MainActor
final class PopoverController {
    private let popover: NSPopover
    private let refresher: QuoteRefresher
    private let viewModel: PopoverViewModel
    private let appearancePrefs: AppearancePreferences
    private let tickerPrefs: TickerPreferences
    private let container: DependencyContainer
    private let popoverWidth: CGFloat = 340
    private let popoverHeight: CGFloat = 520

    /// 监听 popover 之外的点击
    private var eventMonitor: Any?
    private var didCloseObserver: NSObjectProtocol?
    var onClose: (() -> Void)?

    var isShown: Bool { popover.isShown }

    init(
        refresher: QuoteRefresher,
        watchlistRepo: WatchlistRepository,
        settingsRepo: SettingsRepository,
        appearancePrefs: AppearancePreferences,
        tickerPrefs: TickerPreferences,
        container: DependencyContainer
    ) {
        self.refresher = refresher
        self.viewModel = PopoverViewModel(
            refresher: refresher,
            watchlistRepo: watchlistRepo,
            settingsRepo: settingsRepo
        )
        self.appearancePrefs = appearancePrefs
        self.tickerPrefs = tickerPrefs
        self.container = container

        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentSize = NSSize(width: popoverWidth, height: popoverHeight)
        popover.contentViewController = NSHostingController(rootView:
            PopoverRoot()
                .environmentObject(viewModel)
                .environmentObject(refresher)
                .environmentObject(appearancePrefs)
                .environmentObject(tickerPrefs)
                .environment(\.container, container)
                .frame(width: popoverWidth, height: popoverHeight)
        )
        self.popover = popover

        didCloseObserver = NotificationCenter.default.addObserver(
            forName: NSPopover.didCloseNotification,
            object: popover,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handlePopoverClosed()
            }
        }
    }

    deinit {
        if let m = eventMonitor { NSEvent.removeMonitor(m) }
        if let observer = didCloseObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    private func handlePopoverClosed() {
        stopOutsideClickMonitor()
        refresher.setPopoverOpen(false)
        onClose?()
    }

    func show(relativeTo view: NSView, anchorWidth: CGFloat? = nil) {
        refresher.setPopoverOpen(true)
        refresher.refreshNow()
        popover.show(relativeTo: positioningRect(relativeTo: view, anchorWidth: anchorWidth), of: view, preferredEdge: .minY)
        startOutsideClickMonitor()
    }

    private func positioningRect(relativeTo view: NSView, anchorWidth: CGFloat?) -> NSRect {
        let rect: NSRect
        if let anchorWidth {
            let width = max(view.bounds.width, anchorWidth)
            rect = NSRect(
                x: view.bounds.maxX - width,
                y: view.bounds.minY,
                width: width,
                height: view.bounds.height
            )
        } else {
            rect = view.bounds
        }
        return rect
    }

    func close() {
        stopOutsideClickMonitor()
        popover.performClose(nil)
        refresher.setPopoverOpen(false)
    }

    private func startOutsideClickMonitor() {
        stopOutsideClickMonitor()
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self = self, self.popover.isShown else { return }
                self.close()
            }
        }
    }

    private func stopOutsideClickMonitor() {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
    }
}
