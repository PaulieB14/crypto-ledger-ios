import Testing
import Foundation
@testable import LedgerCore

@Suite("Per-account lots and liabilities")
struct PerAccountAndLiabilityTests {

    private func dec(_ s: String) -> Decimal { Decimal(string: s)! }

    private func entry(
        _ id: String, account: String, asset: String, qty: String,
        kind: EntryKind, price: String?, day: Int,
        health: String? = nil
    ) -> LedgerEntry {
        LedgerEntry(
            id: id, sourceID: "test", externalRef: id,
            timestamp: Date(timeIntervalSince1970: Double(day) * 86_400),
            accountID: account, assetID: asset,
            qtyDelta: dec(qty), kind: kind,
            unitPriceUSD: price.map(dec),
            healthFactor: health.map(dec))
    }

    @Test("A sale consumes only the selling account's lots, even under HIFO")
    func saleStaysInAccount() {
        // B's lot is the expensive one. Pooled HIFO would sell it. Per-account
        // HIFO must not: the sale happened on A.
        let entries = [
            entry("a", account: "Wallet A", asset: "BTC", qty: "1", kind: .buy, price: "10000", day: 1),
            entry("b", account: "Wallet B", asset: "BTC", qty: "1", kind: .buy, price: "50000", day: 2),
            entry("s", account: "Wallet A", asset: "BTC", qty: "-1", kind: .sell, price: "20000", day: 400),
        ]
        let spot = ["BTC": dec("20000")]

        for method in CostBasisMethod.allCases {
            let snap = PortfolioEngine(method: method).snapshot(entries: entries, spot: spot)
            let sale = snap.realized.filter { !$0.isTransferFee }
            #expect(sale.count == 1)
            #expect(sale[0].basisUSD == dec("10000"))
            #expect(sale[0].gainUSD == dec("10000"))
            #expect(snap.uncoveredDisposals.isEmpty)
            let open = snap.positions.first { $0.assetID == "BTC" && !$0.isLiability }
            #expect(open?.qty == dec("1"))
            #expect(open?.costBasisUSD == dec("50000"))
            // Method changes nothing about what is owned.
            #expect(snap.netWorthUSD == dec("20000"))
        }
    }

    @Test("Two lots in one account still follow FIFO versus HIFO")
    func methodStillMattersInsideAnAccount() {
        // The README fixture's sale, without the intervening transfer: same
        // account, so the known answer is unchanged.
        let entries = [
            entry("old", account: "coinbase", asset: "BTC", qty: "0.5", kind: .buy, price: "42000", day: 10),
            entry("new", account: "coinbase", asset: "BTC", qty: "0.3", kind: .buy, price: "69000", day: 500),
            entry("sale", account: "coinbase", asset: "BTC", qty: "-0.2", kind: .sell, price: "84000", day: 800),
        ]
        let fifo = PortfolioEngine(method: .fifo).snapshot(entries: entries, spot: ["BTC": dec("95000")])
        let hifo = PortfolioEngine(method: .hifo).snapshot(entries: entries, spot: ["BTC": dec("95000")])
        let fifoSale = fifo.realized[0]
        let hifoSale = hifo.realized[0]
        #expect(fifoSale.basisUSD == dec("8400"))
        #expect(fifoSale.gainUSD == dec("8400"))
        #expect(fifoSale.holdingPeriod == .long)
        #expect(hifoSale.basisUSD == dec("13800"))
        #expect(hifoSale.gainUSD == dec("3000"))
        #expect(hifoSale.holdingPeriod == .short)
        #expect(fifo.netWorthUSD == hifo.netWorthUSD)
    }

    @Test("A sale on one account keeps the other account in the breakdown")
    func provenanceSurvivesASale() {
        let entries = [
            entry("w", account: "Wallet", asset: "ETH", qty: "5", kind: .airdrop, price: "3000", day: 1),
            entry("s", account: "StakeWise Genesis Vault", asset: "ETH", qty: "5", kind: .airdrop, price: "3000", day: 1),
            entry("sell", account: "Wallet", asset: "ETH", qty: "-4", kind: .sell, price: "4000", day: 10),
        ]
        let snap = PortfolioEngine(method: .fifo).snapshot(entries: entries, spot: ["ETH": dec("4000")])
        let eth = snap.positions.first { $0.assetID == "ETH" }
        #expect(eth?.qty == dec("6"))
        #expect(eth?.byAccount.map(\.accountID) == ["StakeWise Genesis Vault", "Wallet"])
        #expect(eth?.byAccount.map(\.qty) == [dec("5"), dec("1")])
    }

    @Test("Collateral minus debt, and a liability is not a sale")
    func loanSubtractsFromNetWorth() {
        let entries = [
            entry("c", account: "Aave Ethereum", asset: "ETH", qty: "10", kind: .airdrop, price: "2000", day: 1),
            entry("d", account: "Aave Ethereum", asset: "USDC", qty: "-4000", kind: .liability, price: "1", day: 1, health: "1.8"),
            // A buy that spent cash never deposited. Must NOT stand in for the loan.
            entry("buy", account: "Wallet", asset: "ETH", qty: "1", kind: .buy, price: "2000", day: 2),
            entry("cash", account: "Wallet", asset: "USD", qty: "-2000", kind: .withdrawal, price: "1", day: 2),
        ]
        let spot = ["ETH": dec("2000"), "USDC": dec("1")]
        let snap = PortfolioEngine(method: .fifo).snapshot(entries: entries, spot: spot)

        #expect(snap.realized.isEmpty)
        #expect(snap.uncoveredDisposals.isEmpty)
        // 11 ETH * 2000 = 22000 of crypto. Cash is -2000 and floors at 0.
        // The USDC debt subtracts 4000. Negative cash does not.
        #expect(snap.cashUSD == dec("-2000"))
        #expect(snap.cryptoValueUSD == dec("22000"))
        #expect(snap.netWorthUSD == dec("18000"))

        let debt = snap.positions.first { $0.isLiability }
        #expect(debt?.assetID == "USDC")
        #expect(debt?.qty == dec("4000"))
        #expect(debt?.healthFactor == dec("1.8"))
        #expect(debt?.byAccount.map(\.accountID) == ["Aave Ethereum"])
        #expect(snap.reconciles)
    }

    @Test("A larger debt increases the liability and does not open a lot")
    func interestGrowsTheDebtNotALot() {
        let start = [
            entry("d", account: "Aave Ethereum", asset: "USDC", qty: "-1000", kind: .liability, price: "1", day: 1),
        ]
        let later = [
            entry("d", account: "Aave Ethereum", asset: "USDC", qty: "-1100", kind: .liability, price: "1", day: 30),
        ]
        let spot = ["USDC": dec("1")]
        let before = PortfolioEngine(method: .fifo).snapshot(entries: start, spot: spot)
        let after = PortfolioEngine(method: .fifo).snapshot(entries: later, spot: spot)
        #expect(before.netWorthUSD == dec("-1000"))
        #expect(after.netWorthUSD == dec("-1100"))
        #expect(after.positions.filter { !$0.isLiability }.isEmpty)
        #expect(after.realized.isEmpty)
        #expect(after.unpricedAcquisitions.isEmpty)
    }

    @Test("The ledger file round-trips, including a health factor")
    func archiveRoundTrip() throws {
        let entries = [
            entry("d", account: "Aave Ethereum", asset: "USDC", qty: "-1.5", kind: .liability, price: "1", day: 1, health: "2.25"),
            LedgerEntry(
                id: "p", sourceID: "s", externalRef: "r",
                timestamp: Date(timeIntervalSince1970: 0),
                accountID: "a", assetID: "chain:0xabc",
                qtyDelta: dec("0.123456789012345678"),
                kind: .buy, unitPriceUSD: dec("1234.56789")),
        ]
        let data = try LedgerArchive.encode(entries)
        let restored = try LedgerArchive.decode(data)
        #expect(restored.count == 2)
        #expect(restored[0].qtyDelta == entries[0].qtyDelta)
        #expect(restored[0].kind == .liability)
        #expect(restored[0].healthFactor == dec("2.25"))
        #expect(restored[1].qtyDelta == entries[1].qtyDelta)
        // An older file with no healthFactor key still decodes.
        let legacy = #"[{"id":"x","sourceID":"s","externalRef":"r","timestamp":"2024-01-01T00:00:00Z","accountID":"a","assetID":"BTC","qtyDelta":"1","kind":"buy","unitPriceUSD":"10"}]"#
        let old = try LedgerArchive.decode(Data(legacy.utf8))
        #expect(old[0].healthFactor == nil)
        #expect(old[0].qtyDelta == dec("1"))
    }
}
