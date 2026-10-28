import SwiftUI

/// Pulse 风格的标的市场徽章(Market Badge)。
/// 高辨识度半透明背景 + 饱和度适中的彩色文字。
struct MarketBadge: View {
    let market: Market

    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .bold, design: .default))
            .foregroundColor(textColor)
            .padding(.horizontal, 4)
            .padding(.vertical, 1.5)
            .background(
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(bgColor)
            )
    }

    private var text: String {
        switch market {
        case .us: return "US"
        case .hk: return "HK"
        case .a:  return "CN"
        }
    }

    private var textColor: Color {
        switch market {
        case .us: return Color(red: 0.0, green: 0.48, blue: 1.0)       // #007AFF
        case .hk: return Color(red: 0.35, green: 0.34, blue: 0.84)     // #5856D6
        case .a:  return Color(red: 1.0, green: 0.58, blue: 0.0)       // #FF9500
        }
    }

    private var bgColor: Color {
        textColor.opacity(0.14)
    }
}
