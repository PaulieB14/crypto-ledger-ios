import Foundation

// Locks the filter the holdings list uses. Net worth is not an input: the
// caller keeps every value in the total and only drops rows from the list.
var failures = 0

@MainActor
func check(_ condition: Bool, _ message: String) {
    if !condition {
        failures += 1
        FileHandle.standardError.write("FAIL \(message)\n".data(using: .utf8)!)
    }
}

let off = SmallBalancePolicy(preset: .off, customUSD: 0, showingAll: false)
check(off.configuredThresholdUSD == nil, "off has no cutoff")
check(!off.hidesRows, "off does not hide")
check(!off.isUnderThreshold(Decimal(string: "0.5")), "off hides nothing")

let one = SmallBalancePolicy(preset: .one, customUSD: 0, showingAll: false)
check(one.configuredThresholdUSD == 1, "$1 preset")
check(one.isUnderThreshold(Decimal(string: "0.99")), "0.99 is under $1")
check(!one.isUnderThreshold(1), "exactly $1 stays")
check(!one.isUnderThreshold(nil), "a missing price stays")
check(one.isUnderThreshold(Decimal(string: "-0.40")), "a small debt uses magnitude")
check(!one.isUnderThreshold(Decimal(string: "-1")), "a $1 debt stays")

let ten = SmallBalancePolicy(preset: .ten, customUSD: 0, showingAll: false)
let revealed = SmallBalancePolicy(preset: .ten, customUSD: 0, showingAll: true)
check(revealed.configuredThresholdUSD == 10, "show-all keeps the saved cutoff")
check(!revealed.hidesRows, "show-all does not hide rows")
check(revealed.isUnderThreshold(3), "show-all still knows which rows are small")

let custom = SmallBalancePolicy(preset: .custom, customUSD: Decimal(string: "2.50")!, showingAll: false)
check(custom.configuredThresholdUSD == Decimal(string: "2.50"), "custom cutoff")
check(custom.isUnderThreshold(Decimal(string: "2.49")), "2.49 is under 2.50")
check(!custom.isUnderThreshold(Decimal(string: "2.50")), "2.50 stays")

let blank = SmallBalancePolicy(preset: .custom, customUSD: 0, showingAll: false)
check(blank.configuredThresholdUSD == nil, "a blank custom amount hides nothing")
check(!blank.hidesRows, "blank custom is not active")

let hundred = SmallBalancePolicy(preset: .hundred, customUSD: 0, showingAll: false)
check(hundred.configuredThresholdUSD == 100, "$100 preset")

let sample: [Decimal?] = [100, Decimal(string: "0.50"), nil, 10]
let hidden = SmallBalanceFilter.split(sample, policy: one) { $0 }
check(hidden.visible.count == 3, "visible keeps the priced row, the unpriced row, and $10")
check(hidden.hiddenCount == 1, "only the 50 cent row is hidden")
check(hidden.visible.contains(where: { $0 == nil }), "nil survived")

let shown = SmallBalanceFilter.split(sample, policy: revealed) { $0 }
check(shown.visible.count == 4, "show-all returns every row")
check(shown.hiddenCount == 1, "show-all still reports the hidden count")

let allSmall = SmallBalanceFilter.split([Decimal(string: "0.2"), Decimal(string: "0.4")], policy: ten) { $0 }
check(allSmall.visible.isEmpty, "every row can be hidden")
check(allSmall.hiddenCount == 2, "both counted")
let kept = (allSmall.visible.reduce(Decimal(0)) { $0 + ($1 ?? 0) })
    + Decimal(string: "0.2")! + Decimal(string: "0.4")!
check(kept == Decimal(string: "0.6"), "hidden amounts are still available to a total")

let en = Locale(identifier: "en_US")
check(SmallBalancePolicy.amountLabel(1, locale: en) == "$1", "label $1")
check(SmallBalancePolicy.amountLabel(10, locale: en) == "$10", "label $10")
check(SmallBalancePolicy.amountLabel(100, locale: en) == "$100", "label $100")
check(SmallBalancePolicy.amountLabel(Decimal(string: "2.5")!, locale: en) == "$2.50", "label $2.50")

check(
    SmallBalancePolicy.statusLine(hiddenCount: 3, threshold: 10, showingAll: false, locale: en) == "3 hidden under $10",
    "hidden line"
)
check(
    SmallBalancePolicy.statusLine(hiddenCount: 3, threshold: 10, showingAll: true, locale: en) == "Showing 3 under $10",
    "showing line"
)
check(
    SmallBalancePolicy.statusLine(hiddenCount: 0, threshold: 1, showingAll: false, locale: en) == "Nothing under $1",
    "empty line"
)
for line in [
    SmallBalancePolicy.statusLine(hiddenCount: 3, threshold: 10, showingAll: false, locale: en),
    SmallBalancePolicy.statusLine(hiddenCount: 1, threshold: Decimal(string: "2.5")!, showingAll: true, locale: en),
] {
    check(!line.contains("\u{2014}"), "no em dash in \(line)")
}

let below = USDFormat.display(Decimal(string: "9999.5")!, locale: en)
check(below.contains("9,999"), "under $10,000 stays exact: \(below)")
check(!below.contains("K"), "under $10,000 is not compact: \(below)")

let thousands = USDFormat.display(Decimal(string: "12400")!, locale: en)
check(thousands.contains("12.4"), "12400 compacts the digits: \(thousands)")
check(thousands.localizedCaseInsensitiveContains("K"), "12400 uses a thousands suffix: \(thousands)")

let millions = USDFormat.display(Decimal(1_200_000), locale: en)
check(millions.contains("1.2"), "1200000 compacts the digits: \(millions)")
check(millions.localizedCaseInsensitiveContains("M"), "1200000 uses a millions suffix: \(millions)")

let loss = USDFormat.display(Decimal(-15000), locale: en)
check(loss.contains("15"), "a loss keeps its digits: \(loss)")
check(loss.contains("-") || loss.contains("("), "a loss keeps a sign: \(loss)")

let wholeLegend = USDFormat.display(Decimal(800), fractionDigits: 0...0, locale: en)
check(wholeLegend == "$800", "legend dollars stay whole: \(wholeLegend)")

if failures > 0 {
    FileHandle.standardError.write("\(failures) failed\n".data(using: .utf8)!)
    exit(1)
}
print("small balance filter: ok")
