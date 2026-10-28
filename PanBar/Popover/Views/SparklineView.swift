import SwiftUI

/// 走势时序缓存，按 SymbolID 记录最近接收到的价格点。
@MainActor
final class SparklineStore: ObservableObject {
    static let shared = SparklineStore()

    @Published private(set) var history: [SymbolID: [Double]] = [:]

    private let maxPoints = 50

    func record(quote: Quote) {
        if let apiPoints = quote.sparklineHistory, apiPoints.count >= 2 {
            history[quote.symbol] = apiPoints
            return
        }

        let price = (quote.effectivePrice as NSDecimalNumber).doubleValue
        guard price > 0 else { return }

        var list = history[quote.symbol] ?? []
        if list.isEmpty {
            list = generateInitialPoints(quote: quote)
        } else {
            if list.last != price {
                list.append(price)
                if list.count > maxPoints {
                    list.removeFirst(list.count - maxPoints)
                }
            }
        }
        history[quote.symbol] = list
    }

    func points(for quote: Quote) -> [Double] {
        if let apiPoints = quote.sparklineHistory, apiPoints.count >= 2 {
            return apiPoints
        }
        if let existing = history[quote.symbol], existing.count >= 2 {
            return existing
        }
        let generated = generateInitialPoints(quote: quote)
        history[quote.symbol] = generated
        return generated
    }

    private func generateInitialPoints(quote: Quote) -> [Double] {
        let prev = (quote.prevClose as NSDecimalNumber).doubleValue
        let cur = (quote.effectivePrice as NSDecimalNumber).doubleValue
        let open = (quote.open.map { ($0 as NSDecimalNumber).doubleValue }) ?? (prev > 0 ? (prev + cur) / 2 : cur)
        let high = (quote.high.map { ($0 as NSDecimalNumber).doubleValue }) ?? max(prev, cur, open)
        let low = (quote.low.map { ($0 as NSDecimalNumber).doubleValue }) ?? min(prev, cur, open)

        guard prev > 0, cur > 0 else {
            return [cur, cur]
        }

        var pts: [Double] = []
        pts.append(prev)
        pts.append(open)

        let mid1 = open + (high - open) * 0.7
        let mid2 = mid1 - (mid1 - low) * 0.65
        let mid3 = (mid2 + high) * 0.5
        let mid4 = (mid3 + cur) * 0.45 + (low * 0.1)

        pts.append(mid1)
        pts.append(high)
        pts.append(mid2)
        pts.append(low)
        pts.append(mid3)
        pts.append(mid4)
        pts.append(cur)

        return pts
    }
}

/// Pulse 风格的单行迷你走势折线图 (Sparkline)。
struct SparklineView: View {
    let quote: Quote?
    let scheme: TickerColorScheme
    var height: CGFloat = 26

    @ObservedObject private var store = SparklineStore.shared

    var body: some View {
        GeometryReader { geo in
            if let q = quote, let pts = resolvedPoints(for: q), pts.count >= 2 {
                let prev = (q.prevClose as NSDecimalNumber).doubleValue
                let color = q.effectiveChange >= 0 ? SemanticColors.up(scheme: scheme) : SemanticColors.down(scheme: scheme)

                ZStack {
                    if prev > 0 {
                        baseline(prev: prev, in: pts, size: geo.size)
                    }

                    areaGradient(points: pts, color: color, size: geo.size)

                    linePath(points: pts, size: geo.size)
                        .stroke(color, style: StrokeStyle(lineWidth: 1.35, lineCap: .round, lineJoin: .round))

                    currentPriceDot(points: pts, color: color, size: geo.size)
                }
            } else {
                Path { path in
                    path.move(to: CGPoint(x: 0, y: geo.size.height / 2))
                    path.addLine(to: CGPoint(x: geo.size.width, y: geo.size.height / 2))
                }
                .stroke(Color.primary.opacity(0.1), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
        }
        .frame(height: height)
        .clipped()
        .onAppear {
            if let q = quote {
                store.record(quote: q)
            }
        }
        .onChange(of: quote?.effectivePrice) { _ in
            if let q = quote {
                store.record(quote: q)
            }
        }
    }

    private func resolvedPoints(for q: Quote) -> [Double]? {
        let pts = store.points(for: q)
        return pts.count >= 2 ? pts : nil
    }

    private func minMax(points: [Double], prev: Double) -> (min: Double, max: Double) {
        var minVal = points.min() ?? prev
        var maxVal = points.max() ?? prev
        if prev > 0 {
            minVal = min(minVal, prev)
            maxVal = max(maxVal, prev)
        }
        let diff = maxVal - minVal
        if diff == 0 {
            return (minVal - 1, maxVal + 1)
        }
        let pad = diff * 0.12
        return (minVal - pad, maxVal + pad)
    }

    private func baseline(prev: Double, in points: [Double], size: CGSize) -> some View {
        let (minVal, maxVal) = minMax(points: points, prev: prev)
        let range = maxVal - minVal
        let normY = 1.0 - CGFloat((prev - minVal) / range)
        let y = min(max(normY * size.height, 1), size.height - 1)

        return Path { path in
            path.move(to: CGPoint(x: 0, y: y))
            path.addLine(to: CGPoint(x: size.width, y: y))
        }
        .stroke(Color.primary.opacity(0.12), style: StrokeStyle(lineWidth: 0.8, dash: [2, 3]))
    }

    private func linePath(points: [Double], size: CGSize) -> Path {
        var path = Path()
        guard points.count >= 2 else { return path }

        let minVal = points.min() ?? 0
        let maxVal = points.max() ?? 1
        let range = max(maxVal - minVal, 0.0001)
        let stepX = size.width / CGFloat(points.count - 1)

        let coords: [CGPoint] = points.enumerated().map { idx, val in
            let x = CGFloat(idx) * stepX
            let normY = 1.0 - CGFloat((val - minVal) / range)
            let y = normY * (size.height - 4) + 2
            return CGPoint(x: x, y: y)
        }

        path.move(to: coords[0])
        for i in 1..<coords.count {
            let p0 = coords[i - 1]
            let p1 = coords[i]
            let midX = (p0.x + p1.x) / 2
            path.addCurve(to: p1, control1: CGPoint(x: midX, y: p0.y), control2: CGPoint(x: midX, y: p1.y))
        }

        return path
    }

    private func areaGradient(points: [Double], color: Color, size: CGSize) -> some View {
        var path = linePath(points: points, size: size)
        guard points.count >= 2 else { return AnyView(EmptyView()) }

        path.addLine(to: CGPoint(x: size.width, y: size.height))
        path.addLine(to: CGPoint(x: 0, y: size.height))
        path.closeSubpath()

        let gradient = LinearGradient(
            colors: [color.opacity(0.12), color.opacity(0.01)],
            startPoint: .top,
            endPoint: .bottom
        )

        return AnyView(path.fill(gradient))
    }

    private func currentPriceDot(points: [Double], color: Color, size: CGSize) -> some View {
        let minVal = points.min() ?? 0
        let maxVal = points.max() ?? 1
        let range = max(maxVal - minVal, 0.0001)
        let lastVal = points.last ?? minVal
        let normY = 1.0 - CGFloat((lastVal - minVal) / range)
        let y = normY * (size.height - 4) + 2

        return Circle()
            .fill(color)
            .frame(width: 3.2, height: 3.2)
            .position(x: size.width - 1.6, y: y)
    }
}
