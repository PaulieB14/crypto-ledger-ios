import Testing
import Foundation
@testable import LedgerCore

/// Staked ETH and wallet ETH are one asset to the tax engine and two different
/// things to the person holding them. Lots stay pooled — that is deliberate, see
/// `LotEngine` — so the split is carried separately as provenance. These tests
/// pin the cases where showing it would be wrong.
@Suite("Position provenance")
struct ProvenanceTests {

    private func dec(_ s: String) -> Decimal { Decimal(string: s)! }

    private func acquire(_ id: String, account: String, asset: String,
                         qty: String, price: String, day: Int) -> LedgerEntry {
        LedgerEntry(
            id: id, sourceID: "test", externalRef: id,
            timestamp: Date(timeIntervalSince1970: Double(day) * 86_400),
            accountID: account, assetID: asset,
            qtyDelta: dec(qty), kind: .airdrop, unitPriceUSD: dec(price))
    }

    @Test("Wallet ETH and staked ETH pool into one position but keep their split")
    func splitsStakedFromWallet() {
        let entries = [
            acquire("w", account: "Wallet 0x0ff5…a6f2", asset: "ETH", qty: "0.35",   price: "3000", day: 1),
            acquire("s", account: "StakeWise Genesis Vault", asset: "ETH", qty: "38.83", price: "3000", day: 1),
        ]
        let snap = PortfolioEngine(method: .fifo).snapshot(entries: entries, spot: ["ETH": dec("3000")])
        let eth = snap.positions.first { $0.assetID == "ETH" }

        // Still one row — the total is what you own.
        #expect(eth?.qty == dec("39.18"))
        // But it can say where it sits, largest first.
        #expect(eth?.byAccount.map(\.accountID) == ["StakeWise Genesis Vault", "Wallet 0x0ff5…a6f2"])
        #expect(eth?.byAccount.first?.qty == dec("38.83"))
        // And the parts must add back up to the row above them.
        #expect(eth?.byAccount.reduce(Decimal(0)) { $0 + $1.qty } == eth?.qty)
    }

    @Test("One account means there is nothing to disambiguate")
    func silentWhenSingleAccount() {
        let entries = [acquire("w", account: "Wallet", asset: "ETH", qty: "2", price: "3000", day: 1)]
        let snap = PortfolioEngine(method: .fifo).snapshot(entries: entries, spot: ["ETH": dec("3000")])
        #expect(snap.positions.first { $0.assetID == "ETH" }?.byAccount.isEmpty == true)
    }

    @Test("Stays silent rather than showing parts that contradict the total")
    func silentWhenPartsDoNotSum() {
        // A sale draws from pooled lots, not from the account the units left, so
        // the surviving per-account positives no longer describe the remainder.
        var entries = [
            acquire("w", account: "Wallet", asset: "ETH", qty: "5", price: "3000", day: 1),
            acquire("s", account: "StakeWise Genesis Vault", asset: "ETH", qty: "5", price: "3000", day: 1),
        ]
        entries.append(LedgerEntry(
            id: "sell", sourceID: "test", externalRef: "sell",
            timestamp: Date(timeIntervalSince1970: 10 * 86_400),
            accountID: "Wallet", assetID: "ETH",
            qtyDelta: dec("-4"), kind: .sell, unitPriceUSD: dec("4000")))

        let snap = PortfolioEngine(method: .fifo).snapshot(entries: entries, spot: ["ETH": dec("4000")])
        let eth = snap.positions.first { $0.assetID == "ETH" }
        #expect(eth?.qty == dec("6"))
        #expect(eth?.byAccount.isEmpty == true)
    }
}
