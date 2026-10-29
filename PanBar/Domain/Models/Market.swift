import Foundation

enum Market: String, Codable, CaseIterable, Sendable {
    case a   // A-share (Shanghai / Shenzhen)
    case hk  // Hong Kong
    case us  // United States
    case kr  // South Korea (KRX: KOSPI / KOSDAQ)

    var displayName: String {
        switch self {
        case .a:  return L("market.a", comment: "A-share market")
        case .hk: return L("market.hk", comment: "Hong Kong market")
        case .us: return L("market.us", comment: "US market")
        case .kr: return L("market.kr", comment: "South Korea market")
        }
    }

    var defaultCurrency: Currency {
        switch self {
        case .a:  return .cny
        case .hk: return .hkd
        case .us: return .usd
        case .kr: return .krw
        }
    }

    var timeZone: TimeZone {
        switch self {
        case .a, .hk: return TimeZone(identifier: "Asia/Shanghai")!
        case .us:     return TimeZone(identifier: "America/New_York")!
        case .kr:     return TimeZone(identifier: "Asia/Seoul")!
        }
    }
}
