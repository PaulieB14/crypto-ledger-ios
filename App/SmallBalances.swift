import Foundation

/// Hide tiny rows from the holdings list without touching the portfolio total.
///
/// Default is off. A wallet import can be full of dust, but this app's rule is
/// that nothing disappears until the person asks: an unpriced coin stays
/// listed, a row at exactly the cutoff stays listed, and net worth is computed
/// upstream of this filter so hidden value is still in the total.
enum SmallBalancePreset: String, CaseIterable, Identifiable, Sendable {
    case off
    case one
    case ten
    case hundred
    case custom

    var id: String { rawValue }

    var menuTitle: String {
        switch self {
        case .off: "Off"
        case .one: "Hide under $1"
        case .ten: "Hide under $10"
        case .hundred: "Hide under $100"
        case .custom: "Hide under a custom amount"
        }
    }
}

struct SmallBalancePolicy: Equatable, Sendable {
    static let presetKey = "smallBalancePreset"
    static let customKey = "smallBalanceCustomUSD"
    static let showingAllKey = "smallBalanceShowingAll"

    var preset: SmallBalancePreset
    var customUSD: Decimal
    /// One-tap override. The cutoff stays saved; the list shows every row.
    var showingAll: Bool

    /// The saved cutoff. Nil when the filter is off, or custom is blank / not positive.
    var configuredThresholdUSD: Decimal? {
        switch preset {
        case .off:
            return nil
        case .one:
            return 1
        case .ten:
            return 10
        case .hundred:
            return 100
        case .custom:
            return customUSD > 0 ? customUSD : nil
        }
    }

    /// True when rows under the cutoff should leave the list.
    var hidesRows: Bool { configuredThresholdUSD != nil && !showingAll }

    /// Magnitude under the saved cutoff. Unpriced rows (nil) are never "under".
    /// Compared with `<`, so a holding worth exactly $10 stays visible at "under $10".
    func isUnderThreshold(_ value: Decimal?) -> Bool {
        guard let cutoff = configuredThresholdUSD, let value else { return false }
        return abs(value) < cutoff
    }

    /// "$10" for whole dollars under 1000, otherwise a normal USD currency string.
    static func amountLabel(_ amount: Decimal, locale: Locale = .current) -> String {
        let number = NSDecimalNumber(decimal: amount)
        let magnitude = number.doubleValue
        if magnitude >= 0, magnitude < 1000, magnitude == magnitude.rounded() {
            return "$\(number.intValue)"
        }
        return amount.formatted(
            .currency(code: "USD").precision(.fractionLength(2...2)).locale(locale)
        )
    }

    /// The line under the holdings list. "3 hidden under $10", or the show-all twin.
    static func statusLine(hiddenCount: Int, threshold: Decimal, showingAll: Bool, locale: Locale = .current) -> String {
        let money = amountLabel(threshold, locale: locale)
        if hiddenCount == 0 { return "Nothing under \(money)" }
        if showingAll { return "Showing \(hiddenCount) under \(money)" }
        return "\(hiddenCount) hidden under \(money)"
    }
}

struct SmallBalanceSplit<Item> {
    var visible: [Item]
    var hiddenCount: Int
}

enum SmallBalanceFilter {
    /// Partition a list. Hidden rows are omitted only while `hidesRows` is set.
    /// `hiddenCount` still reports them during show-all, so the toggle can name them.
    static func split<Item>(
        _ items: [Item],
        policy: SmallBalancePolicy,
        value: (Item) -> Decimal?
    ) -> SmallBalanceSplit<Item> {
        var visible: [Item] = []
        visible.reserveCapacity(items.count)
        var hiddenCount = 0
        for item in items {
            if policy.isUnderThreshold(value(item)) {
                hiddenCount += 1
                if policy.hidesRows { continue }
            }
            visible.append(item)
        }
        return SmallBalanceSplit(visible: visible, hiddenCount: hiddenCount)
    }
}

/// Portfolio figures. Exact currency under $10,000. Compact above that ($12.4K,
/// $1.2M) so a row stays one line. Callers that are a tax figure, or the net
/// worth headline, should keep the exact string instead.
enum USDFormat {
    static func exact(_ value: Decimal, fractionDigits: ClosedRange<Int> = 2...2, locale: Locale = .current) -> String {
        value.formatted(.currency(code: "USD").precision(.fractionLength(fractionDigits)).locale(locale))
    }

    static func display(
        _ value: Decimal,
        compactAbove cutoff: Decimal = 10_000,
        fractionDigits: ClosedRange<Int> = 2...2,
        locale: Locale = .current
    ) -> String {
        if abs(value) >= cutoff {
            return value.formatted(
                .currency(code: "USD")
                    .notation(.compactName)
                    .precision(.fractionLength(0...1))
                    .locale(locale)
            )
        }
        return exact(value, fractionDigits: fractionDigits, locale: locale)
    }

    static func display(
        _ value: Double,
        compactAbove cutoff: Double = 10_000,
        fractionDigits: ClosedRange<Int> = 2...2,
        locale: Locale = .current
    ) -> String {
        if abs(value) >= cutoff {
            return value.formatted(
                .currency(code: "USD")
                    .notation(.compactName)
                    .precision(.fractionLength(0...1))
                    .locale(locale)
            )
        }
        return value.formatted(.currency(code: "USD").precision(.fractionLength(fractionDigits)).locale(locale))
    }
}
