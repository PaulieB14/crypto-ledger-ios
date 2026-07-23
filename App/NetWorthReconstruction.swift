import Foundation
import LedgerCore

/// Reconstructs an accurate daily net-worth series from the immutable ledger ×
/// real per-coin price history. Uses quantity-AT-each-day (a running fold of
/// qtyDelta), never current quantities against past prices — so it never lies
/// about a past rebalance. Backfills the chart's pre-install history; forward
/// daily snapshots remain the authoritative source and override any overlap.
enum NetWorthReconstruction {

    /// - Parameters:
    ///   - entries: the full immutable entry stream.
    ///   - coinIDBySymbol: symbol -> CoinGecko id (from the loaded catalog).
    static func series(entries: [LedgerEntry],
                       coinIDBySymbol: [String: String],
                       days: Int = 30) async -> [NetWorthPoint] {
        guard !entries.isEmpty else { return [] }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current

        // Fetch each held coin's daily price history (serially — gentle on the
        // free API; a failed coin is simply skipped).
        let cryptoAssets = Set(entries.map(\.assetID)).subtracting(["USD"])
        var priceByAssetDay: [String: [Date: Double]] = [:]
        for asset in cryptoAssets {
            guard let id = coinIDBySymbol[asset] else { continue }
            let hist = await CoinGecko.priceHistory(coinID: id, days: days)
            guard !hist.isEmpty else { continue }
            var byDay: [Date: Double] = [:]
            for p in hist { byDay[cal.startOfDay(for: p.date)] = p.priceUSD }  // last of day wins
            priceByAssetDay[asset] = byDay
        }
        guard !priceByAssetDay.isEmpty else { return [] }

        let sorted = entries.sorted { $0.timestamp < $1.timestamp }
        let today = cal.startOfDay(for: Date())
        var points: [NetWorthPoint] = []

        for offset in stride(from: days - 1, through: 0, by: -1) {
            guard let day = cal.date(byAdding: .day, value: -offset, to: today),
                  let dayEnd = cal.date(byAdding: .day, value: 1, to: day)?.addingTimeInterval(-1)
            else { continue }

            // Cumulative quantity per asset (and cash) as of end of this day.
            var qty: [String: Decimal] = [:]
            for e in sorted where e.timestamp <= dayEnd {
                qty[e.assetID, default: 0] += e.qtyDelta
            }

            var value = ((qty["USD"] ?? 0) as NSDecimalNumber).doubleValue
            var pricedAnything = false
            for (asset, q) in qty where asset != "USD" && q > 0 {
                guard let price = priceOn(day: day, byDay: priceByAssetDay[asset], cal: cal) else { continue }
                value += (q as NSDecimalNumber).doubleValue * price
                pricedAnything = true
            }

            // Skip the flat-zero run before the first holding existed.
            if pricedAnything || value > 0 {
                points.append(NetWorthPoint(date: day, value: value))
            }
        }
        return points
    }

    /// Price for `day`, falling back to the nearest available day within a week.
    private static func priceOn(day: Date, byDay: [Date: Double]?, cal: Calendar) -> Double? {
        guard let byDay else { return nil }
        if let p = byDay[day] { return p }
        for back in 1...7 {
            if let d = cal.date(byAdding: .day, value: -back, to: day), let p = byDay[d] { return p }
        }
        for fwd in 1...7 {
            if let d = cal.date(byAdding: .day, value: fwd, to: day), let p = byDay[d] { return p }
        }
        return nil
    }
}
