//  NetWorthChart — the pulse line.
//
//  A calm reading-instrument chart: a hairline Ink stroke over a faint
//  directional wash, a dotted amber reference at the period-open value, an
//  amber freshness node at the leading edge, and a scrub crosshair that reports
//  the value under the finger. iOS 17 / macOS 14, system-only, light + dark and
//  Reduce-Motion aware.
import SwiftUI
import Charts

/// One (time, value) sample on the net-worth line.
struct NetWorthPoint: Identifiable, Hashable, Sendable {
    let date: Date
    let value: Double
    var id: Date { date }
}

extension Array where Element == NetWorthPoint {
    /// Evenly-spaced daily points from a bare `[Double]` (previews/simple callers).
    static func daily(_ values: [Double], endingOn end: Date = Date()) -> [NetWorthPoint] {
        let cal = Calendar.current
        let n = values.count
        return values.enumerated().map { i, v in
            let d = cal.date(byAdding: .day, value: -(n - 1 - i), to: end) ?? end
            return NetWorthPoint(date: d, value: v)
        }
    }
}

struct NetWorthChart: View {
    private let points: [NetWorthPoint]
    private let onScrub: ((NetWorthPoint?) -> Void)?

    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selected: NetWorthPoint?

    init(points: [NetWorthPoint], onScrub: ((NetWorthPoint?) -> Void)? = nil) {
        self.points = points
        self.onScrub = onScrub
    }

    private var isUp: Bool {
        guard let first = points.first, let last = points.last else { return true }
        return last.value >= first.value
    }
    private var trend: Color { isUp ? Theme.gain : Theme.loss }

    private var yDomain: ClosedRange<Double> {
        let vs = points.map(\.value)
        guard let lo = vs.min(), let hi = vs.max() else { return 0...1 }
        if lo == hi { let pad = max(abs(lo) * 0.02, 1); return (lo - pad)...(hi + pad) }
        let pad = (hi - lo) * 0.12
        return (lo - pad)...(hi + pad)
    }
    private var openValue: Double { points.first?.value ?? 0 }

    var body: some View {
        Group {
            if points.count < 2 {
                sparseNote
            } else {
                chart.frame(minHeight: 120)
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: points)
        .sensoryFeedback(.selection, trigger: selected?.date)
    }

    private var chart: some View {
        Chart {
            RuleMark(y: .value("Open", openValue))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 3]))
                .foregroundStyle(Theme.amber.opacity(0.55))

            ForEach(points) { p in
                AreaMark(x: .value("Date", p.date),
                         yStart: .value("Base", yDomain.lowerBound),
                         yEnd: .value("Value", p.value))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(LinearGradient(
                        colors: [trend.opacity(scheme == .dark ? 0.22 : 0.14), trend.opacity(0)],
                        startPoint: .top, endPoint: .bottom))

                LineMark(x: .value("Date", p.date), y: .value("Value", p.value))
                    .interpolationMethod(.monotone)
                    .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round))
                    .foregroundStyle(Theme.ink)
            }

            if selected == nil, let last = points.last {
                PointMark(x: .value("Date", last.date), y: .value("Value", last.value))
                    .symbolSize(58)
                    .foregroundStyle(Theme.amber)
            }

            if let sel = selected {
                RuleMark(x: .value("Date", sel.date))
                    .lineStyle(StrokeStyle(lineWidth: 1))
                    .foregroundStyle(Theme.amber.opacity(0.7))
                PointMark(x: .value("Date", sel.date), y: .value("Value", sel.value))
                    .symbolSize(70)
                    .foregroundStyle(Theme.amber)
                    .annotation(position: .top, spacing: 6,
                                overflowResolution: .init(x: .fit, y: .disabled)) { readout(sel) }
            }
        }
        .chartYScale(domain: yDomain)
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { _ in
                AxisGridLine().foregroundStyle(Theme.hairline)
                AxisValueLabel().font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Theme.inkSecondary)
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                AxisGridLine().foregroundStyle(Theme.hairline.opacity(0.6))
                AxisValueLabel().font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Theme.inkSecondary)
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { drag in scrub(to: drag.location, proxy: proxy, geo: geo) }
                        .onEnded { _ in selected = nil; onScrub?(nil) })
            }
        }
        .accessibilityLabel("Net worth over time")
        .accessibilityValue(points.last.map { "\(Int($0.value)) dollars" } ?? "")
    }

    private func readout(_ p: NetWorthPoint) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(p.value, format: .currency(code: "USD").precision(.fractionLength(0)))
                .font(.figure(14, .medium)).foregroundStyle(Theme.ink)
            Text(p.date, format: .dateTime.month(.abbreviated).day().hour().minute())
                .font(.system(size: 10, design: .monospaced)).foregroundStyle(Theme.inkSecondary)
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.hairline, lineWidth: 1))
    }

    private func scrub(to location: CGPoint, proxy: ChartProxy, geo: GeometryProxy) {
        guard let anchor = proxy.plotFrame else { return }
        let plot = geo[anchor]
        let x = location.x - plot.origin.x
        guard x >= 0, x <= plot.width, let date: Date = proxy.value(atX: x) else { return }
        let nearest = points.min(by: {
            abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date))
        })
        if nearest?.date != selected?.date {
            selected = nearest
            onScrub?(nearest)
        }
    }

    /// One data point is not a chart.
    ///
    /// Reserving chart-height space to draw a single dot on an empty field reads
    /// as a graph that failed to load. A compact line reads as what it actually
    /// is: an account that is one day old. Entering a balance today tells Argus
    /// nothing about what you held last week, so there is genuinely no history to
    /// draw yet — and inventing one would make the chart a lie.
    private var sparseNote: some View {
        HStack(spacing: 8) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.footnote)
                .foregroundStyle(Theme.amber)
            Text("Tracking since \(points.first?.date ?? Date(), format: .dateTime.month().day()) — your chart fills in as prices move.")
                .font(.editorial(15))
                .foregroundStyle(Theme.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }
}

#if os(iOS)
#Preview("Up") {
    NetWorthChart(points: .daily([102_000, 101_200, 104_500, 103_800, 106_200,
                                  108_900, 107_400, 111_300, 112_800, 116_430]))
        .padding()
}
#endif
