import SwiftUI

struct PopoverRoot: View {
    @EnvironmentObject var vm: PopoverViewModel
    @EnvironmentObject var refresher: QuoteRefresher
    @Environment(\.container) private var container

    var isPinned: Bool = false
    var onTogglePin: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 0) {
            header
            WatchlistTab()
            Divider().opacity(0.35)
            footer
        }
    }

    /// 极简清爽的 Header
    private var header: some View {
        HStack(spacing: 8) {
            // 左侧:Pulse 极简电波 Logo + 应用名称
            HStack(spacing: 6) {
                PulseWaveform()
                    .stroke(SemanticColors.pulseBrandBlue, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                    .frame(width: 15, height: 11)

                Text("PanBar")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.primary)
            }

            Spacer()

            // 右侧工具按钮: Pin 图钉 / 搜索 / 设置
            HStack(spacing: 4) {
                if let onTogglePin = onTogglePin {
                    toolButton(
                        systemName: isPinned ? "pin.fill" : "pin",
                        active: isPinned,
                        help: isPinned ? L("action.unpinWindow", comment: "取消钉住") : L("action.pinWindow", comment: "钉为独立窗口")
                    ) {
                        onTogglePin()
                    }
                }

                toolButton(systemName: "magnifyingglass", active: false, help: L("action.search", comment: "搜索标的")) {
                    openSearch()
                }

                toolButton(systemName: "gearshape", active: false, help: L("menu.settings", comment: "设置")) {
                    openSettings()
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 9)
        .padding(.bottom, 6)
    }

    private func toolButton(systemName: String, active: Bool, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11.5, weight: active ? .semibold : .regular))
                .foregroundColor(active ? SemanticColors.pulseBrandBlue : .secondary)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    /// 极简纯净的 Footer
    private var footer: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(footerStatusColor)
                .frame(width: 5, height: 5)

            Text(footerStatus)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.secondary)

            Spacer()

            if refresher.isRefreshing {
                ProgressView()
                    .controlSize(.mini)
                    .scaleEffect(0.6)
                    .frame(width: 10, height: 10)
            } else if let updated = refresher.lastUpdated {
                Text(timeString(from: updated))
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundColor(.secondary.opacity(0.6))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
    }

    private var footerStatusColor: Color {
        if refresher.isOffline { return .secondary }
        if refresher.lastError != nil { return .orange }
        return Color(red: 0.04, green: 0.66, blue: 0.35)
    }

    private var footerStatus: String {
        if refresher.isOffline {
            return L("footer.offline", comment: "离线")
        }
        if refresher.lastError != nil {
            return L("footer.quoteFailed", comment: "部分行情延迟")
        }
        return "Streaming live"
    }

    private func timeString(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    private func openSettings() {
        SettingsWindowController.shared.show()
    }

    private func openSearch() {
        SettingsWindowController.shared.show(initialAction: .addWatch)
    }
}
