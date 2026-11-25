import Foundation
#if DEBUG
import LedgerCore

/// Illustrative holdings for App Store screenshots.
///
/// Compiled only into Debug builds, and inert unless the process was launched
/// with `-ArgusDemoScreenshots`. Release archives (TestFlight, the App Store)
/// do not contain this code. It never reads a wallet and never writes the
/// on-device ledger: `LedgerStore.save` and `SnapshotStore.save` refuse it.
///
/// The amounts are round demo figures (0.50 BTC, 2 ETH, and three coins under
/// $10). They are not a real address and not the sample portfolio that was
/// removed for App Review.
enum DemoSeed {
    static let launchArgument = "-ArgusDemoScreenshots"
    static let screenArgument = "-ArgusScreenshot"

    static var isEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains(launchArgument)
    }

    /// `portfolio`, `dust`, `shown`, `btc`, `cycle`, or `import`.
    static var screen: String {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: screenArgument), index + 1 < args.count else {
            return "portfolio"
        }
        return args[index + 1]
    }

    /// Dark appearance and the small-balance cutoff, before any view reads them.
    static func prepareLaunchState() {
        guard isEnabled else { return }
        let defaults = UserDefaults.standard
        defaults.set("dark", forKey: "appearance")
        switch screen {
        case "dust":
            defaults.set(SmallBalancePreset.ten.rawValue, forKey: SmallBalancePolicy.presetKey)
            defaults.set(false, forKey: SmallBalancePolicy.showingAllKey)
        case "shown":
            defaults.set(SmallBalancePreset.ten.rawValue, forKey: SmallBalancePolicy.presetKey)
            defaults.set(true, forKey: SmallBalancePolicy.showingAllKey)
        default:
            defaults.set(SmallBalancePreset.off.rawValue, forKey: SmallBalancePolicy.presetKey)
            defaults.set(false, forKey: SmallBalancePolicy.showingAllKey)
        }
    }

    /// Spot × quantity for the six demo rows. The chart's last point is the
    /// engine's net worth, which should land on this number.
    static var illustrativeNetWorth: Double {
        let rows = [("BTC", "0.5"), ("ETH", "2"), ("SOL", "8"), ("DOGE", "40"), ("ADA", "3"), ("DOT", "0.4")]
        let total = rows.reduce(Decimal(0)) { sum, row in
            sum + (spots[row.0] ?? 0) * dec(row.1)
        }
        return (total as NSDecimalNumber).doubleValue
    }

    static var spots: [String: Decimal] {
        [
            "BTC": dec("64000"),
            "ETH": dec("3200"),
            "SOL": dec("150"),
            "DOGE": dec("0.08"),
            "ADA": dec("0.35"),
            "DOT": dec("6"),
        ]
    }

    /// Purchased below the spot above, so the BTC screen can show a cost and a gain.
    static func entries() -> [LedgerEntry] {
        let when = monthsAgo(4)
        return [
            holding("btc", "BTC", "0.5", "42000", when),
            holding("eth", "ETH", "2", "1800", when),
            holding("sol", "SOL", "8", "90", when),
            holding("doge", "DOGE", "40", "0.05", when),
            holding("ada", "ADA", "3", "0.20", when),
            holding("dot", "DOT", "0.4", "4", when),
        ]
    }

    /// A short rise ending on today's net worth, so the hero chart is a line
    /// rather than the one-day note. Today's point is replaced by the engine.
    static func history(endingAt total: Double) -> [NetWorthSnapshot] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let today = calendar.startOfDay(for: Date())
        let start = total * 0.88
        let days = 28
        return (0..<days).map { index in
            let date = calendar.date(byAdding: .day, value: -(days - 1 - index), to: today) ?? today
            let t = Double(index) / Double(days - 1)
            let value = start + (total - start) * t
            return NetWorthSnapshot(date: date, netWorthUSD: value, cashUSD: 0, cryptoUSD: value)
        }
    }

    private static func holding(_ id: String, _ asset: String, _ qty: String, _ cost: String, _ date: Date) -> LedgerEntry {
        LedgerEntry(
            id: "demo-\(id)",
            sourceID: "demo",
            externalRef: "demo-\(id)",
            timestamp: date,
            accountID: "Manual",
            assetID: asset,
            qtyDelta: dec(qty),
            kind: .airdrop,
            unitPriceUSD: dec(cost)
        )
    }

    private static func dec(_ value: String) -> Decimal {
        Decimal(string: value, locale: Locale(identifier: "en_US_POSIX")) ?? 0
    }

    private static func monthsAgo(_ months: Int) -> Date {
        Calendar(identifier: .gregorian).date(byAdding: .month, value: -months, to: Date()) ?? Date()
    }
}
#endif
